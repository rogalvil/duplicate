import Foundation
import Testing

@testable import DuplicateCore

private func pair(
    _ a: String, _ b: String, _ kind: MediaKind = .image, similarity: Double = 1.0
)
    -> SimilarPair
{
    SimilarPair(fileA: a, fileB: b, similarity: similarity, mediaKind: kind)
}

private func scan(_ pairs: [SimilarPair], root: String = "/r") -> SimilarScan {
    SimilarScan(
        scanID: "20260818-120000-000000", root: root, createdAt: "t",
        imageThreshold: 5, videoThreshold: 0.7, pairs: pairs
    )
}

private struct ApplyScratch {
    let root: String
    let tree: String
    let state: StateDirectory

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-simapply-\(UUID().uuidString)"
        tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
    }

    @discardableResult
    func image(_ name: String, _ pattern: SyntheticImage.Pattern) throws -> String {
        try SyntheticImage.write(
            pattern, width: 96, height: 96, format: .png, to: tree + "/" + name)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

/// Moves nothing, records everything, so a plan can be exercised without a filesystem.
private final class RecordingDisposer: ItemDisposing, @unchecked Sendable {
    private(set) var disposed: [String] = []

    func dispose(path: String) throws -> DisposalOutcome {
        disposed.append(path)
        return DisposalOutcome(
            originalPath: path, resultingPath: "/trash/" + (path as NSString).lastPathComponent,
            mechanism: .trash, byteCount: 10)
    }
}

@Suite("SimilarApplyPlan")
struct SimilarApplyPlanTests {

    @Test("An untouched review plans nothing")
    func plansNothingUntouched() {
        let state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        let plan = SimilarApplyPlan.from(state)
        #expect(plan.isEmpty)
        #expect(plan.items.isEmpty)
        #expect(plan.contradicted.isEmpty)
    }

    @Test("A decided pair plans the file the decision removes")
    func plansTheRemovedFile() throws {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        state.confirm(.keepA)
        let plan = SimilarApplyPlan.from(state)
        let item = try #require(plan.items.first)
        #expect(item.path == "/r/b.jpg")
        #expect(item.counterpart == "/r/a.jpg")
        #expect(item.pairKey == "/r/a.jpg||/r/b.jpg")
        #expect(plan.pairCount == 1)
    }

    /// **A file in several pairs is planned once.** Moving it twice would fail the second time on a file already
    /// in the Trash and report an error for something that worked.
    @Test("A file removed by two pairs appears once")
    func deduplicatesByPath() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/c.jpg"), pair("/r/b.jpg", "/r/c.jpg")]))
        state.confirmAll([0, 1], as: .keepA)
        let plan = SimilarApplyPlan.from(state)
        #expect(plan.items.map(\.path) == ["/r/c.jpg"])
        #expect(plan.pairCount == 1, "the surviving item keeps one pair key")
    }

    /// **Excluded, not warned about.** Both decisions are the user's, and the only reading that respects both is
    /// to act on neither.
    @Test("A path kept by another decision is excluded from the plan")
    func excludesContradictions() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg"), pair("/r/a.jpg", "/r/c.jpg")]))
        state.confirm(.keepB)  // removes /r/a.jpg
        state.go(to: 1)
        state.confirm(.keepA)  // keeps /r/a.jpg
        let plan = SimilarApplyPlan.from(state)
        #expect(plan.contradicted == ["/r/a.jpg"])
        #expect(!plan.items.map(\.path).contains("/r/a.jpg"))
        // The other victim of the second pair is still planned: only the conflicted path is dropped.
        #expect(plan.items.map(\.path) == ["/r/c.jpg"])
    }

    @Test("keep_none plans both files of the pair")
    func plansBothForKeepNone() {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        state.confirm(.keepNone)
        let plan = SimilarApplyPlan.from(state)
        #expect(plan.items.map(\.path) == ["/r/a.jpg", "/r/b.jpg"])
        // Each item names the other as its counterpart, so the verification has something to compare against.
        #expect(plan.items[0].counterpart == "/r/b.jpg")
        #expect(plan.items[1].counterpart == "/r/a.jpg")
    }

    @Test("The plan is in byte order, so a dry run and an apply agree")
    func ordersByBytes() {
        var state = SimilarReviewState(
            scan: scan([
                pair("/r/z.jpg", "/r/zz.jpg"), pair("/r/a.jpg", "/r/aa.jpg"),
                pair("/r/m.jpg", "/r/mm.jpg"),
            ]))
        state.confirmAll([0, 1, 2], as: .keepA)
        let plan = SimilarApplyPlan.from(state)
        #expect(plan.items.map(\.path) == ["/r/aa.jpg", "/r/mm.jpg", "/r/zz.jpg"])
    }

    /// The fingerprint has to survive a relaunch, so it cannot come from Swift's seeded hasher.
    @Test("The fingerprint changes with the plan and not with the process")
    func fingerprintsThePlan() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg"), pair("/r/c.jpg", "/r/d.jpg")]))
        state.confirm(.keepA)
        let one = SimilarApplyPlan.from(state).fingerprint
        #expect(one == SimilarApplyPlan.from(state).fingerprint)
        state.go(to: 1)
        state.confirm(.keepA)
        #expect(SimilarApplyPlan.from(state).fingerprint != one)
        #expect(one.count == 16, "the fingerprint is 16 hex characters")
    }
}

