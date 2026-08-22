import Foundation
import Synchronization

/// One file the plan would remove, with what the scan vouched for.
public struct ApplyItem: Hashable, Sendable {
    public let path: String
    /// The digest the scan recorded for this content. Re-checked immediately before the move.
    public let digest: Digest32
    public let byteCount: Int64
    /// The group this file belongs to, so the journal can name it.
    public let groupKey: String

    public init(path: String, digest: Digest32, byteCount: Int64, groupKey: String) {
        self.path = path
        self.digest = digest
        self.byteCount = byteCount
        self.groupKey = groupKey
    }
}

/// What a dry run would do, and what an apply is authorised against.
///
/// Built from a review's removal plan, in the order the files will actually be acted on -- byte order
/// within each group, groups in scan order. The order is not cosmetic: it is the order the journal records,
/// and an undo replays it.
public struct ApplyPlan: Sendable {
    public let scanID: String
    public let items: [ApplyItem]

    public init(scanID: String, items: [ApplyItem]) {
        self.scanID = scanID
        self.items = items
    }

    /// Builds the plan from a review.
    ///
    /// Uses ``ExactReviewState/removalPlan``, which already honours storage classes: one representative per
    /// class, never `files[1:]`. So a hardlink that shares an inode with the keeper is not here.
    public static func from(_ state: ExactReviewState) -> ApplyPlan {
        var items: [ApplyItem] = []
        for entry in state.removalPlan {
            for path in PathOrder.sorted(entry.paths) {
                items.append(
                    ApplyItem(
                        path: path,
                        digest: entry.group.digest,
                        byteCount: entry.group.size,
                        groupKey: entry.group.key
                    )
                )
            }
        }
        return ApplyPlan(scanID: state.scan.scanID, items: items)
    }

    public var fileCount: Int { items.count }
    /// Bytes the plan would free if every move succeeds.
    public var byteCount: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    /// The digest each path must still hash to, for ``VerifyingDisposer``.
    public var expectedDigests: [String: Digest32] {
        Dictionary(items.map { ($0.path, $0.digest) }, uniquingKeysWith: { first, _ in first })
    }
    public var isEmpty: Bool { items.isEmpty }
}

/// What one file's move came to.
public struct ApplyFailure: Equatable, Sendable {
    public let path: String
    public let reason: DisposalError

    public init(path: String, reason: DisposalError) {
        self.path = path
        self.reason = reason
    }
}

/// What an apply actually did.
public struct DisposalReport: Sendable {
    public let sessionID: String
    public let moved: [DisposalOutcome]
    public let failures: [ApplyFailure]
    /// `true` when the run gave up early because failures kept coming.
    public let stoppedEarly: Bool
    /// Whether the run stopped because it was cancelled.
    ///
    /// **A cancelled apply returns a report rather than throwing.** The files it already moved are in the Trash,
    /// and the caller needs the journal path and the moved list to offer an undo; throwing would leave the user
    /// with moved files and a window that never heard about them.
    ///
    /// `Task.isCancelled` works in synchronous code, so this runner needs no `async` to honour a cancel -- it is
    /// called from a detached task and the flag is visible there.
    public var wasCancelled = false
    /// Where the journal went, or `nil` when nothing was moved.
    public let journalPath: String?

    public init(
        sessionID: String,
        moved: [DisposalOutcome],
        failures: [ApplyFailure],
        stoppedEarly: Bool,
        journalPath: String?
    ) {
        self.sessionID = sessionID
        self.moved = moved
        self.failures = failures
        self.stoppedEarly = stoppedEarly
        self.journalPath = journalPath
    }

    public var movedCount: Int { moved.count }
    public var freedBytes: Int64 { moved.reduce(0) { $0 + $1.byteCount } }
    /// How many landed in quarantine because the Trash refused them.
    public var quarantinedCount: Int { moved.filter { $0.mechanism == .quarantine }.count }
    public var isCompleteSuccess: Bool { failures.isEmpty && !stoppedEarly }
}

