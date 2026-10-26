import Foundation
import Testing

@testable import DuplicateCore

private func pair(_ a: String, _ b: String, _ kind: MediaKind = .image) -> SimilarPair {
    SimilarPair(fileA: a, fileB: b, similarity: 1.0, mediaKind: kind)
}

private func scan(_ pairs: [SimilarPair], root: String = "/r") -> SimilarScan {
    SimilarScan(
        scanID: "20261025-120000-000000", root: root, createdAt: "t",
        imageThreshold: 5, videoThreshold: 0.7, pairs: pairs
    )
}

/// Three copies of one photo. Files in byte order: "/r/a/photo copy.png", "/r/b/photo.jpg", "/r/c/photo 2.png".
private let threeCopies = [
    pair("/r/a/photo copy.png", "/r/b/photo.jpg"),
    pair("/r/a/photo copy.png", "/r/c/photo 2.png"),
    pair("/r/b/photo.jpg", "/r/c/photo 2.png"),
]

@Suite("SimilarRename")
struct SimilarRenameTests {

    @Test("The kept file takes the other's name in its own folder, and keeps its own extension")
    func buildsTheTarget() {
        #expect(
            SimilarRename(keptPath: "/r/a/photo copy.png", nameFromPath: "/r/b/photo.jpg")
                .targetPath
                == "/r/a/photo.png")
        #expect(
            SimilarRename(keptPath: "/r/a/clip", nameFromPath: "/r/b/movie.mp4").targetPath
                == "/r/a/movie")
        #expect(
            SimilarRename(keptPath: "/r/a/x.mp4", nameFromPath: "/r/b/my.trip").targetPath
                == "/r/a/my.mp4")
        #expect(
            SimilarRename(keptPath: "/r/a/x.mp4", nameFromPath: "/r/b/my.trip.mov").targetPath
                == "/r/a/my.trip.mp4")
        #expect(
            SimilarRename(keptPath: "/r/a/.x.png", nameFromPath: "/r/b/.profile").targetPath
                == "/r/a/.profile.png")
    }

    /// **The undo matches paths by bytes**, so the target has to be the bytes it names: `NSString`'s path methods
    /// collapsed this `//`, and the target stopped being the path the other file left.
    @Test("The target keeps every byte of the folder and of the name")
    func keepsBytes() {
        let target = SimilarRename(
            keptPath: "/T//r/caf\u{00E9} copy.png", nameFromPath: "/T//r/cafe\u{0301}.png"
        ).targetPath
        #expect(Array(target.utf8) == Array("/T//r/cafe\u{0301}.png".utf8))
    }

    @Test("A name that would not change is no rename")
    func detectsNoOps() {
        #expect(SimilarRename(keptPath: "/r/a/x.jpg", nameFromPath: "/r/b/x.jpg").isNoOp)
        #expect(SimilarRename(keptPath: "/r/a/x.jpg", nameFromPath: "/r/b/x.png").isNoOp)
        #expect(!SimilarRename(keptPath: "/r/a/X.jpg", nameFromPath: "/r/b/x.jpg").isNoOp)
    }

    @Test("The document round-trips, and one from a future layout is refused")
    func roundTrips() throws {
        let document = SimilarRenamesDocument(renames: [
            SimilarRename(keptPath: "/r/a/caf\u{00E9}.png", nameFromPath: "/r/b/cafe\u{0301}.png")
        ])
        let data = try JSONWriter.document(SimilarRenamesCodec.encode(document))
        let decoded = try SimilarRenamesCodec.decode(JSONReader.parse(data))
        // Byte for byte: the NFC and the NFD spelling stay what they were.
        #expect(Array(decoded.renames[0].keptPath.utf8) == Array("/r/a/caf\u{00E9}.png".utf8))
        #expect(Array(decoded.renames[0].nameFromPath.utf8) == Array("/r/b/cafe\u{0301}.png".utf8))

        let future = try JSONReader.parse(Data(#"{"format_version": 2, "renames": []}"#.utf8))
        #expect(throws: (any Error).self) { try SimilarRenamesCodec.decode(future) }
    }
}

@Suite("SimilarReviewState names")
struct SimilarReviewNameTests {

    @Test("A group keeping one file can take another member's name")
    func choosesAName() {
        var state = SimilarReviewState(scan: scan(threeCopies))
        state.confirmGroup(0, keep: [0])
        #expect(state.nameSource(inGroup: 0) == nil)
        let outcome1 = state.setNameSource(1, inGroup: 0)

        #expect(outcome1)
        #expect(state.nameSource(inGroup: 0) == 1)
        #expect(
            state.rename(inGroup: 0)
                == SimilarRename(keptPath: "/r/a/photo copy.png", nameFromPath: "/r/b/photo.jpg"))
        #expect(state.renamePlan.map(\.targetPath) == ["/r/a/photo.png"])

        // The kept file's own name is the way back.
        let outcome2 = state.setNameSource(0, inGroup: 0)

        #expect(outcome2)
        #expect(state.nameSource(inGroup: 0) == nil)
        #expect(state.renamePlan.isEmpty)
    }

    /// **Stored as chosen, checked when read**: keeping a second file sets the name aside, keeping one again brings it
    /// back -- and with two kept, there is no file to give a name to.
    @Test("Keeping a second file sets the name aside, and refuses a new one")
    func setsAsideWithTwoKept() {
        var state = SimilarReviewState(scan: scan(threeCopies))
        state.confirmGroup(0, keep: [0])
        state.setNameSource(1, inGroup: 0)
        let outcome3 = state.toggleKeep(2, inGroup: 0)

        #expect(outcome3)
        #expect(state.nameSource(inGroup: 0) == nil)
        let outcome4 = state.setNameSource(1, inGroup: 0)

        #expect(!outcome4)
        let outcome5 = state.toggleKeep(2, inGroup: 0)

        #expect(outcome5)
        #expect(state.nameSource(inGroup: 0) == 1)
    }

    /// A name is not a decision. It is saved so it survives the window, and planned only once its group is decided.
    @Test("An undecided group's name is saved, and planned only after the group is decided")
    func plansOnlyDecidedGroups() throws {
        var state = SimilarReviewState(scan: scan(threeCopies))
        let kept = try #require(state.effectiveKeep(inGroup: 0).first)
        let other = (kept + 1) % 3
        let outcome6 = state.setNameSource(other, inGroup: 0)

        #expect(outcome6)
        #expect(state.renamesForSaving.renames.count == 1)
        #expect(state.renamePlan.isEmpty)
        #expect(SimilarApplyPlan.from(state).isEmpty)
        state.confirmGroup(0)
        #expect(state.renamePlan.count == 1)
    }

    @Test("A name saved earlier comes back, and one whose files are not in one group is dropped")
    func rehydrates() {
        let state = SimilarReviewState(
            scan: scan(threeCopies + [pair("/r/x.png", "/r/y.png")]),
            priorRenames: [
                SimilarRename(keptPath: "/r/a/photo copy.png", nameFromPath: "/r/c/photo 2.png"),
                SimilarRename(keptPath: "/r/x.png", nameFromPath: "/r/b/photo.jpg"),
            ])
        #expect(state.groups.count == 2)
        // Group 0's suggestion keeps one file; whether the name shows depends on which, so read the stored choice
        // through a state that keeps the file the rename names.
        var decided = state
        decided.confirmGroup(0, keep: [0])
        #expect(decided.nameSource(inGroup: 0) == 2)
        #expect(decided.nameSource(inGroup: 1) == nil)
    }

    /// A choice of name changes what the apply does, so it changes the plan the dry run approved.
    @Test("The plan carries the rename, and choosing a name changes its fingerprint")
    func fingerprintsTheName() {
        var state = SimilarReviewState(scan: scan(threeCopies))
        state.confirmGroup(0, keep: [0])
        let before = SimilarApplyPlan.from(state)
        state.setNameSource(1, inGroup: 0)
        let after = SimilarApplyPlan.from(state)
        #expect(before.renames.isEmpty)
        #expect(after.renames.map(\.nameFromPath) == ["/r/b/photo.jpg"])
        #expect(before.items == after.items)
        #expect(before.fingerprint != after.fingerprint)
    }
}

