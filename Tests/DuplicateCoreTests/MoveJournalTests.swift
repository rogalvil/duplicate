import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private func journalEntry(
    original: String = "/x/a.bin",
    resulting: String = "/Users/t/.Trash/a.bin",
    mechanism: DisposalMechanism = .trash,
    size: Int64 = 1000,
    seed: String = "a"
) -> JournalEntry {
    JournalEntry(
        originalPath: original,
        resultingPath: resulting,
        mechanism: mechanism,
        byteCount: size,
        digest: digest(seed),
        groupKey: "\(size):\(digest(seed).hexString)",
        scanID: "20260511-064716-685054",
        timestamp: "2026-05-11T06:47:16.685054Z"
    )
}

/// A state directory in a temp dir, so no test touches the real one.
private struct JournalScratch {
    let directory: String
    let state: StateDirectory

    init() throws {
        directory = NSTemporaryDirectory() + "/duplicate-journal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        state = StateDirectory(
            environment: ["XDG_STATE_HOME": directory],
            homePath: "/Users/tester"
        )
    }

    func remove() { try? FileManager.default.removeItem(atPath: directory) }

    func raw(_ sessionID: String) throws -> String {
        let path = try state.filePath(for: .journal, id: sessionID, extension: "jsonl")
        return String(decoding: FileManager.default.contents(atPath: path) ?? Data(), as: UTF8.self)
    }

    func write(_ sessionID: String, _ text: String) throws {
        try state.create(.journal)
        try Data(text.utf8).write(
            to: URL(filePath: try state.filePath(for: .journal, id: sessionID, extension: "jsonl"))
        )
    }
}

@Suite("MoveJournal")
struct MoveJournalTests {
    let session = "20260511-070000-000001"

    @Test("Each entry is one compact line")
    func eachEntryIsOneLine() throws {
        // JSON Lines, not a JSON array: a pretty-printed array cannot be appended to without rewriting it,
        // and a crash mid-write has to leave every prior entry readable.
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        try MoveJournal.append(
            [journalEntry(original: "/x/1"), journalEntry(original: "/x/2")],
            sessionID: session,
            in: scratch.state
        )
        let text = try scratch.raw(session)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        #expect(!text.contains("\n  "), "a line was pretty-printed")
        #expect(text.hasSuffix("\n"))
    }

    @Test("The file lands under journal/, with a .jsonl extension")
    func fileLandsInJournalDirectory() throws {
        // The extension is the honest signal that this is not the CLI's format: the CLI performs a
        // different action and has no concept of a journal.
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        let url = try MoveJournal.url(sessionID: session, in: scratch.state)
        #expect(url.path(percentEncoded: false).hasSuffix("/duplicate/journal/\(session).jsonl"))
    }

