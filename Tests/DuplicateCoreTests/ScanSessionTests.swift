import Foundation
import Testing

@testable import DuplicateCore

/// A tree to scan, a state directory to save into, and a hash cache -- all under `/tmp`.
///
/// The cache path matters as much as the state path: pointing at the real
/// `~/Library/Caches/com.rogalvil.duplicate` would make the next real scan look warm because a test
/// hashed a fixture, and would make these tests depend on whatever ran before them.
private struct SessionScratch {
    let root: String
    let tree: String
    let state: StateDirectory
    let store: ScanStore
    let cacheURL: URL

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-session-\(UUID().uuidString)"
        tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        store = ScanStore(state: state)
        cacheURL = URL(filePath: root + "/hashes.v1")
    }

    @discardableResult
    func write(_ relative: String, _ contents: String) throws -> String {
        let path = tree + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: URL(filePath: path))
        return path
    }

    func session() -> ScanSession {
        ScanSession(
            store: store,
            // The Trash resolver points at a directory inside the scratch, so the real `~/.Trash` is never
            // involved -- not even to be resolved.
            trashResolver: FixedTrashRootResolver([root + "/faketrash"]),
            cacheURL: cacheURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private let noon = ScanIdentifier.Instant(
    year: 2026, month: 8, day: 12, hour: 12, minute: 0, second: 0, microsecond: 0
)

@Suite("ScanSession")
struct ScanSessionTests {

    @Test("A scan finds the duplicate and saves it where the store can read it back")
    func scansAndSaves() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("a.txt", "same contents here")
        try scratch.write("sub/b.txt", "same contents here")
        try scratch.write("unique.txt", "different")

        let result = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree), instant: noon)

        #expect(result.scan.groups.count == 1)
        #expect(result.scan.fileCount == 2)
        #expect(result.scan.scanID == noon.identifier)
        #expect(result.saveFailure == nil)
        let path = try #require(result.savedPath)
        #expect(path.hasSuffix("/scans/\(noon.identifier).json"))
        // And it round-trips: the document on disk is the one the store reads.
        #expect(try scratch.store.loadScan(id: noon.identifier).groups.count == 1)
    }

    @Test("A tree with no duplicates saves an empty scan rather than nothing")
    func savesAnEmptyScan() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("a.txt", "one")
        try scratch.write("b.txt", "two")

        let result = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.scan.groups.isEmpty)
        // Saved all the same: "I looked and found nothing" is a fact worth keeping, and its absence is
        // indistinguishable from "the scan never ran".
        #expect(result.savedPath != nil)
    }

    /// **The CLI's live bug, closed.** `rav duplicate ~` twice re-discovers everything the first run
    /// quarantined, because its walk does not exclude the quarantine roots -- which default to inside
    /// `~/.Trash`.
    @Test("Files under a Trash root are never scanned")
    func excludesTheTrashRoot() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("keep.txt", "duplicated contents")
        // The fake Trash lives beside the tree, and a copy of it is planted *inside* the tree so the walk
        // would reach it if the exclusion did not work.
        let trash = scratch.root + "/faketrash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        try Data("duplicated contents".utf8).write(to: URL(filePath: trash + "/keep.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.tree + "/trash-link", withDestinationPath: trash)

        let result = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.scan.groups.isEmpty)
        #expect(!result.scan.groups.contains { $0.files.contains { $0.contains("faketrash") } })
    }

    @Test("A second scan of the same tree is served by the cache")
    func usesTheCache() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        for index in 0..<4 {
            try scratch.write("a\(index).txt", "shared contents")
        }

        let session = scratch.session()
        let cold = try await session.run(ScanSession.Request(root: scratch.tree), instant: noon)
        #expect(cold.outcome.cacheHits == 0)

        let warm = try await session.run(
            ScanSession.Request(root: scratch.tree), instant: noon.nextMicrosecond)
        #expect(warm.outcome.cacheHits == 4)
        // Same answer, which is the part that matters: a cache that changes the result is worse than none.
        #expect(warm.scan.groups.count == cold.scan.groups.count)
        #expect(warm.scan.groups.first?.files == cold.scan.groups.first?.files)
    }

    @Test("Turning the cache off leaves it untouched")
    func skipsTheCache() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("a.txt", "shared")
        try scratch.write("b.txt", "shared")

        let result = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree, usesCache: false), instant: noon)
        #expect(result.scan.groups.count == 1)
        #expect(result.outcome.cacheHits == 0)
        #expect(FileManager.default.fileExists(atPath: scratch.cacheURL.path) == false)
    }

    /// **Nothing is written when a scan is cancelled**, because the save happens after the finder returns.
    @Test("A cancelled scan leaves no document behind")
    func writesNothingWhenCancelled() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        // Enough files that the scan is still running when the cancellation lands.
        for index in 0..<400 {
            try scratch.write("f\(index).bin", "contents \(index % 7)")
        }

        let session = scratch.session()
        let task = Task {
            try await session.run(ScanSession.Request(root: scratch.tree), instant: noon)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(scratch.store.identifiers(in: .scans).isEmpty)
    }

    @Test("A root that cannot be scanned is refused before any work")
    func refusesABadRoot() throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        let file = try scratch.write("a.txt", "x")
        let session = scratch.session()

        #expect(session.check(root: scratch.tree) == .ok)
        #expect(session.check(root: scratch.tree).canScan)
        #expect(session.check(root: scratch.root + "/nope") == .missing)
        #expect(session.check(root: file) == .notADirectory)
        #expect(session.check(root: file).canScan == false)
    }

    /// Two tools writing into one directory can collide. Overwriting somebody else's scan is not an
    /// acceptable way to find out.
    @Test("A taken identifier is stepped over")
    func stepsOverATakenIdentifier() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("a.txt", "x")

        // Plant a scan already occupying the identifier this instant would use.
        let date = Date(timeIntervalSince1970: 1_786_000_000)
        let first = ScanIdentifier.Instant(date)
        try scratch.store.save(
            DuplicateScan(
                scanID: first.identifier, root: "/elsewhere",
                createdAt: first.timestamp, groups: []
            )
        )

        let session = scratch.session()
        let chosen = session.availableInstant(at: date)
        #expect(chosen.identifier == first.nextMicrosecond.identifier)

        // And the overload that resolves it internally saves under that identifier, not the taken one.
        let result = try await session.run(ScanSession.Request(root: scratch.tree), at: date)
        #expect(result.scan.scanID == chosen.identifier)
        #expect(scratch.store.identifiers(in: .scans).count == 2)
    }

    @Test("The instant the scan is stamped with is the one in its filename")
    func stampAndFilenameAgree() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("a.txt", "x")

        let result = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree), at: Date(timeIntervalSince1970: 1_786_000_001))
        let path = try #require(result.savedPath)
        #expect(path.hasSuffix("/\(result.scan.scanID).json"))
        #expect(result.scan.createdAt.hasPrefix(String(result.scan.scanID.prefix(4))))
    }

    /// A finished scan must not be thrown away because the state directory could not be written. Twenty
    /// minutes of work is worth more than a tidy error path.
    @Test("A scan that cannot be saved is still returned")
    func survivesASaveFailure() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        try scratch.write("a.txt", "shared")
        try scratch.write("b.txt", "shared")

        // A regular file where the `scans` directory has to go, so creating it fails.
        let blocked = scratch.state.path(for: .scans)
        try FileManager.default.createDirectory(
            atPath: (blocked as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: blocked, contents: Data("x".utf8))

        let result = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.scan.groups.count == 1)
        #expect(result.savedPath == nil)
        #expect(result.saveFailure != nil)
    }

    @Test("Progress counters reach the caller")
    func reportsProgress() async throws {
        let scratch = try SessionScratch()
        defer { scratch.remove() }
        for index in 0..<6 { try scratch.write("f\(index).txt", "shared contents") }

        let counters = ProgressCounters()
        _ = try await scratch.session().run(
            ScanSession.Request(root: scratch.tree), instant: noon, progress: counters)

        let snapshot = counters.snapshot()
        #expect(snapshot.filesSeen == 6)
        #expect(snapshot.filesHashed > 0)
        // `.finished` and not `.grouping`: the phase a finished run rests in is the last one, which is also
        // the stronger assertion -- it says the pipeline reached the end rather than stalling in grouping.
        #expect(snapshot.phase == .finished)
    }
}
