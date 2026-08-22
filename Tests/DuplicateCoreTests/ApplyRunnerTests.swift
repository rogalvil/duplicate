import Foundation
import Synchronization
import Testing

@testable import DuplicateCore

/// A tree, a state directory and a quarantine root, all under `/tmp`.
///
/// **Nothing here goes to the real Trash.** The disposer under test is a quarantine one: `trashItem` is
/// covered by its own tests and by `--selftest --mode trash`, and a test suite that filled the user's Trash
/// with fixtures would be a test suite nobody wants to run twice.
private struct ApplyScratch {
    let root: String
    let tree: String
    let state: StateDirectory

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-apply-\(UUID().uuidString)"
        tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
    }

    @discardableResult
    func write(_ name: String, _ contents: String) throws -> String {
        let path = tree + "/" + name
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(filePath: path))
        return path
    }

    func disposer(sessionID: String) -> QuarantineDisposer {
        QuarantineDisposer(root: root + "/quarantine", sessionID: sessionID)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private let noon = ScanIdentifier.Instant(
    year: 2026, month: 8, day: 12, hour: 12, minute: 0, second: 0, microsecond: 0
)

/// A disposer that refuses everything, for the give-up-early rule.
private struct RefusingDisposer: ItemDisposing {
    func dispose(path: String) throws -> DisposalOutcome {
        throw DisposalError.trashUnavailable(path: path, reason: "refused by the test")
    }
}

private func digest(of path: String) throws -> Digest32 {
    try ContentHasher().fullDigest(atPath: path).digest
}

private func plan(_ paths: [String], scanID: String = "20260812-120000-000000") throws -> ApplyPlan
{
    var items: [ApplyItem] = []
    for path in paths {
        let size =
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .int64Value ?? 0
        items.append(
            ApplyItem(
                path: path, digest: try digest(of: path), byteCount: size,
                groupKey: "\(size):\(try digest(of: path).hexString)"
            )
        )
    }
    return ApplyPlan(scanID: scanID, items: items)
}

@Suite("ApplyPlan")
struct ApplyPlanTests {

    /// **The plan honours storage classes, because it comes from `removalPlan`.** A hardlink that shares an
    /// inode with the keeper is not in it -- otherwise the app would trash a second name for the very file
    /// it is keeping, recover nothing, and report that it recovered something.
    @Test("A file sharing storage with the keeper is not in the plan")
    func skipsTheKeepersOwnStorage() {
        let group = DuplicateGroup(
            size: 100,
            digest: Digest32(hexString: String(repeating: "a", count: 64))!,
            files: ["/r/keep", "/r/hardlink", "/r/independent"],
            storage: StoragePartition(
                clusters: [["/r/keep", "/r/hardlink"], ["/r/independent"]], isExact: true)
        )
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: "/r",
            createdAt: "2026-08-12T12:00:00.000000Z", groups: [group]
        )
        var state = ExactReviewState(scan: scan, root: "/r")
        _ = state.confirm()

        let built = ApplyPlan.from(state)
        #expect(built.items.map(\.path) == ["/r/independent"])
        #expect(built.fileCount == 1)
        #expect(built.byteCount == 100)
    }

    @Test("An undecided review plans nothing")
    func plansNothingWithoutDecisions() {
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: "/r",
            createdAt: "2026-08-12T12:00:00.000000Z",
            groups: [
                DuplicateGroup(
                    size: 10, digest: Digest32(hexString: String(repeating: "a", count: 64))!,
                    files: ["/r/a", "/r/b"])
            ]
        )
        let built = ApplyPlan.from(ExactReviewState(scan: scan, root: "/r"))
        #expect(built.isEmpty)
    }

    /// The order is the order the journal records and an undo replays, so it is pinned.
    @Test("Paths are planned in byte order")
    func ordersByBytes() {
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: "/r",
            createdAt: "2026-08-12T12:00:00.000000Z",
            groups: [
                DuplicateGroup(
                    size: 10, digest: Digest32(hexString: String(repeating: "a", count: 64))!,
                    files: ["/r/keep", "/r/z", "/r/a"])
            ]
        )
        var state = ExactReviewState(scan: scan, root: "/r")
        _ = state.confirm()
        #expect(ApplyPlan.from(state).items.map(\.path) == ["/r/a", "/r/z"])
    }
}