    @Test("Appending twice keeps both batches")
    func appendingIsCumulative() throws {
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        try MoveJournal.append(
            [journalEntry(original: "/x/1")], sessionID: session, in: scratch.state)
        try MoveJournal.append(
            [journalEntry(original: "/x/2")], sessionID: session, in: scratch.state)
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.map(\.originalPath) == ["/x/1", "/x/2"])
        #expect(loaded.isClean)
    }

    @Test("Every field survives the round trip")
    func fieldsRoundTrip() throws {
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        let entry = journalEntry(
            // a decomposed path, which the corpus really contains
            original: "/x/Sua\u{0301}rez.mp4",
            resulting: "/Volumes/WD12TB/.Trashes/501/Sua\u{0301}rez.mp4",
            mechanism: .quarantine,
            size: 496_243_319,
            seed: "e"
        )
        try MoveJournal.append([entry], sessionID: session, in: scratch.state)
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries == [entry])
        // The path is escaped the same way the shared scan format escapes it, so the two files can
        // be read side by side when an undo is planned. This path is decomposed, so the 'a' stays
        // literal and only the combining acute becomes an escape.
        let raw = try scratch.raw(session)
        #expect(raw.contains("Sua"), "escaping changed: \(raw.prefix(160))")
        #expect(raw.contains("u0301rez"), "the combining mark was not escaped")
    }

    @Test("A torn final line costs that line and nothing else")
    func toleratesTornFinalLine() throws {
        // The whole point of appending line by line. A crash mid-write must not cost the session's history.
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        try MoveJournal.append(
            [journalEntry(original: "/x/1"), journalEntry(original: "/x/2")],
            sessionID: session,
            in: scratch.state
        )
        var text = try scratch.raw(session)
        text += String(try MoveJournal.encode(journalEntry(original: "/x/3")).prefix(40))
        try scratch.write(session, text)

        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.map(\.originalPath) == ["/x/1", "/x/2"])
        #expect(loaded.malformedLines == [3])
        #expect(!loaded.isClean)
    }

    @Test("A journal from a future layout is refused, not half-read")
    func refusesFutureFormat() throws {
        // Its fields may be perfectly intact and still mean something else.
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        let line = try MoveJournal.encode(journalEntry())
            .replacingOccurrences(of: #""format_version": 1"#, with: #""format_version": 99"#)
        try scratch.write(session, line + "\n")
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.malformedLines == [1])
    }

    @Test("A missing journal is empty, not an error")
    func missingJournalIsEmpty() throws {
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.isEmpty)
        #expect(loaded.isClean)
    }

    @Test("A restoration is appended, not written over the original line")
    func restorationIsAppended() throws {
        // So the journal stays a truthful log of what happened in order, rather than a mutable summary of
        // the current state. A rewrite would also lose everything if it crashed halfway.
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        let entry = journalEntry(original: "/x/1")
        try MoveJournal.append([entry], sessionID: session, in: scratch.state)
        try MoveJournal.appendRestoration(
            of: entry,
            at: "2026-05-11T07:00:00Z",
            sessionID: session,
            in: scratch.state
        )
        let text = try scratch.raw(session)
        #expect(text.split(separator: "\n", omittingEmptySubsequences: true).count == 2)
        #expect(text.contains(#""undone_at""#))

        let loaded = try MoveJournal.load(sessionID: session, in: scratch.state)
        #expect(loaded.entries.map(\.originalPath) == ["/x/1"], "the original entry is still there")
        #expect(loaded.restoredPaths == ["/x/1"])
    }

    @Test("Lists sessions newest first, ignoring anything else in the directory")
    func listsSessions() throws {
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        for id in ["20260511-070000-000001", "20260512-080000-000002"] {
            try MoveJournal.append([journalEntry()], sessionID: id, in: scratch.state)
        }
        // A stray file must not be mistaken for a session.
        try Data().write(
            to: URL(filePath: scratch.state.path(for: .journal) + "/notes.txt")
        )
        #expect(
            MoveJournal.sessions(in: scratch.state)
                == ["20260512-080000-000002", "20260511-070000-000001"]
        )
    }

    @Test("Refuses a session identifier that would escape the directory")
    func refusesTraversal() throws {
        let scratch = try JournalScratch()
        defer { scratch.remove() }
        #expect(throws: StateDirectoryError.invalidIdentifier("../../etc/passwd")) {
            try MoveJournal.append(
                [journalEntry()], sessionID: "../../etc/passwd", in: scratch.state)
        }
    }
}

@Suite("UndoPlanner")
struct UndoPlannerTests {
    /// A fabricated filesystem, so every branch is reachable without staging a real Trash.
    private func environment(
        existing: Set<String> = [],
        directories: Set<String> = [],
        digests: [String: Digest32] = [:]
    ) -> UndoPlanner.Environment {
        UndoPlanner.Environment(
            exists: { existing.contains($0) || directories.contains($0) },
            isDirectory: { directories.contains($0) },
            digest: { digests[$0] }
        )
    }

