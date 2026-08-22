import Foundation
import Synchronization
import Testing

@testable import DuplicateCore

private func folderPair(
    _ a: String, _ b: String, similarity: Double = 1.0, totalA: Int = 3, totalB: Int = 3
) -> FolderPair {
    FolderPair(
        folderA: a, folderB: b, similarity: similarity, matching: min(totalA, totalB),
        onlyInA: [], onlyInB: [], changed: [], totalA: totalA, totalB: totalB
    )
}

private func folderScan(_ pairs: [FolderPair], root: String = "/r") -> FolderScan {
    FolderScan(
        scanID: "20260818-120000-000000", root: root, createdAt: "t", threshold: 0.9, pairs: pairs)
}

private let noon = ScanIdentifier.Instant(
    year: 2026, month: 8, day: 18, hour: 12, minute: 0, second: 0, microsecond: 0)

private struct FolderScratch {
    let root: String
    let tree: String
    let state: StateDirectory

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-folderapply-\(UUID().uuidString)"
        tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> String {
        let path = tree + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: URL(filePath: path))
        return path
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private final class RecordingDisposer: ItemDisposing, @unchecked Sendable {
    private(set) var disposed: [String] = []
    func dispose(path: String) throws -> DisposalOutcome {
        disposed.append(path)
        return DisposalOutcome(
            originalPath: path, resultingPath: "/trash/" + (path as NSString).lastPathComponent,
            mechanism: .trash, byteCount: 100)
    }
}

@Suite("FolderDecisionsCodec")
struct FolderDecisionsCodecTests {

    /// **A third shape**: wrapped like `decisions/`, keyed like `similar-decisions/`.
    @Test("The document is wrapped and keyed by pair")
    func writesTheWrappedShape() throws {
        let document = FolderDecisionsDocument(
            scanID: "20260818-120000-000000", createdAt: "2026-08-18T12:00:00Z",
            decisions: [(key: "/a||/b", keptPaths: ["/a"])]
        )
        let text = String(
            decoding: try JSONWriter.document(FolderDecisionsCodec.encode(document)), as: UTF8.self)
        #expect(text.contains("\"scan_id\""))
        #expect(text.contains("\"created_at\""))
        #expect(text.contains("\"decisions\""))
        #expect(text.contains("\"/a||/b\""))
        let decoded = try FolderDecisionsCodec.decode(JSONReader.parse(Data(text.utf8)))
        #expect(decoded == document)
    }

    @Test("Key order survives, so a re-encode is byte-identical")
    func preservesOrder() throws {
        let document = FolderDecisionsDocument(
            scanID: "20260818-120000-000000", createdAt: "t",
            decisions: [
                (key: "/z||/y", keptPaths: ["/z"]), (key: "/a||/b", keptPaths: ["/a", "/b"]),
            ]
        )
        let encoded = try JSONWriter.document(FolderDecisionsCodec.encode(document))
        let decoded = try FolderDecisionsCodec.decode(JSONReader.parse(encoded))
        #expect(decoded.decisions.map(\.key) == ["/z||/y", "/a||/b"])
        #expect(try JSONWriter.document(FolderDecisionsCodec.encode(decoded)) == encoded)
    }

    @Test("A missing field is reported by name")
    func reportsMissingFields() {
        let value = JSONValue.object([
            JSONMember(key: "scan_id", value: .string("20260818-120000-000000"))
        ])
        #expect(throws: ScanDecodingError.missingField("created_at")) {
            try FolderDecisionsCodec.decode(value)
        }
    }
}

@Suite("FolderManifest")
struct FolderManifestTests {

    @Test("A manifest lists every file by relative path")
    func listsFiles() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        try scratch.write("a/one.txt", "first")
        try scratch.write("a/sub/two.txt", "second")