@Suite("SimilarVerifier")
struct SimilarVerifierTests {

    @Test("A pair that still looks alike is allowed")
    func allowsAnUnchangedPair() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let b = try scratch.image("b.png", .rampWithCorner)

        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: b, counterpart: a, pairKey: "\(a)||\(b)", mediaKind: .image,
                recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(verdict.allowsMove)
        guard case .stillAlike(let similarity) = verdict else {
            Issue.record("expected a pass, got \(verdict)")
            return
        }
        #expect(similarity == 1.0)
    }

    /// **The check the exact detector does with a digest, done with the claim instead.** A file replaced at the
    /// same path since the scan is refused rather than deleted on a stale claim.
    @Test("A file replaced since the scan is refused")
    func refusesAChangedFile() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let b = try scratch.image("b.png", .rampWithCorner)
        // Same path, an entirely different picture.
        _ = try scratch.image("b.png", .checkerboard(square: 3))

        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: b, counterpart: a, pairKey: "\(a)||\(b)", mediaKind: .image,
                recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(!verdict.allowsMove)
        guard case .noLongerAlike = verdict else {
            Issue.record("expected a refusal, got \(verdict)")
            return
        }
    }

    @Test("A file that is already gone is reported as missing, not as an error")
    func reportsMissing() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: scratch.tree + "/gone.png", counterpart: a, pairKey: "k",
                mediaKind: .image, recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(verdict == .missing(path: scratch.tree + "/gone.png"))
    }

    /// **The counterpart's absence stops the move**: without it the claim cannot be re-checked, and moving on an
    /// unverifiable claim is what this type exists to prevent.
    @Test("A missing counterpart refuses the move")
    func refusesWithoutACounterpart() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let b = try scratch.image("b.png", .rampWithCorner)
        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: b, counterpart: scratch.tree + "/gone.png", pairKey: "k",
                mediaKind: .image, recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(verdict == .unreadable(path: scratch.tree + "/gone.png"))
        #expect(!verdict.allowsMove)
    }

    /// The video branch, where the comparison is asymmetric -- so the verification has to ask it the same way
    /// round the scan did, or it could refuse a move the scan's own number allows.
    @Test("A video pair that still matches is allowed")
    func allowsAnUnchangedVideoPair() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .movingBlock),
            to: scratch.tree + "/a.mp4")
        let b = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .movingBlock),
            to: scratch.tree + "/b.mp4")

        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: b, counterpart: a, pairKey: "\(a)||\(b)", mediaKind: .video,
                recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(verdict.allowsMove, "an unchanged video pair was refused: \(verdict)")
    }

    @Test("A video replaced since the scan is refused")
    func refusesAChangedVideo() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .movingBlock),
            to: scratch.tree + "/a.mp4")
        let b = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .movingBlock),
            to: scratch.tree + "/b.mp4")
        // Same path, a clip that looks nothing like it.
        _ = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .constantGrey(30)),
            to: scratch.tree + "/b.mp4")

        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: b, counterpart: a, pairKey: "\(a)||\(b)", mediaKind: .video,
                recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(!verdict.allowsMove)
        guard case .noLongerAlike = verdict else {
            Issue.record("expected a refusal, got \(verdict)")
            return
        }
    }

    @Test("A video that cannot be decoded is refused")
    func refusesUnreadableVideo() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .movingBlock),
            to: scratch.tree + "/a.mp4")
        let broken = scratch.tree + "/broken.mp4"
        try Data("not a movie".utf8).write(to: URL(filePath: broken))

        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: broken, counterpart: a, pairKey: "k", mediaKind: .video,
                recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(verdict == .unreadable(path: broken))
    }

    @Test("A file that is not an image is refused rather than deleted")
    func refusesUnreadable() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let broken = scratch.tree + "/broken.png"
        try Data("not a png".utf8).write(to: URL(filePath: broken))

        let verdict = await SimilarVerifier().verify(
            SimilarApplyItem(
                path: broken, counterpart: a, pairKey: "k", mediaKind: .image,
                recordedSimilarity: 1.0),
            imageThreshold: 5, videoThreshold: 0.7
        )
        #expect(verdict == .unreadable(path: broken))
    }
}