    @Test("Restores an entry whose file is in the Trash and whose original path is free")
    func restoresTheOrdinaryCase() {
        let entry = journalEntry(original: "/x/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            environment: environment(
                existing: ["/T/a.bin", "/x"],
                digests: ["/T/a.bin": digest("a")]
            )
        )
        #expect(plan.restorable == [entry])
        #expect(plan.restorableBytes == 1000)
        #expect(!plan.isNoOp)
    }

    @Test("Never overwrites an occupied original path")
    func neverOverwritesOccupiedPath() {
        // The worst bug this design permits. A user who undid a session after saving new work at one of
        // those paths must not lose it.
        let entry = journalEntry(original: "/x/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            environment: environment(
                existing: ["/T/a.bin", "/x", "/x/a.bin"],
                digests: ["/T/a.bin": digest("a"), "/x/a.bin": digest("b")]
            )
        )
        #expect(plan.restorable.isEmpty)
        #expect(plan.blocked.map(\.obstacle) == [.originalPathOccupied])
        #expect(plan.isNoOp)
    }

    @Test("Byte-identical content at the original path counts as already restored")
    func identicalContentIsAlreadyRestored() {
        // Possibly put back by Finder's own Put Back, which the app cannot observe. Reporting it as a
        // restore would inflate the count the UI shows, and writing the same bytes over themselves is not
        // a restore.
        let entry = journalEntry(original: "/x/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            environment: environment(
                existing: ["/T/a.bin", "/x", "/x/a.bin"],
                digests: ["/T/a.bin": digest("a"), "/x/a.bin": digest("a")]
            )
        )
        #expect(plan.alreadyRestored == [entry])
        #expect(plan.blocked.isEmpty)
        #expect(plan.isNoOp)
    }

    @Test("A directory where the file was is blocked, with its own reason")
    func directoryAtOriginalPathIsBlocked() {
        // Distinct from an occupied path because there is no suffix-rename that helps: the user has to
        // decide.
        let entry = journalEntry(original: "/x/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            environment: environment(
                existing: ["/T/a.bin", "/x"],
                directories: ["/x/a.bin"],
                digests: ["/T/a.bin": digest("a")]
            )
        )
        #expect(plan.blocked.map(\.obstacle) == [.originalPathIsDirectory])
    }

    @Test("An emptied Trash makes the whole plan a no-op")
    func emptiedTrashIsANoOp() {
        // The UI must not offer a Restore button that cannot restore anything. One sentence and a Close
        // button is the honest answer.
        let entries = (0..<3).map { journalEntry(original: "/x/\($0)", resulting: "/T/\($0)") }
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: entries,
            environment: environment(existing: ["/x"])
        )
        #expect(plan.isNoOp)
        #expect(plan.obstacleCounts == [.movedFileMissing: 3])
        #expect(plan.restorableBytes == 0)
    }

    @Test("A missing parent directory is its own obstacle")
    func missingParentIsBlocked() {
        // Otherwise the move fails with a message that points at the file rather than at the folder that
        // is gone.
        let entry = journalEntry(original: "/x/deep/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            environment: environment(existing: ["/T/a.bin"], digests: ["/T/a.bin": digest("a")])
        )
        #expect(plan.blocked.map(\.obstacle) == [.parentMissing])
    }

    @Test("A file edited inside the Trash is not written back")
    func editedTrashFileIsBlocked() {
        // A user who edited a file in the Trash and then undid the session would otherwise get those edits
        // written over their original path.
        let entry = journalEntry(original: "/x/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            environment: environment(
                existing: ["/T/a.bin", "/x"],
                digests: ["/T/a.bin": digest("f")]
            )
        )
        #expect(plan.blocked.map(\.obstacle) == [.contentChanged])
    }

    @Test("An entry the journal already marked restored is not restored twice")
    func honoursRecordedRestorations() {
        let entry = journalEntry(original: "/x/a.bin", resulting: "/T/a.bin")
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: [entry],
            restoredPaths: ["/x/a.bin"],
            environment: environment(existing: ["/x", "/x/a.bin"])
        )
        #expect(plan.alreadyRestored == [entry])
    }

    @Test("Groups obstacles by reason rather than listing every row")
    func groupsObstacles() {
        // A global problem must not produce 4,000 identical lines in a report.
        let entries = (0..<5).map { journalEntry(original: "/x/\($0)", resulting: "/T/\($0)") }
        let plan = UndoPlanner.plan(
            sessionID: "s",
            entries: entries,
            environment: environment(existing: ["/x"])
        )
        #expect(plan.obstacleCounts.count == 1)
        #expect(plan.obstacleCounts[.movedFileMissing] == 5)
    }
}