/// Carries out a plan, one file at a time.
///
/// **Serial on purpose.** The bottleneck is filesystem metadata, not throughput: concurrency buys nothing
/// and would make the journal's order non-deterministic, which is the order an undo replays.
///
/// **The first failure does not stop the run.** A file locked by another process must not abort the other
/// 3,997. **But twenty consecutive failures do stop it**: a global problem -- a revoked permission, a
/// volume that went away -- should not produce four thousand identical rows for the user to read.
public struct ApplyRunner: Sendable {
    /// How many failures in a row before giving up.
    public static let consecutiveFailureLimit = 20

    private let state: StateDirectory
    private let hasher: any FileHashing

    public init(state: StateDirectory = .current(), hasher: any FileHashing = ContentHasher()) {
        self.state = state
        self.hasher = hasher
    }

    /// Runs `plan`, journalling as it goes.
    ///
    /// - Parameters:
    ///   - disposer: normally a ``FallbackDisposer`` -- the Trash, falling back to quarantine when
    ///     `trashItem` refuses, which happens on network mounts and read-only volumes. Wrapped here in a
    ///     ``VerifyingDisposer`` so **every file is re-hashed immediately before it moves**. A path absent
    ///     from the plan is refused rather than allowed.
    ///   - onProgress: called after each item with how many are done. On the calling task.
    ///
    /// **Journalled in batches, not at the end.** A crash halfway through must leave a journal describing
    /// what already moved, or those files cannot be put back by the app. Batching keeps that true while
    /// costing one write per 32 files instead of one per file.
    public func run(
        _ plan: ApplyPlan,
        sessionID: String,
        instant: ScanIdentifier.Instant,
        disposer: any ItemDisposing,
        onProgress: (@Sendable (ApplyProgress) -> Void)? = nil
    ) throws -> DisposalReport {
        // The path being worked on, read by the callback the disposer calls when the digest matched. A box
        // because that callback is `@Sendable` and the loop variable is not visible to it.
        let current = CurrentItem()
        let verifying = VerifyingDisposer(
            wrapping: disposer,
            hasher: hasher,
            expected: plan.expectedDigests,
            onVerified: {
                onProgress?(
                    ApplyProgress(
                        itemsDone: current.index, itemCount: plan.items.count, path: current.path,
                        stage: .moving))
            }
        )

        var moved: [DisposalOutcome] = []
        var failures: [ApplyFailure] = []
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
            if Task.isCancelled {
                cancelled = true
                break
            }
            // Verifying is a full re-hash of the file, which for a 4 GB item is the slow half. Said before it
            // starts; the disposer says when it flips to moving.
            current.set(index: index, path: item.path)
            onProgress?(
                ApplyProgress(
                    itemsDone: index, itemCount: plan.items.count, path: item.path,
                    stage: .verifying(filesChecked: 0)))
            do {
                let outcome = try verifying.dispose(path: item.path)
                moved.append(outcome)
                pending.append(
                    JournalEntry(
                        originalPath: outcome.originalPath,
                        resultingPath: outcome.resultingPath,
                        mechanism: outcome.mechanism,
                        byteCount: outcome.byteCount,
                        digest: item.digest,
                        groupKey: item.groupKey,
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

        // Flushed even when the run stopped early, or the files that did move would be unrecoverable.
        try flush()

        var report = DisposalReport(
            sessionID: sessionID,
            moved: moved,
            failures: failures,
            stoppedEarly: stoppedEarly,
            journalPath: moved.isEmpty ? nil : journalPath
        )
        report.wasCancelled = cancelled
        return report
    }

    /// A session identifier for an apply starting now.
    ///
    /// Same shape as a scan identifier, so the journal sorts chronologically by filename like every other
    /// directory here.
    public func sessionIdentifier(at date: Date) -> String {
        ScanIdentifier.identifier(from: date)
    }
}

/// The item an apply is on, readable from the `@Sendable` callback the verifying disposer calls.
private final class CurrentItem: Sendable {
    private let stored = Mutex<(index: Int, path: String)>((0, ""))

    func set(index: Int, path: String) {
        stored.withLock { $0 = (index, path) }
    }

    var index: Int { stored.withLock { $0.index } }
    var path: String { stored.withLock { $0.path } }
}