@Suite("ApplyRunner")
struct ApplyRunnerTests {

    @Test("Every file in the plan is moved, journalled, and reported")
    func movesAndJournals() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.write("a.txt", "shared contents")
        let b = try scratch.write("sub/b.txt", "shared contents")

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            try plan([a, b]), sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )

        #expect(report.movedCount == 2)
        #expect(report.failures.isEmpty)
        #expect(report.stoppedEarly == false)
        #expect(report.isCompleteSuccess)
        #expect(report.freedBytes == 30)
        #expect(report.quarantinedCount == 2)
        // The originals are gone and the journal describes where they went.
        #expect(FileManager.default.fileExists(atPath: a) == false)
        #expect(FileManager.default.fileExists(atPath: b) == false)
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.count == 2)
        #expect(loaded.entries.map(\.originalPath) == [a, b])
    }

    /// **The safety rule that makes trusting the hash cache acceptable.** A digest that is stale -- because
    /// the file changed after the scan -- must stop that file from moving, not be discovered afterwards.
    @Test("A file whose content changed since the scan is refused")
    func refusesChangedContent() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.write("a.txt", "original contents")
        let built = try plan([a])
        // Change it after the plan was built, which is exactly the window this guards.
        try Data("different contents entirely".utf8).write(to: URL(filePath: a))

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            built, sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )

        #expect(report.movedCount == 0)
        #expect(report.failures.count == 1)
        #expect(report.failures[0].reason == .contentChanged(path: a))
        // And it is still there, which is the point.
        #expect(FileManager.default.fileExists(atPath: a))
        #expect(report.journalPath == nil)
    }

    /// A path nobody vouched for is refused rather than allowed. Disposing something absent from the plan is
    /// the mistake `VerifyingDisposer` exists to prevent.
    @Test("A path outside the plan is never disposed")
    func refusesAnUnvouchedPath() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let planned = try scratch.write("planned.txt", "x")
        let bystander = try scratch.write("bystander.txt", "y")

        let session = "20260812-120000-000000"
        var built = try plan([planned])
        // Smuggle in an item the digest map does not cover.
        built = ApplyPlan(
            scanID: built.scanID,
            items: built.items + [
                ApplyItem(
                    path: bystander,
                    digest: Digest32(hexString: String(repeating: "f", count: 64))!,
                    byteCount: 1, groupKey: "1:f"
                )
            ]
        )
        let report = try ApplyRunner(state: scratch.state).run(
            built, sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )

        #expect(report.movedCount == 1)
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: bystander))
    }

    /// **One locked file must not abort the other 3,997.**
    @Test("A single failure does not stop the run")
    func toleratesOneFailure() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let good1 = try scratch.write("g1.txt", "aaa")
        let bad = try scratch.write("bad.txt", "bbb")
        let good2 = try scratch.write("g2.txt", "ccc")
        let built = try plan([good1, bad, good2])
        // Make the middle one fail by changing it.
        try Data("changed".utf8).write(to: URL(filePath: bad))

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            built, sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )

        #expect(report.movedCount == 2)
        #expect(report.failures.count == 1)
        #expect(report.stoppedEarly == false)
        #expect(FileManager.default.fileExists(atPath: good1) == false)
        #expect(FileManager.default.fileExists(atPath: good2) == false)
        #expect(FileManager.default.fileExists(atPath: bad))
    }

    /// **But a global problem stops it.** A revoked permission or a volume that went away should not produce
    /// four thousand identical rows for the user to read.
    @Test("Twenty failures in a row give up")
    func stopsAfterConsecutiveFailures() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        var paths: [String] = []
        for index in 0..<40 {
            paths.append(try scratch.write("f\(index).txt", "contents \(index)"))
        }

        let report = try ApplyRunner(state: scratch.state).run(
            try plan(paths), sessionID: "20260812-120000-000000", instant: noon,
            disposer: RefusingDisposer()
        )

        #expect(report.stoppedEarly)
        #expect(report.failures.count == ApplyRunner.consecutiveFailureLimit)
        #expect(report.movedCount == 0)
        // The other 20 were never attempted, so they are all still there.
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
    }

    /// A run that gives up must still journal what already moved, or those files cannot be put back.
    @Test("Files moved before a give-up are still journalled")
    func journalsBeforeGivingUp() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let good = try scratch.write("good.txt", "moves fine")
        var paths = [good]
        for index in 0..<25 {
            let path = try scratch.write("bad\(index).txt", "will change \(index)")
            paths.append(path)
        }
        let built = try plan(paths)
        // Break everything except the first.
        for path in paths.dropFirst() {
            try Data("changed".utf8).write(to: URL(filePath: path))
        }

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            built, sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )

        #expect(report.stoppedEarly)
        #expect(report.movedCount == 1)
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.count == 1)
        #expect(loaded.entries[0].originalPath == good)
    }

    /// The journal is flushed in batches; a plan larger than one batch has to end up complete.
    @Test("A plan larger than one journal batch is fully recorded")
    func journalsEveryBatch() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        var paths: [String] = []
        for index in 0..<70 {
            paths.append(try scratch.write("f\(index).txt", "contents \(index)"))
        }

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            try plan(paths), sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )

        #expect(report.movedCount == 70)
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.count == 70)
        #expect(loaded.entries.map(\.originalPath) == paths)
    }

    @Test("Progress is reported once per item, and names the stage before each")
    func reportsProgress() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let paths = try (0..<5).map { try scratch.write("f\($0).txt", "contents \($0)") }

        let seen = Mutex<[ApplyProgress]>([])
        let session = "20260812-120000-000000"
        _ = try ApplyRunner(state: scratch.state).run(
            try plan(paths), sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session),
            onProgress: { report in seen.withLock { $0.append(report) } }
        )
        let reports = seen.withLock { $0 }
        #expect(reports.allSatisfy { $0.itemCount == 5 })

        // One item done per item, still.
        let done = reports.filter { $0.stage == .done }.map(\.itemsDone)
        #expect(done == [1, 2, 3, 4, 5])

        // And each item says it is verifying before it says it is moving. The re-hash is the slow half for a
        // large file, and the caller cannot see the boundary from outside the disposer.
        let firstItem = reports.filter { $0.path == paths[0] }
        #expect(firstItem.first?.stage == .verifying(filesChecked: 0))
        #expect(firstItem.contains { $0.stage == .moving })
    }

    @Test("An empty plan does nothing and writes no journal")
    func handlesAnEmptyPlan() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            ApplyPlan(scanID: "20260812-120000-000000", items: []),
            sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )
        #expect(report.movedCount == 0)
        #expect(report.journalPath == nil)
        // Nothing was written, so the journal file for the session does not exist either.
        let journal = try MoveJournal.url(sessionID: session, in: scratch.state)
        #expect(
            FileManager.default.fileExists(atPath: journal.path(percentEncoded: false)) == false)
    }

    /// The whole loop: apply, then put everything back byte-identical.
    @Test("What was applied can be undone byte-identically")
    func roundTripsThroughUndo() throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.write("a.txt", "contents of a")
        let b = try scratch.write("sub/b.txt", "contents of b")
        let originals = [a: try digest(of: a), b: try digest(of: b)]

        let session = "20260812-120000-000000"
        let report = try ApplyRunner(state: scratch.state).run(
            try plan([a, b]), sessionID: session, instant: noon,
            disposer: scratch.disposer(sessionID: session)
        )
        #expect(report.movedCount == 2)

        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        let undo = UndoPlanner.plan(
            sessionID: session,
            entries: loaded.entries,
            restoredPaths: loaded.restoredPaths,
            environment: .live(hasher: ContentHasher())
        )
        #expect(undo.restorable.count == 2)
        #expect(undo.isNoOp == false)

        let result = UndoRunner().run(undo)
        #expect(result.restored.count == 2)
        for (path, want) in originals {
            #expect(FileManager.default.fileExists(atPath: path))
            #expect(try digest(of: path) == want)
        }
    }
}