@Suite("UndoPlanner renames")
struct UndoPlannerRenameTests {

    private func entry(
        _ original: String, _ resulting: String, _ mechanism: DisposalMechanism, _ digest: Digest32
    ) -> JournalEntry {
        JournalEntry(
            originalPath: original, resultingPath: resulting, mechanism: mechanism, byteCount: 0,
            digest: digest, groupKey: "k", scanID: "s", timestamp: "t")
    }

    private let photo = Digest32(hexString: String(repeating: "a", count: 64))!
    private let copy = Digest32(hexString: String(repeating: "b", count: 64))!

    /// After `x.png` went to the Trash and `x copy.png` took its name. The filesystem as it is now.
    private func environment(renamedFileDigest: Digest32? = nil) -> UndoPlanner.Environment {
        let files: [String: Digest32] = [
            "/trash/x.png": photo, "/r/x.png": renamedFileDigest ?? copy,
        ]
        return UndoPlanner.Environment(
            exists: { files[$0] != nil || $0 == "/r" || $0 == "/trash" },
            isDirectory: { $0 == "/r" || $0 == "/trash" },
            digest: { files[$0] })
    }

    private var session: [JournalEntry] {
        [
            entry("/r/x.png", "/trash/x.png", .trash, photo),
            entry("/r/x copy.png", "/r/x.png", .rename, copy),
        ]
    }