@Suite("SimilarApplyRunner")
struct SimilarApplyRunnerTests {

    private let instant = ScanIdentifier.Instant(
        year: 2026, month: 8, day: 18, hour: 12, minute: 0, second: 0, microsecond: 0)

    @Test("A verified item is moved and journalled")
    func movesAndJournals() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let b = try scratch.image("b.png", .rampWithCorner)

        var review = SimilarReviewState(scan: scan([pair(a, b)], root: scratch.tree))
        review.confirm(.keepA)
        let plan = SimilarApplyPlan.from(review)
        let disposer = RecordingDisposer()

        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant, disposer: disposer)

        #expect(report.moved.count == 1)
        #expect(disposer.disposed == [b])
        #expect(report.refused.isEmpty)
        #expect(report.failures.isEmpty)
        #expect(report.journalPath != nil)

        // The journal carries a digest computed at move time, which is what an undo verifies against.
        let loaded = try MoveJournal.load(sessionID: instant.identifier, in: scratch.state)
        #expect(loaded.entries.count == 1)
        let entry = try #require(loaded.entries.first)
        #expect(entry.originalPath == b)
        #expect(entry.groupKey == "\(a)||\(b)")
        #expect(entry.scanID == "20260818-120000-000000")
        #expect(entry.digest != Digest32(hexString: String(repeating: "0", count: 64)))
    }

    /// **The refusal path, end to end.** A file changed since the scan is left alone and named.
    @Test("A changed file is refused, not moved")
    func refusesChangedFiles() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let b = try scratch.image("b.png", .rampWithCorner)

        var review = SimilarReviewState(scan: scan([pair(a, b)], root: scratch.tree))
        review.confirm(.keepA)
        let plan = SimilarApplyPlan.from(review)

        // Replace the file the plan would move.
        _ = try scratch.image("b.png", .checkerboard(square: 3))

        let disposer = RecordingDisposer()
        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant, disposer: disposer)

        #expect(report.moved.isEmpty)
        #expect(disposer.disposed.isEmpty, "a changed file was moved")
        #expect(report.refused.count == 1)
        guard case .noLongerAlike = report.refused[0].reason else {
            Issue.record("wrong refusal: \(report.refused[0].reason)")
            return
        }
        #expect(report.journalPath == nil, "nothing moved, so there is no journal")
    }

    @Test("An empty plan does nothing and writes no journal")
    func handlesAnEmptyPlan() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let plan = SimilarApplyPlan.from(
            SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")])))
        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant, disposer: RecordingDisposer())
        #expect(report.moved.isEmpty)
        #expect(report.journalPath == nil)
    }

    @Test("Progress is reported for refusals as well as moves")
    func reportsProgressForEveryItem() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let b = try scratch.image("b.png", .rampWithCorner)
        let c = try scratch.image("c.png", .checkerboard(square: 3))
        let d = try scratch.image("d.png", .uniform(200))

        var review = SimilarReviewState(
            scan: scan([pair(a, b), pair(c, d)], root: scratch.tree))
        review.confirmAll([0, 1], as: .keepA)
        let plan = SimilarApplyPlan.from(review)
        #expect(plan.items.count == 2)

        let counter = ProgressBox()
        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant, disposer: RecordingDisposer(),
            onProgress: { done, total in counter.record(done: done, total: total) }
        )
        #expect(counter.lastDone == 2)
        #expect(counter.lastTotal == 2)
        // The checkerboard pair does not look alike at all, so it is refused rather than moved.
        #expect(report.moved.count + report.refused.count == 2)
    }

    @Test("A cancelled apply stops between items")
    func stopsWhenCancelled() async throws {
        let scratch = try ApplyScratch()
        defer { scratch.remove() }
        let a = try scratch.image("a.png", .rampWithCorner)
        let b = try scratch.image("b.png", .rampWithCorner)
        var review = SimilarReviewState(scan: scan([pair(a, b)], root: scratch.tree))
        review.confirm(.keepA)
        let plan = SimilarApplyPlan.from(review)

        let runner = SimilarApplyRunner(state: scratch.state)
        let task = Task {
            try await runner.run(
                plan, sessionID: instant.identifier, instant: instant,
                disposer: RecordingDisposer())
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

/// A tiny box, because a closure that mutates a local cannot be `@Sendable`.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var total = 0

    func record(done: Int, total: Int) {
        lock.lock()
        self.done = done
        self.total = total
        lock.unlock()
    }

    var lastDone: Int {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var lastTotal: Int {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}