@Suite("Undo against real files")
struct UndoRunnerTests {
    @Test("Trashes a file and puts it back byte-identical")
    func fullRoundTrip() throws {
        // The whole promise, end to end, against the real Trash: dispose, journal, plan, restore, and the
        // file comes back with the same bytes at the same path.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let scratch = try JournalScratch()
        defer { scratch.remove() }

        let bytes = ScratchTree.pattern(2500)
        let path = try tree.write("doomed.bin", bytes: bytes)
        let expected = ScratchTree.oneShot(bytes)
        let hasher = ContentHasher()

        let outcome = try TrashDisposer().dispose(path: path)
        var cleanedUp = false
        defer {
            if !cleanedUp { try? FileManager.default.removeItem(atPath: outcome.resultingPath) }
        }

        let entry = JournalEntry(
            originalPath: outcome.originalPath,
            resultingPath: outcome.resultingPath,
            mechanism: outcome.mechanism,
            byteCount: outcome.byteCount,
            digest: expected,
            groupKey: "2500:\(expected.hexString)",
            scanID: "20260511-064716-685054",
            timestamp: "2026-05-11T06:47:16.685054Z"
        )
        try MoveJournal.append([entry], sessionID: "20260511-070000-000001", in: scratch.state)

        let loaded = try MoveJournal.load(sessionID: "20260511-070000-000001", in: scratch.state)
        let plan = UndoPlanner.plan(
            sessionID: "20260511-070000-000001",
            entries: loaded.entries,
            restoredPaths: loaded.restoredPaths,
            environment: .live(hasher: hasher)
        )
        #expect(plan.restorable.count == 1)

        let report = UndoRunner().run(plan)
        cleanedUp = true
        #expect(report.restored.count == 1)
        #expect(report.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path), "the file did not come back")
        #expect(try hasher.fullDigest(atPath: path).digest == expected)
        #expect(!FileManager.default.fileExists(atPath: outcome.resultingPath))
    }

    @Test("Refuses to overwrite something that appeared after the plan was made")
    func refusesLateOccupant() throws {
        // The plan may have been shown to a user minutes ago. The destination is re-checked immediately
        // before the move, because that is the only check that is still true.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let bytes = ScratchTree.pattern(600)
        let path = try tree.write("doomed.bin", bytes: bytes)
        let expected = ScratchTree.oneShot(bytes)

        let outcome = try TrashDisposer().dispose(path: path)
        defer { try? FileManager.default.removeItem(atPath: outcome.resultingPath) }

        let entry = JournalEntry(
            originalPath: outcome.originalPath,
            resultingPath: outcome.resultingPath,
            mechanism: outcome.mechanism,
            byteCount: outcome.byteCount,
            digest: expected,
            groupKey: "600:\(expected.hexString)",
            scanID: "20260511-064716-685054",
            timestamp: "2026-05-11T06:47:16.685054Z"
        )
        let plan = UndoPlan(sessionID: "s", steps: [.restore(entry)])

        // New work saved at that path after the plan was built.
        let newContent = Data("something the user wrote".utf8)
        try newContent.write(to: URL(filePath: path))

        let report = UndoRunner().run(plan)
        #expect(report.restored.isEmpty)
        #expect(report.failed.count == 1)
        #expect(
            try Data(contentsOf: URL(filePath: path)) == newContent,
            "the user's new file was overwritten"
        )
    }
}
