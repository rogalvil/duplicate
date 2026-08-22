import Foundation
import Synchronization

/// Why a folder apply refused to move a folder.
public enum FolderRefusal: Sendable, Equatable {
    /// Files exist in the folder about to go that the keeper does not have. **The reason this check exists.**
    case wouldLoseFiles(count: Int, examples: [String])
    /// The folder is not there any more.
    case missing(path: String)
    /// The folder being kept is not there, so containment cannot be checked.
    case keeperMissing(path: String)
    /// The walk or the hashing failed.
    case unreadable(path: String)
}

/// What a folder apply did.
public struct FolderDisposalReport: Sendable {
    public let sessionID: String
    public let moved: [DisposalOutcome]
    public let failures: [ApplyFailure]
    public let refused: [(path: String, reason: FolderRefusal)]
    public let stoppedEarly: Bool
    /// Whether the run stopped because it was cancelled. See ``SimilarDisposalReport/wasCancelled``.
    public var wasCancelled = false
    public let journalPath: String?

    public var movedBytes: Int64 { moved.reduce(0) { $0 + $1.byteCount } }
}

/// Moves the folders a review decided to remove, one at a time, proving first that nothing is lost.
///
/// **The verification is containment, not similarity, and that is the whole design.** "These two folders are 95%
/// alike" is a fine reason to *look*, and a terrible reason to delete: the other 5% is exactly what would be
/// lost. So before a folder is moved, both trees are walked and hashed, and every file in the doomed folder must
/// have a byte-identical twin at the same relative path in the folder being kept. One that does not is named and
/// the folder is left alone.
///
/// The digest cache makes this affordable: a folder that was just scanned is re-verified from cached digests.
///
/// **What goes in the journal is the manifest digest** -- a folder has no content digest of its own, and an undo
/// needs one to prove that what is in the Trash is still what was put there. Edit any file inside a trashed
/// folder, or add or remove one, and it changes.
public struct FolderApplyRunner: Sendable {
    public static let consecutiveFailureLimit = 20

    private let state: StateDirectory
    private let walker: any DirectoryEnumerating
    private let hasher: any FileHashing
    private let cacheURL: URL?

    public init(
        state: StateDirectory = .current(),
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: any FileHashing = ContentHasher(),
        cacheURL: URL? = nil
    ) {
        self.state = state
        self.walker = walker
        self.hasher = hasher
        self.cacheURL = cacheURL
    }

    public func run(
        _ plan: FolderApplyPlan,
        sessionID: String,
        instant: ScanIdentifier.Instant,
        disposer: any ItemDisposing,
        onProgress: (@Sendable (ApplyProgress) -> Void)? = nil
    ) async throws -> FolderDisposalReport {
        let cache = HashCache(url: cacheURL ?? HashCache.defaultURL())
        await cache.loadAndRepair()

        var moved: [DisposalOutcome] = []
        var failures: [ApplyFailure] = []
        var refused: [(path: String, reason: FolderRefusal)] = []
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
            // Flushed on the way out rather than thrown from here: see the note in `SimilarApplyRunner`.
            if Task.isCancelled {
                cancelled = true
                break
            }
            // Said before the work starts, not after it: the two manifests below are where the minutes go.
            let tally = FileTally()
            let emit: @Sendable (Int) -> Void = { soFar in
                onProgress?(
                    ApplyProgress(
                        itemsDone: index, itemCount: plan.items.count, path: item.path,
                        stage: .verifying(filesChecked: tally.base + soFar)))
            }
            emit(0)
            let manager = FileManager.default
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: item.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                refused.append((item.path, .missing(path: item.path)))
                onProgress?(
                    ApplyProgress(
                        itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                        stage: .done))
                continue
            }
            guard manager.fileExists(atPath: item.keeper, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                refused.append((item.path, .keeperMissing(path: item.keeper)))
                onProgress?(
                    ApplyProgress(
                        itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                        stage: .done))
                continue
            }

            // Two builds, one number: to the reader this is one pair being checked, so the keeper's count
            // continues where the doomed folder's left off instead of restarting at zero.
            //
            // **And a cancelled manifest is not an unreadable folder.** `FolderManifest.build` checks for
            // cancellation once per file, which is what makes a 10,506-file verification abortable -- but a
            // `try?` swallowing that error filed the folder under "could not be read", which is an accusation
            // about the user's data for something the user just asked for. Breaking out is also right on its
            // own terms: everything past this point re-reads the same tree.
            let doomedManifest: FolderManifest?
            do {
                doomedManifest = try await FolderManifest.build(
                    root: item.path, walker: walker, hasher: hasher, cache: cache, onFile: emit)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                doomedManifest = nil
            }
            guard let doomed = doomedManifest else {
                refused.append((item.path, .unreadable(path: item.path)))
                onProgress?(
                    ApplyProgress(
                        itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                        stage: .done))
                continue
            }
            tally.base = doomed.entries.count
            let keeperManifest: FolderManifest?
            do {
                keeperManifest = try await FolderManifest.build(
                    root: item.keeper, walker: walker, hasher: hasher, cache: cache, onFile: emit)
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                keeperManifest = nil
            }
            guard let keeper = keeperManifest else {
                refused.append((item.path, .unreadable(path: item.path)))
                onProgress?(
                    ApplyProgress(
                        itemsDone: index + 1, itemCount: plan.items.count, path: item.path,
                        stage: .done))
                continue
            }

            let missing = doomed.filesMissing(from: keeper)
            guard missing.isEmpty else {
                refused.append(
                    (
                        item.path,
                        .wouldLoseFiles(count: missing.count, examples: Array(missing.prefix(5)))
                    ))
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
                        digest: doomed.digest,
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

        _ = try? await cache.persist()
        try flush()

        var report = FolderDisposalReport(
            sessionID: sessionID,
            moved: moved,
            failures: failures,
            refused: refused,
            stoppedEarly: stoppedEarly,
            journalPath: moved.isEmpty ? nil : journalPath
        )
        report.wasCancelled = cancelled
        return report
    }

    public func sessionIdentifier(at date: Date) -> String {
        ScanIdentifier.identifier(from: date)
    }
}

/// How many files the first of a pair's two manifests digested, so the second can continue the count.
///
/// A class holding an `Atomic` because the callback that reads it is `@Sendable`: the same reason
/// `AppliedCounter` in the app is a class and not a local.
private final class FileTally: Sendable {
    private let stored = Atomic<Int>(0)
    var base: Int {
        get { stored.load(ordering: .relaxed) }
        set { stored.store(newValue, ordering: .relaxed) }
    }
}
