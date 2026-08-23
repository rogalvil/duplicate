import Foundation
import Testing

@testable import DuplicateCore

private struct PrunerScratch {
    let root: String
    let state: StateDirectory

    init() throws {
        root = NSTemporaryDirectory() + "duplicate-prune-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    func entry(_ name: String) -> JournalEntry {
        JournalEntry(
            originalPath: "/tree/\(name)",
            resultingPath: "/trash/\(name)",
            mechanism: .trash,
            byteCount: 10,
            digest: Digest32(hexString: String(repeating: "a", count: 64))!,
            groupKey: "10:aaa",
            scanID: "20260812-120000-000000",
            timestamp: "2026-08-12T12:00:00.000000Z"
        )
    }
}

@Suite("JournalPruner")
struct JournalPrunerTests {

    @Test("A session whose files were all put back is prunable; one that was not is untouched")
    func prunesOnlyFullyRestored() throws {
        let scratch = try PrunerScratch()
        defer { scratch.remove() }

        // Session A: two files moved, both restored. The undo already ran, so the journal has nothing left
        // to offer -- and its own records are what prove it, which is what makes this rule provable rather
        // than probable.
        _ = try MoveJournal.append(
            [scratch.entry("a1"), scratch.entry("a2")], sessionID: "20260812-120000-000000",
            in: scratch.state)
        for name in ["a1", "a2"] {
            _ = try MoveJournal.appendRestoration(
                of: scratch.entry(name), at: "2026-08-13T09:00:00.000000Z",
                sessionID: "20260812-120000-000000", in: scratch.state)
        }

        // Session B: two moved, one restored. Still holds the only record of where the other one went.
        _ = try MoveJournal.append(
            [scratch.entry("b1"), scratch.entry("b2")], sessionID: "20260812-130000-000000",
            in: scratch.state)
        _ = try MoveJournal.appendRestoration(
            of: scratch.entry("b1"), at: "2026-08-13T09:00:00.000000Z",
            sessionID: "20260812-130000-000000", in: scratch.state)

        let plan = JournalPruner.plan(in: scratch.state)
        #expect(plan.sessions.count == 2)
        #expect(plan.prunable.map(\.sessionID) == ["20260812-120000-000000"])
        #expect(plan.stillUndoable.map(\.sessionID) == ["20260812-130000-000000"])
        #expect(plan.reclaimableBytes > 0)

        let removed = JournalPruner.prune(plan, in: scratch.state)
        #expect(removed.map(\.sessionID) == ["20260812-120000-000000"])
        #expect(MoveJournal.sessions(in: scratch.state) == ["20260812-130000-000000"])

        // And the survivor still reads: pruning one journal cannot disturb another.
        let survivor = try MoveJournal.load(
            sessionID: "20260812-130000-000000", in: scratch.state)
        #expect(survivor.entries.count == 2)
        #expect(survivor.restoredPaths == ["/tree/b1"])
    }

    @Test("An empty or unparseable journal is not prunable")
    func leavesNothingToGoOn() throws {
        let scratch = try PrunerScratch()
        defer { scratch.remove() }

        // **Not prunable on purpose.** A journal with no entries is either a session that moved nothing or a
        // file this build could not parse; deleting it gains nothing and destroys the only evidence of the
        // second case.
        let path = try MoveJournal.url(sessionID: "20260812-140000-000000", in: scratch.state)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this is not a journal\n{oops\n".utf8).write(to: path)

        let plan = JournalPruner.plan(in: scratch.state)
        #expect(plan.prunable.isEmpty)
        #expect(plan.unreadable.map(\.sessionID) == ["20260812-140000-000000"])
        #expect(JournalPruner.prune(plan, in: scratch.state).isEmpty)
        #expect(MoveJournal.sessions(in: scratch.state) == ["20260812-140000-000000"])
    }

    @Test("A restoration record for a path the journal never moved does not count")
    func ignoresForeignRestorations() throws {
        let scratch = try PrunerScratch()
        defer { scratch.remove() }

        // Counted against the entries, not against the restoration records: a record naming a path this
        // journal never moved says the journal is not what it claims to be, and letting it satisfy the count
        // would make a file's only record deletable by an unrelated line.
        _ = try MoveJournal.append(
            [scratch.entry("real")], sessionID: "20260812-150000-000000", in: scratch.state)
        _ = try MoveJournal.appendRestoration(
            of: scratch.entry("somewhere-else"), at: "2026-08-13T09:00:00.000000Z",
            sessionID: "20260812-150000-000000", in: scratch.state)

        let plan = JournalPruner.plan(in: scratch.state)
        #expect(plan.prunable.isEmpty, "a foreign restoration made a live journal prunable")
        let session = try #require(plan.sessions.first)
        #expect(session.movedCount == 1)
        #expect(session.restoredCount == 0)
    }

    @Test("The real state directory is never touched by these tests")
    func staysInTemporary() throws {
        let scratch = try PrunerScratch()
        defer { scratch.remove() }
        #expect(scratch.state.path(for: .journal).hasPrefix(NSTemporaryDirectory()))
    }
}

@Suite("UndoPreflight")
struct UndoPreflightTests {