    /// **The case the ordering exists for.** Planned in journal order, the trashed photo is blocked by the very file
    /// this undo is about to rename out of its way.
    @Test("The rename is undone first, so the file whose name it took can come back")
    func undoesRenamesFirst() {
        let plan = UndoPlanner.plan(sessionID: "s", entries: session, environment: environment())
        #expect(plan.blocked.isEmpty)
        #expect(plan.restorable.map(\.mechanism) == [.rename, .trash])
    }

    @Test(
        "A rename that cannot be undone keeps the name taken, and the other file is not put over it"
    )
    func blocksBehindABlockedRename() {
        let plan = UndoPlanner.plan(
            sessionID: "s", entries: session,
            environment: environment(
                renamedFileDigest: Digest32(hexString: String(repeating: "c", count: 64))))
        #expect(plan.restorable.isEmpty)
        #expect(plan.blocked.map(\.obstacle) == [.contentChanged, .originalPathOccupied])
    }
}

@Suite("FileIdentity paths")
struct FileIdentityPathTests {

    @Test("Two names of one file are the same file; two files, or a missing one, are not")
    func comparesFiles() throws {
        let root = NSTemporaryDirectory() + "/duplicate-identity-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: root + "/a", contents: Data("a".utf8))
        FileManager.default.createFile(atPath: root + "/b", contents: Data("a".utf8))
        try FileManager.default.linkItem(atPath: root + "/a", toPath: root + "/link")
        #expect(FileIdentity.same(root + "/a", root + "/link"))
        #expect(!FileIdentity.same(root + "/a", root + "/b"))
        #expect(!FileIdentity.same(root + "/a", root + "/missing"))
    }
}

private struct RenameScratch {
    let root: String
    let tree: String
    let state: StateDirectory

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-rename-\(UUID().uuidString)"
        tree = root + "/tree"
        try FileManager.default.createDirectory(
            atPath: tree + "/sub", withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
    }

    /// The same picture at two sizes: alike to the verifier, different bytes to SHA-256.
    @discardableResult
    func image(_ name: String, side: Int = 96) throws -> String {
        try SyntheticImage.write(
            .rampWithCorner, width: side, height: side, format: .png, to: tree + "/" + name)
    }

    func digest(_ path: String) throws -> Digest32 {
        try ContentHasher().fullDigest(atPath: path).digest
    }