        let manifest = try await FolderManifest.build(root: scratch.tree + "/a")
        #expect(manifest.fileCount == 2)
        #expect(manifest.entries.keys.sorted() == ["one.txt", "sub/two.txt"])
    }

    /// **The check that makes deleting a folder verifiable.**
    @Test("A file the keeper lacks is named")
    func namesWhatWouldBeLost() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["a", "b"] {
            try scratch.write("\(folder)/one.txt", "first")
            try scratch.write("\(folder)/two.txt", "second")
        }
        try scratch.write("b/only-here.txt", "unique")

        let a = try await FolderManifest.build(root: scratch.tree + "/a")
        let b = try await FolderManifest.build(root: scratch.tree + "/b")
        #expect(b.filesMissing(from: a) == ["only-here.txt"])
        #expect(a.filesMissing(from: b).isEmpty, "a is contained in b")
    }

    /// Same name, different bytes, is a loss too -- and the digest is what catches it.
    @Test("A file with the same name and different content counts as missing")
    func catchesChangedContent() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        try scratch.write("a/one.txt", "first")
        try scratch.write("b/one.txt", "DIFFERENT")

        let a = try await FolderManifest.build(root: scratch.tree + "/a")
        let b = try await FolderManifest.build(root: scratch.tree + "/b")
        #expect(b.filesMissing(from: a) == ["one.txt"])
    }

    /// The journal needs one digest for a whole tree, and it has to move when anything inside does.
    @Test("The manifest digest changes with any file inside")
    func digestsTheWholeTree() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        try scratch.write("a/one.txt", "first")
        let before = try await FolderManifest.build(root: scratch.tree + "/a").digest

        try scratch.write("a/one.txt", "edited")
        let edited = try await FolderManifest.build(root: scratch.tree + "/a").digest
        #expect(edited != before)

        try scratch.write("a/one.txt", "first")
        try scratch.write("a/two.txt", "added")
        let added = try await FolderManifest.build(root: scratch.tree + "/a").digest
        #expect(added != before)
    }
}

@Suite("FolderApplyPlan")
struct FolderApplyPlanTests {

    @Test("An untouched review plans nothing")
    func plansNothingUntouched() {
        let state = FolderReviewState(scan: folderScan([folderPair("/r/a", "/r/b")]))
        #expect(FolderApplyPlan.from(state).isEmpty)
    }

    /// **The CLI moves folder_b of every pair it found, reviewed or not.** Here an undecided pair does nothing.
    @Test("An undecided pair is not acted on")
    func ignoresUndecidedPairs() {
        var state = FolderReviewState(
            scan: folderScan([folderPair("/r/a", "/r/b"), folderPair("/r/c", "/r/d")]))
        state.keep("/r/a", at: 0)
        let plan = FolderApplyPlan.from(state)
        #expect(plan.items.map(\.path) == ["/r/b"])
        #expect(state.tally == (decided: 1, skipped: 0, undecided: 1))
    }

    @Test("Keeping both moves neither")
    func keepBothMovesNothing() {
        var state = FolderReviewState(scan: folderScan([folderPair("/r/a", "/r/b")]))
        state.keepBoth()
        #expect(FolderApplyPlan.from(state).isEmpty)
        #expect(state.tally.decided == 1)
    }

    /// **The nested case, measured on the real corpus**: the 42 pairs include parents and their own children.
    @Test("A descendant of a folder already going is dropped")
    func collapsesNestedPairs() {
        var state = FolderReviewState(
            scan: folderScan([
                folderPair("/r/keep/Pole", "/r/gone/Pole"),
                folderPair("/r/keep/Pole/videos", "/r/gone/Pole/videos"),
            ]))
        state.keep("/r/keep/Pole", at: 0)
        state.keep("/r/keep/Pole/videos", at: 1)
        let plan = FolderApplyPlan.from(state)
        #expect(plan.items.map(\.path) == ["/r/gone/Pole"])
        #expect(plan.collapsed == ["/r/gone/Pole/videos"])
    }