    /// **A directory's digest is its manifest, and it has to come from somewhere that can await the cache.**
    /// Building it inside the planner's synchronous environment meant hashing the whole folder on the calling
    /// thread with no cache: measured at 979 MB/s over 200 three-megabyte files, which is 33.8 seconds for a
    /// 10,506-file photo folder -- right after the apply that put those digests in the cache.
    @Test("The preflight digests the directories a journal moved, and skips the files")
    func digestsDirectoriesOnly() async throws {
        let scratch = try PrunerScratch()
        defer { scratch.remove() }
        let manager = FileManager.default

        let folder = scratch.root + "/moved-folder"
        try manager.createDirectory(atPath: folder + "/sub", withIntermediateDirectories: true)
        try Data("one".utf8).write(to: URL(filePath: folder + "/one.txt"))
        try Data("two".utf8).write(to: URL(filePath: folder + "/sub/two.txt"))
        let loose = scratch.root + "/loose.txt"
        try Data("loose".utf8).write(to: URL(filePath: loose))

        let entries = [
            JournalEntry(
                originalPath: folder, resultingPath: folder, mechanism: .trash, byteCount: 6,
                digest: Digest32(hexString: String(repeating: "b", count: 64))!,
                groupKey: "folder", scanID: "s", timestamp: "2026-08-12T12:00:00.000000Z"),
            JournalEntry(
                originalPath: loose, resultingPath: loose, mechanism: .trash, byteCount: 5,
                digest: Digest32(hexString: String(repeating: "c", count: 64))!,
                groupKey: "file", scanID: "s", timestamp: "2026-08-12T12:00:00.000000Z"),
        ]

        let digests = await UndoPreflight.directoryDigests(for: entries)
        #expect(
            digests.count == 1,
            "the preflight digested \(digests.count) paths, wanted the folder only")
        let manifest = try await FolderManifest.build(root: folder)
        #expect(digests[DirectoryTree.canonical(folder)] == manifest.digest)
        #expect(digests[DirectoryTree.canonical(loose)] == nil, "a file was treated as a directory")
    }

    /// Without the preflight, a folder restore blocks rather than acting.
    ///
    /// **The safe direction, and the one a forgotten preflight gets.** An absent digest means "could not
    /// verify", and this planner never acts on something it could not verify -- the alternative is restoring a
    /// folder whose contents changed while it sat in the Trash.
    @Test("A directory with no precomputed digest is blocked, not restored")
    func blocksWithoutTheirDigests() async throws {
        let scratch = try PrunerScratch()
        defer { scratch.remove() }
        let folder = scratch.root + "/trashed"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: URL(filePath: folder + "/a.txt"))

        let entry = JournalEntry(
            originalPath: scratch.root + "/gone", resultingPath: folder, mechanism: .trash,
            byteCount: 6, digest: try await FolderManifest.build(root: folder).digest,
            groupKey: "folder", scanID: "s", timestamp: "2026-08-12T12:00:00.000000Z")

        let without = UndoPlanner.plan(
            sessionID: "20260812-120000-000000", entries: [entry], restoredPaths: [],
            environment: .live(hasher: ContentHasher()))
        #expect(
            without.restorable.isEmpty,
            "a folder was planned for restore with no digest to verify it")
        // **Blocked as unverifiable, not as changed.** `contentChanged` would tell the user something about
        // their data that nobody established: the digest was never computed.
        #expect(without.blocked.map(\.obstacle) == [.unverifiable])

        let digests = await UndoPreflight.directoryDigests(for: [entry])
        let with = UndoPlanner.plan(
            sessionID: "20260812-120000-000000", entries: [entry], restoredPaths: [],
            environment: .live(hasher: ContentHasher(), directoryDigests: digests))
        #expect(with.restorable.count == 1, "the folder was not planned even with its digest")
    }
}
