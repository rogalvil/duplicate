import Foundation

/// Why a perceptual apply refused to move a file.
public enum SimilarRefusal: Sendable, Equatable {
    /// The pair no longer scores above the threshold: something changed since the scan.
    case noLongerAlike(similarity: Double, threshold: Double)
    /// One of the two files could not be read, so the claim could not be re-checked.
    case unreadable(path: String)
    /// The file is already gone.
    case missing(path: String)

    /// `nil` for a verdict that allows the move, so a pass cannot be turned into a refusal by accident.
    init?(_ verdict: SimilarVerifier.Verdict) {
        switch verdict {
        case .noLongerAlike(let similarity, let threshold):
            self = .noLongerAlike(similarity: similarity, threshold: threshold)
        case .unreadable(let path): self = .unreadable(path: path)
        case .missing(let path): self = .missing(path: path)
        case .stillAlike, .cancelled: return nil
        }
    }
}

/// What a perceptual apply did.
public struct SimilarDisposalReport: Sendable {
    public let sessionID: String
    public let moved: [DisposalOutcome]
    public let failures: [ApplyFailure]
    /// Files not moved because the pair no longer holds up. **Not failures** -- the check did its job.
    public let refused: [(path: String, reason: SimilarRefusal)]
    public let stoppedEarly: Bool
    /// Whether the run stopped because it was cancelled.
    ///
    /// **A cancelled apply returns a report rather than throwing**, because the files it already moved are in the
    /// Trash and the caller needs the journal path and the moved list to offer an undo. Throwing would leave the
    /// user with moved files and a window that never learned about them.
    public var wasCancelled = false
    public let journalPath: String?
    /// Kept files now under the name of a file this run moved (#228).
    public var renamed: [SimilarRename] = []
    /// Renames left undone, with why. Like ``refused``, not failures: the file is untouched under its own name.
    public var renameRefusals: [(rename: SimilarRename, reason: SimilarRenameRefusal)] = []

    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.byteCount } }
    /// Moved into quarantine because the Trash refused, so not where "Put Back" can find them.
    public var quarantinedCount: Int { moved.filter { $0.mechanism == .quarantine }.count }
}

/// Moves the files a perceptual review decided to remove, one at a time, verifying each first.
///
/// **Serial, journalled in batches of 32, and it stops after twenty consecutive failures** -- the same three
/// rules the exact runner follows, for the same reasons: the bottleneck is filesystem metadata so concurrency
/// buys nothing and would make the journal order non-deterministic; a crash mid-run has to leave a journal
/// describing what already moved, or those files cannot be put back; and one file locked by another process must
/// not abort the other 3,997 while a global problem must not produce four thousand identical rows.
///
/// **What differs is the verification.** There is no recorded digest to compare against, so each item is
/// re-scored against its counterpart and moved only if the pair still passes -- see ``SimilarVerifier``. The
/// SHA-256 that goes in the journal is computed here, at move time, which is the digest an undo needs: it proves a
/// restored file is byte-identical to the one that was moved.
public struct SimilarApplyRunner: Sendable {
    public static let consecutiveFailureLimit = 20

    private let state: StateDirectory
    private let hasher: any FileHashing
    private let verifier: SimilarVerifier

    public init(
        state: StateDirectory = .current(),
        hasher: any FileHashing = ContentHasher(),
        verifier: SimilarVerifier = SimilarVerifier()
    ) {
        self.state = state
        self.hasher = hasher
        self.verifier = verifier
    }