    /// **A folder that contains something another pair keeps cannot go**, and no ordering fixes it.
    @Test("A folder holding a keeper is excluded")
    func excludesFoldersHoldingKeepers() {
        var state = FolderReviewState(
            scan: folderScan([
                folderPair("/r/a", "/r/b"),
                folderPair("/r/b/inner", "/r/c"),
            ]))
        state.keep("/r/a", at: 0)  // would move /r/b
        state.keep("/r/b/inner", at: 1)  // keeps something inside /r/b
        let plan = FolderApplyPlan.from(state)
        #expect(!plan.items.map(\.path).contains("/r/b"))
        #expect(plan.contradicted.contains("/r/b"))
        #expect(plan.items.map(\.path) == ["/r/c"])
    }

    @Test("A folder kept by another pair is excluded")
    func excludesContradictions() {
        var state = FolderReviewState(
            scan: folderScan([folderPair("/r/a", "/r/b"), folderPair("/r/b", "/r/c")]))
        state.keep("/r/a", at: 0)  // moves /r/b
        state.keep("/r/b", at: 1)  // keeps /r/b
        let plan = FolderApplyPlan.from(state)
        #expect(plan.contradicted.contains("/r/b"))
        #expect(plan.items.map(\.path) == ["/r/c"])
    }

    /// **Component-wise, not a string prefix**: `/a/photos` is not inside `/a/photo`.
    @Test("Ancestry is by components")
    func comparesByComponents() {
        #expect(FolderApplyPlan.isAncestor("/a/photo", of: "/a/photo/x"))
        #expect(FolderApplyPlan.isAncestor("/a/photo", of: "/a/photos") == false)
        #expect(FolderApplyPlan.isAncestor("/a/photo", of: "/a/photo") == false)
    }
}

@Suite("FolderApplyRunner")
struct FolderApplyRunnerTests {

    @Test("A contained folder is moved and journalled with its manifest digest")
    func movesAContainedFolder() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["keep", "gone"] {
            try scratch.write("\(folder)/one.txt", "first")
            try scratch.write("\(folder)/sub/two.txt", "second")
        }

        var review = FolderReviewState(
            scan: folderScan(
                [folderPair(scratch.tree + "/keep", scratch.tree + "/gone")], root: scratch.tree))
        review.keep(scratch.tree + "/keep")
        let plan = FolderApplyPlan.from(review)
        let disposer = RecordingDisposer()

        let report = try await FolderApplyRunner(
            state: scratch.state, cacheURL: URL(filePath: scratch.root + "/hashes.v1")
        ).run(plan, sessionID: noon.identifier, instant: noon, disposer: disposer)

        #expect(report.moved.count == 1)
        // **Compared canonically, and the fixture keeps the trap.** `NSTemporaryDirectory()` ends in a slash, so
        // `scratch.tree` carries a double one; the plan canonicalises paths on purpose -- the same trap that once
        // made a folder scan silently find nothing -- so the moved path has a single slash.
        #expect(disposer.disposed == [DirectoryTree.canonical(scratch.tree + "/gone")])
        #expect(report.refused.isEmpty)

