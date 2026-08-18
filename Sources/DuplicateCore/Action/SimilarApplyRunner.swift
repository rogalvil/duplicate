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
        case .stillAlike: return nil
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
    public let journalPath: String?

    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.byteCount } }
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
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> SimilarDisposalReport {
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

        for (index, item) in plan.items.enumerated() {
            try Task.checkCancellation()
            let verdict = await verifier.verify(
                item, imageThreshold: plan.imageThreshold, videoThreshold: plan.videoThreshold)
            if let refusal = SimilarRefusal(verdict) {
                refused.append((item.path, refusal))
                onProgress?(index + 1, plan.items.count)
                continue
            }

            // **The digest for the journal, read now** rather than remembered from a scan that never had one.
            //
            // And if it cannot be read, the file is not moved. The verification just read this file, so a failure
            // here is close to impossible -- but a journal entry with an invented digest would let an undo
            // "verify" a restored file against nothing, which is worse than refusing a deletion.
            guard let digest = try? hasher.fullDigest(atPath: item.path) else {
                refused.append((item.path, .unreadable(path: item.path)))
                onProgress?(index + 1, plan.items.count)
                continue
            }
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
            onProgress?(index + 1, plan.items.count)
        }

        // Flushed even when the run stopped early, or the files that did move would be unrecoverable.
        try flush()

        return SimilarDisposalReport(
            sessionID: sessionID,
            moved: moved,
            failures: failures,
            refused: refused,
            stoppedEarly: stoppedEarly,
            journalPath: moved.isEmpty ? nil : journalPath
        )
    }

    public func sessionIdentifier(at date: Date) -> String {
        ScanIdentifier.identifier(from: date)
    }
}