    public func run(
        _ plan: SimilarApplyPlan,
        sessionID: String,
        instant: ScanIdentifier.Instant,
        disposer: any ItemDisposing,
        onProgress: (@Sendable (ApplyProgress) -> Void)? = nil
    ) async throws -> SimilarDisposalReport {
        // Before anything moves: a run that cannot record where files went must not move them.
        try MoveJournal.ensureWritable(sessionID: sessionID, in: state)
        var moved: [DisposalOutcome] = []
        var failures: [ApplyFailure] = []
        var refused: [(path: String, reason: SimilarRefusal)] = []
        var pending: [JournalEntry] = []
        var consecutive = 0
        var stoppedEarly = false
        var journalPath: String?

        func flush() throws {
            guard !pending.isEmpty else { return }
            _ = try MoveJournal.append(pending, sessionID: sessionID, in: state)
            journalPath = try MoveJournal.url(sessionID: sessionID, in: state).path(
                percentEncoded: false)
            pending.removeAll()
        }

        var cancelled = false
        for (index, item) in plan.items.enumerated() {
            // **Checked here and the journal flushed on the way out.** An earlier version threw from this point,
            // which skipped the flush below and left up to 31 already-moved files with no journal entry -- in the
            // Trash, and invisible to undo.
            if Task.isCancelled {
                cancelled = true
                break
            }
            // Re-scoring a perceptual pair decodes both files: measured, about 7 ms for two images and 300 ms
            // for two videos. Said before it starts.
            onProgress?(
                ApplyProgress(
                    itemsDone: index, itemCount: plan.items.count, path: item.path,
                    stage: .verifying(filesChecked: 0)))
            let verdict = await verifier.verify(
                item, imageThreshold: plan.imageThreshold, videoThreshold: plan.videoThreshold)
            // A cancelled verification is not a refusal: nothing was decided about this pair, so it must not
            // appear in a report the user reads as "these I checked and left alone".
            if verdict == .cancelled {
                cancelled = true
                break
            }
            if let refusal = SimilarRefusal(verdict) {
                refused.append((item.path, refusal))
                onProgress?(
                    ApplyProgress(
                        itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                        stage: .done))
                continue
            }

            // **The digest for the journal, read now** rather than remembered from a scan that never had one.
            //
            // And if it cannot be read, the file is not moved. The verification just read this file, so a failure
            // here is close to impossible -- but a journal entry with an invented digest would let an undo
            // "verify" a restored file against nothing, which is worse than refusing a deletion.
            // Checked before the read, not inferred from its failure: a cancelled hash coming back as
            // `.unreadable` is the bug this project just fixed one layer up.
            if Task.isCancelled {
                cancelled = true
                break
            }
            guard let digest = try? hasher.fullDigest(atPath: item.path) else {
                refused.append((item.path, .unreadable(path: item.path)))
                onProgress?(
                    ApplyProgress(
                        itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                        stage: .done))
                continue
            }
            onProgress?(
                ApplyProgress(
                    itemsDone: index, itemCount: plan.items.count, path: item.path, stage: .moving))
            do {
                let outcome = try disposer.dispose(path: item.path)
                moved.append(outcome)
                pending.append(
                    JournalEntry(
                        originalPath: outcome.originalPath,
                        resultingPath: outcome.resultingPath,
                        mechanism: outcome.mechanism,
                        byteCount: outcome.byteCount,
                        digest: digest.digest,
                        groupKey: item.pairKey,
                        scanID: plan.scanID,
                        timestamp: instant.timestamp
                    )
                )
                consecutive = 0
                if pending.count >= 32 { try flush() }
            } catch let error as DisposalError {
                failures.append(ApplyFailure(path: item.path, reason: error))
                consecutive += 1
                if consecutive >= Self.consecutiveFailureLimit {
                    stoppedEarly = true
                    break
                }
            }
            onProgress?(
                ApplyProgress(
                    itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                    stage: .done))
        }

        // **Renames last, and only after a run that went through** (#228). A name is free only once the file that had
        // it is in the Trash, and a cancelled or stopped run is not the plan the user approved.
        var renamed: [SimilarRename] = []
        var renameRefusals: [(rename: SimilarRename, reason: SimilarRenameRefusal)] = []
        if !cancelled, !stoppedEarly {
            for rename in plan.renames {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                let manager = FileManager.default
                guard manager.fileExists(atPath: rename.keptPath) else {
                    renameRefusals.append((rename, .keptMissing))
                    continue
                }
                guard !manager.fileExists(atPath: rename.nameFromPath) else {
                    renameRefusals.append((rename, .nameSourceStayed))
                    continue
                }
                // Read before the rename, for the same reason as a move: an undo puts back only what it can verify.
                guard let digest = try? hasher.fullDigest(atPath: rename.keptPath) else {
                    renameRefusals.append((rename, .unreadable))
                    continue
                }
                let target = rename.targetPath
                // **Exclusive, so the filesystem itself refuses a taken name**, with no gap between a check and the
                // move for another file to land in. Measured on the boot volume: refused with EEXIST and the other
                // file intact, and still allowed when the new name differs only in case -- a check with
                // `fileExists` first would have refused that one, because the old name answers for the new.
                guard renamex_np(rename.keptPath, target, UInt32(RENAME_EXCL)) == 0 else {
                    let code = errno
                    if code == EEXIST {
                        renameRefusals.append((rename, .nameTaken))
                    } else {
                        failures.append(
                            ApplyFailure(
                                path: rename.keptPath,
                                reason: .renameFailed(
                                    path: rename.keptPath, reason: String(cString: strerror(code))))
                        )
                    }
                    continue
                }
                renamed.append(rename)
                pending.append(
                    JournalEntry(
                        originalPath: rename.keptPath,
                        resultingPath: target,
                        mechanism: .rename,
                        byteCount: 0,
                        digest: digest.digest,
                        groupKey: rename.keptPath + "||" + rename.nameFromPath,
                        scanID: plan.scanID,
                        timestamp: instant.timestamp
                    )
                )
                if pending.count >= 32 { try flush() }
            }
        }

        // Flushed even when the run stopped early or was cancelled, or the files that did move would be
        // unrecoverable.
        try flush()

        var report = SimilarDisposalReport(
            sessionID: sessionID,
            moved: moved,
            failures: failures,
            refused: refused,
            stoppedEarly: stoppedEarly,
            journalPath: moved.isEmpty && renamed.isEmpty ? nil : journalPath
        )
        report.wasCancelled = cancelled
        report.renamed = renamed
        report.renameRefusals = renameRefusals
        return report
    }

    public func sessionIdentifier(at date: Date) -> String {
        ScanIdentifier.identifier(from: date)
    }
}