        let loaded = try MoveJournal.load(sessionID: noon.identifier, in: scratch.state)
        let entry = try #require(loaded.entries.first)
        let manifest = try await FolderManifest.build(root: scratch.tree + "/keep")
        // The two trees are identical, so the recorded digest is the keeper's manifest too.
        #expect(entry.digest == manifest.digest)
    }

    /// **The refusal this whole design exists for.** A folder that is 95% a copy still has the 5%.
    @Test("A folder holding a file the keeper lacks is refused, with its name")
    func refusesWhatWouldBeLost() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["keep", "gone"] {
            try scratch.write("\(folder)/one.txt", "first")
        }
        try scratch.write("gone/only-here.txt", "the five percent")

        var review = FolderReviewState(
            scan: folderScan(
                [folderPair(scratch.tree + "/keep", scratch.tree + "/gone", similarity: 0.95)],
                root: scratch.tree))
        review.keep(scratch.tree + "/keep")
        let disposer = RecordingDisposer()

        let report = try await FolderApplyRunner(
            state: scratch.state, cacheURL: URL(filePath: scratch.root + "/hashes.v1")
        ).run(
            FolderApplyPlan.from(review), sessionID: noon.identifier, instant: noon,
            disposer: disposer)

        #expect(report.moved.isEmpty)
        #expect(disposer.disposed.isEmpty, "a folder with unique content was moved")
        guard case .wouldLoseFiles(let count, let examples) = report.refused.first?.reason else {
            Issue.record("wrong refusal: \(String(describing: report.refused.first))")
            return
        }
        #expect(count == 1)
        #expect(examples == ["only-here.txt"])
    }

    @Test("A folder that is gone is reported, not treated as a failure")
    func reportsMissingFolders() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        try scratch.write("keep/one.txt", "first")

        var review = FolderReviewState(
            scan: folderScan(
                [folderPair(scratch.tree + "/keep", scratch.tree + "/gone")], root: scratch.tree))
        review.keep(scratch.tree + "/keep")
        let report = try await FolderApplyRunner(
            state: scratch.state, cacheURL: URL(filePath: scratch.root + "/hashes.v1")
        ).run(
            FolderApplyPlan.from(review), sessionID: noon.identifier, instant: noon,
            disposer: RecordingDisposer())
        #expect(report.moved.isEmpty)
        #expect(report.refused.count == 1)
        guard case .missing = report.refused[0].reason else {
            Issue.record("wrong refusal")
            return
        }
    }
}

@Suite("FolderReviewState")
struct FolderReviewStateTests {

    @Test("Only decided pairs are saved")
    func savesOnlyDecided() {
        var state = FolderReviewState(
            scan: folderScan((0..<10).map { folderPair("/r/a\($0)", "/r/b\($0)") }))
        state.keep("/r/a0", at: 0)
        let document = state.decisionsForSaving(instant: noon)
        #expect(document.count == 1)
        #expect(document.scanID == "20260818-120000-000000")
        #expect(state.tally == (decided: 1, skipped: 0, undecided: 9))
    }

    @Test("The suggestion is the first folder, and it is not a decision")
    func suggestsTheFirstFolder() {
        let state = FolderReviewState(scan: folderScan([folderPair("/r/a", "/r/b")]))
        #expect(state.effectiveKeep(at: 0) == ["/r/a"])
        #expect(state.decision(at: 0) == .undecided)
        #expect(state.decisionsForSaving(instant: noon).count == 0)
    }

    @Test("Prior decisions are rehydrated by pair key")
    func rehydrates() {
        let state = FolderReviewState(
            scan: folderScan([folderPair("/r/a", "/r/b")]),
            priorDecisions: ["/r/a||/r/b": ["/r/b"]]
        )
        #expect(state.decision(at: 0) == .decided(keep: ["/r/b"]))
        #expect(state.effectiveKeep(at: 0) == ["/r/b"])
    }

    @Test("Skipping is neither decided nor unseen")
    func skips() {
        var state = FolderReviewState(scan: folderScan([folderPair("/r/a", "/r/b")]))
        state.skip()
        #expect(state.tally == (decided: 0, skipped: 1, undecided: 0))
        #expect(state.decisionsForSaving(instant: noon).count == 0)
    }
}

/// A hasher that cancels its own task partway through, so the cancellation lands *inside* a manifest build.
///
/// **Deliberately not a slow hasher plus a sleep.** The first version of this test did that, and it passed on its
/// own and failed inside the full suite: whether 120 ms of wall clock lands in the middle of 600 ms of hashing
/// depends on machine load, which makes it a race dressed up as a test. Cancelling on the tenth file always lands
/// in the first manifest of a hundred-file folder, and the test runs in milliseconds.
private struct CancellingHasher: FileHashing {
    let after: Int
    private let inner = ContentHasher()
    // A class, because `Atomic` is noncopyable and a `FileHashing` is a value passed by copy.
    private let seen = Counter()

    private final class Counter: Sendable {
        private let value = Atomic<Int>(0)
        func next() -> Int { value.add(1, ordering: .relaxed).newValue }
    }

    init(after: Int) { self.after = after }

    func usesPrefixStage(forSize size: Int64) -> Bool { inner.usesPrefixStage(forSize: size) }