    func quarantine(_ session: String) -> QuarantineDisposer {
        QuarantineDisposer(root: root + "/quarantine", sessionID: session)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite("SimilarApplyRunner renames")
struct SimilarApplyRunnerRenameTests {

    private let instant = ScanIdentifier.Instant(
        year: 2026, month: 10, day: 25, hour: 13, minute: 0, second: 0, microsecond: 0)

    /// A review of `photo.png` and `sub/photo copy.png` keeping the copy under the photo's name.
    private func plan(
        _ scratch: RenameScratch, keep kept: String, nameFrom source: String
    )
        throws -> SimilarApplyPlan
    {
        var review = SimilarReviewState(scan: scan([pair(source, kept)], root: scratch.tree))
        let group = try #require(review.groups.first)
        let keep = try #require(group.files.firstIndex(of: kept))
        let name = try #require(group.files.firstIndex(of: source))
        let confirmed = review.confirmGroup(0, keep: [keep])
        #expect(confirmed == .confirmed)
        let outcome7 = review.setNameSource(name, inGroup: 0)

        #expect(outcome7)
        return SimilarApplyPlan.from(review)
    }

    /// **End to end, and back.** The kept file lands on the very path the other file left, so the undo has to put
    /// the rename back first -- the ordering this feature added to the planner -- and both files return byte for byte.
    @Test("The kept file takes the name, is journalled at size 0, and an undo puts both back")
    func renamesAndUndoes() async throws {
        let scratch = try RenameScratch()
        defer { scratch.remove() }
        let photo = try scratch.image("photo.png")
        let copy = try scratch.image("photo copy.png", side: 128)
        let photoDigest = try scratch.digest(photo)
        let copyDigest = try scratch.digest(copy)

        let report = try await SimilarApplyRunner(state: scratch.state).run(
            try plan(scratch, keep: copy, nameFrom: photo), sessionID: instant.identifier,
            instant: instant, disposer: scratch.quarantine(instant.identifier))

        #expect(report.moved.map(\.originalPath) == [photo])
        #expect(report.renamed.map(\.targetPath) == [photo])
        #expect(report.renameRefusals.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: copy))
        #expect(try scratch.digest(photo) == copyDigest, "the copy did not take the name")

        let loaded = try MoveJournal.load(sessionID: instant.identifier, in: scratch.state)
        let renameEntry = try #require(loaded.entries.last)
        #expect(loaded.entries.map(\.mechanism) == [.quarantine, .rename])
        #expect(renameEntry.byteCount == 0, "a rename freed nothing")
        #expect(renameEntry.originalPath == copy)
        #expect(renameEntry.resultingPath == photo)
        #expect(renameEntry.digest == copyDigest)

        let undo = UndoPlanner.plan(
            sessionID: instant.identifier, entries: loaded.entries,
            environment: .live(hasher: ContentHasher()))
        #expect(undo.blocked.isEmpty)
        let undone = UndoRunner().run(undo)
        #expect(undone.failed.isEmpty)
        #expect(try scratch.digest(photo) == photoDigest)
        #expect(try scratch.digest(copy) == copyDigest)
    }

    /// **Never overwritten.** The filesystem itself refuses the name, and the file holding it is untouched.
    @Test("A name something else holds is refused, and that file is left as it was")
    func refusesATakenName() async throws {
        let scratch = try RenameScratch()
        defer { scratch.remove() }
        let photo = try scratch.image("photo.png")
        let copy = try scratch.image("sub/photo copy.png", side: 128)
        let squatter = scratch.tree + "/sub/photo.png"
        FileManager.default.createFile(atPath: squatter, contents: Data("mine".utf8))

        let report = try await SimilarApplyRunner(state: scratch.state).run(
            try plan(scratch, keep: copy, nameFrom: photo), sessionID: instant.identifier,
            instant: instant, disposer: scratch.quarantine(instant.identifier))

        #expect(report.moved.count == 1)
        #expect(report.renamed.isEmpty)
        #expect(report.renameRefusals.map(\.reason) == [.nameTaken])
        #expect(FileManager.default.contents(atPath: squatter) == Data("mine".utf8))
        #expect(FileManager.default.fileExists(atPath: copy))
        let loaded = try MoveJournal.load(sessionID: instant.identifier, in: scratch.state)
        #expect(loaded.entries.map(\.mechanism) == [.quarantine])
    }

    /// The name is free only once its file has left. One refused by the verification keeps it.
    @Test("A name whose file stayed is not taken")
    func refusesWhileTheSourceStays() async throws {
        let scratch = try RenameScratch()
        defer { scratch.remove() }
        let photo = try scratch.image("photo.png")
        let copy = try scratch.image("sub/photo copy.png", side: 128)
        let plan = try plan(scratch, keep: copy, nameFrom: photo)
        // Changed since the scan, so the verification leaves it where it is.
        _ = try SyntheticImage.write(
            .checkerboard(square: 3), width: 96, height: 96, format: .png, to: photo)

        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant,
            disposer: scratch.quarantine(instant.identifier))

        #expect(report.moved.isEmpty)
        #expect(report.renameRefusals.map(\.reason) == [.nameSourceStayed])
        #expect(FileManager.default.fileExists(atPath: copy))
        #expect(report.journalPath == nil)
    }

    @Test("A rename the filesystem refuses is a failure, and the file keeps its name")
    func reportsAFailedRename() async throws {
        let scratch = try RenameScratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scratch.tree + "/sub")
            scratch.remove()
        }
        let photo = try scratch.image("photo.png")
        let copy = try scratch.image("sub/photo copy.png", side: 128)
        let plan = try plan(scratch, keep: copy, nameFrom: photo)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: scratch.tree + "/sub")

        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant,
            disposer: scratch.quarantine(instant.identifier))

        #expect(report.moved.count == 1)
        #expect(report.renamed.isEmpty)
        let failure = try #require(report.failures.first)
        guard case .renameFailed(let path, _) = failure.reason else {
            Issue.record("wrong failure: \(failure.reason)")
            return
        }
        #expect(path == copy)
        #expect(FileManager.default.fileExists(atPath: copy))
    }

    /// **Cancelled after the name came free**: the file whose name it was is already gone, so only the cancellation
    /// keeps the rename from running. Cancelled earlier, the file would still be there and hold its name anyway.
    @Test("A run cancelled after the name came free renames nothing")
    func skipsRenamesWhenCancelled() async throws {
        let scratch = try RenameScratch()
        defer { scratch.remove() }
        let photo = try scratch.image("photo.png")
        let copy = try scratch.image("sub/photo copy.png", side: 128)
        let plan = try plan(scratch, keep: copy, nameFrom: photo)
        let runner = SimilarApplyRunner(state: scratch.state, hasher: CancellingHasher())
        let disposer = scratch.quarantine(instant.identifier)
        let instant = instant
        let report = try await Task {
            try await runner.run(
                plan, sessionID: instant.identifier, instant: instant, disposer: disposer)
        }.value
        #expect(report.moved.map(\.originalPath) == [photo], "the name never came free")
        #expect(report.wasCancelled)
        #expect(report.renamed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: copy))
    }

    /// **Stopped after one group's file left.** Twenty failures in a row stop the run, and that one group's name is
    /// free -- but a stopped run is not the plan the user approved.
    @Test("A run stopped by failures renames nothing, even where the name came free")
    func skipsRenamesWhenStopped() async throws {
        let scratch = try RenameScratch()
        defer { scratch.remove() }
        var pairs: [SimilarPair] = []
        for index in 0...SimilarApplyRunner.consecutiveFailureLimit {
            pairs.append(
                pair(
                    try scratch.image("p\(index).png"),
                    try scratch.image("sub/p\(index) copy.png", side: 128)))
        }
        var review = SimilarReviewState(scan: scan(pairs, root: scratch.tree))
        for (index, group) in review.groups.enumerated() {
            let keep = try #require(group.files.firstIndex { $0.hasSuffix(" copy.png") })
            _ = review.confirmGroup(index, keep: [keep])
            _ = review.setNameSource(1 - keep, inGroup: index)
        }
        let plan = SimilarApplyPlan.from(review)
        #expect(plan.renames.count == pairs.count)

        let report = try await SimilarApplyRunner(state: scratch.state).run(
            plan, sessionID: instant.identifier, instant: instant,
            disposer: OnceDisposer(scratch.quarantine(instant.identifier)))
        #expect(report.moved.count == 1)
        #expect(report.stoppedEarly)
        #expect(report.renamed.isEmpty)
        #expect(report.renameRefusals.isEmpty)
    }
}

