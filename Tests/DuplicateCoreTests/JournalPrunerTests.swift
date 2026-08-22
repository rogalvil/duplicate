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