    func prefixDigest(atPath path: String, size: Int64) throws -> Digest32 {
        try inner.prefixDigest(atPath: path, size: size)
    }

    func fullDigest(atPath path: String) throws -> HashResult {
        let count = seen.next()
        if count == after {
            // Cancels the task the runner is on, which the manifest's per-file `checkCancellation` then throws.
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return try inner.fullDigest(atPath: path)
    }
}

@Suite("Cancelling a folder apply")
struct FolderApplyCancellationTests {

    /// **A cancelled manifest is not an unreadable folder.** The `try?` that used to wrap the build filed a
    /// cancellation under "could not be read" -- an accusation about the user's data for something the user just
    /// asked for, and `unreadable` is the refusal that sends someone looking for damage.
    @Test("Cancelling during verification is cancellation, not an unreadable folder")
    func cancellationIsNotUnreadable() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["keep", "gone"] {
            for index in 0..<100 {
                _ = try scratch.write("\(folder)/f\(index).txt", "contents \(index)")
            }
        }

        var review = FolderReviewState(
            scan: folderScan(
                [folderPair(scratch.tree + "/keep", scratch.tree + "/gone")], root: scratch.tree))
        review.keep(scratch.tree + "/keep")
        let plan = FolderApplyPlan.from(review)
        let disposer = RecordingDisposer()

        let report = try await Task {
            try await FolderApplyRunner(
                state: scratch.state, hasher: CancellingHasher(after: 10),
                cacheURL: URL(filePath: scratch.root + "/hashes.v1")
            ).run(plan, sessionID: noon.identifier, instant: noon, disposer: disposer)
        }.value

        #expect(report.wasCancelled)
        #expect(report.moved.isEmpty, "a folder moved after the apply was cancelled")
        #expect(disposer.disposed.isEmpty)
        // The whole point: no refusal at all, and above all not an unreadable one.
        #expect(report.refused.isEmpty, "a cancelled apply reported refusals: \(report.refused)")
    }

    /// **A manifest cut short by a cancellation must never reach the containment check.**
    ///
    /// Measured, and narrower than it first looks. Cancelling on the *doomed* folder's last file is harmless:
    /// the keeper's build starts with its own per-file checkpoint and throws immediately. The reachable case is
    /// the **keeper's** last file -- there is no checkpoint between that and the comparison, so a `try?` there
    /// leaves the keeper short, the doomed folder appears to hold a file the keeper lacks, and the run reports
    /// `wouldLoseFiles` naming a file that is sitting in both folders. Which is the accusation flavour again:
    /// the user pressed Stop and got told their two folders differ.
    @Test("A manifest cut short by a cancellation never reaches the containment check")
    func cancellationOnTheLastFileDoesNotMoveTheFolder() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["keep", "gone"] {
            for index in 0..<5 {
                _ = try scratch.write("\(folder)/f\(index).txt", "contents \(index)")
            }
        }

        var review = FolderReviewState(
            scan: folderScan(
                [folderPair(scratch.tree + "/keep", scratch.tree + "/gone")], root: scratch.tree))
        review.keep(scratch.tree + "/keep")
        let plan = FolderApplyPlan.from(review)
        let disposer = RecordingDisposer()

        // Five files each, doomed hashed first, so the tenth hash is the keeper's last one.
        let report = try await Task {
            try await FolderApplyRunner(
                state: scratch.state, hasher: CancellingHasher(after: 10),
                cacheURL: URL(filePath: scratch.root + "/hashes.v1")
            ).run(plan, sessionID: noon.identifier, instant: noon, disposer: disposer)
        }.value

        #expect(report.wasCancelled)
        #expect(
            disposer.disposed.isEmpty,
            "a folder was moved on a manifest cut short by a cancellation")
        #expect(report.moved.isEmpty)
        #expect(
            report.refused.isEmpty,
            "a cancellation was reported as the two folders differing: \(report.refused)")
        #expect(
            FileManager.default.fileExists(atPath: scratch.tree + "/gone/f4.txt"),
            "the folder left the disk")
    }
}