/// Hashes like the real one, and cancels the task that asked -- after answering, so the file it read still moves.
private struct CancellingHasher: FileHashing {
    func usesPrefixStage(forSize size: Int64) -> Bool { false }
    func prefixDigest(atPath path: String, size: Int64) throws -> Digest32 {
        try ContentHasher().prefixDigest(atPath: path, size: size)
    }
    func fullDigest(atPath path: String) throws -> HashResult {
        defer { withUnsafeCurrentTask { $0?.cancel() } }
        return try ContentHasher().fullDigest(atPath: path)
    }
}

/// Moves the first file it is given, and refuses every one after.
private final class OnceDisposer: ItemDisposing, @unchecked Sendable {
    private let first: any ItemDisposing
    private var used = false

    init(_ first: any ItemDisposing) { self.first = first }

    func dispose(path: String) throws -> DisposalOutcome {
        guard !used else { throw DisposalError.trashUnavailable(path: path, reason: "refused") }
        used = true
        return try first.dispose(path: path)
    }
}

@Suite("UndoPlanner case-only renames")
struct UndoCaseOnlyRenameTests {

    /// On a volume that ignores case, the old name answers for the renamed file. Read as "already back", the undo
    /// would report a restore it never made.
    @Test("A rename that only changed case is put back, not reported as already there")
    func undoesCaseOnly() throws {
        let root = NSTemporaryDirectory() + "/duplicate-case-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        FileManager.default.createFile(atPath: root + "/IMG.png", contents: Data("x".utf8))
        let digest = try ContentHasher().fullDigest(atPath: root + "/IMG.png").digest
        try FileManager.default.moveItem(atPath: root + "/IMG.png", toPath: root + "/img.png")
        let entry = JournalEntry(
            originalPath: root + "/IMG.png", resultingPath: root + "/img.png", mechanism: .rename,
            byteCount: 0, digest: digest, groupKey: "k", scanID: "s", timestamp: "t")

        let plan = UndoPlanner.plan(
            sessionID: "s", entries: [entry], environment: .live(hasher: ContentHasher()))
        #expect(plan.alreadyRestored.isEmpty)
        #expect(plan.restorable == [entry])
        #expect(UndoRunner().run(plan).failed.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["IMG.png"])
    }
}

@Suite("ScanStore renames")
struct ScanStoreRenameTests {

    @Test("Names are saved beside the scan, removed when none is left, and deleted with it")
    func savesAndDeletes() throws {
        let root = NSTemporaryDirectory() + "/duplicate-renames-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)
        let id = "20261025-120000-000000"
        let path = try state.filePath(for: .similarRenames, id: id)
        let rename = SimilarRename(keptPath: "/r/a.png", nameFromPath: "/r/b.png")

        #expect(store.priorSimilarRenames(scanID: id).isEmpty)
        try store.save(SimilarRenamesDocument(renames: [rename]), scanID: id)
        #expect(store.priorSimilarRenames(scanID: id) == [rename])

        try store.save(SimilarRenamesDocument(renames: []), scanID: id)
        #expect(!FileManager.default.fileExists(atPath: path))

        try store.save(SimilarRenamesDocument(renames: [rename]), scanID: id)
        _ = try store.deleteSimilarScan(id: id)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
