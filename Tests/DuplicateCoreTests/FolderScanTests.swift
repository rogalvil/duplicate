import Foundation
import Testing

@testable import DuplicateCore

private func pair(
    _ a: String, _ b: String, similarity: Double, matching: Int,
    onlyInA: [String] = [], onlyInB: [String] = [], changed: [String] = [],
    totalA: Int = 1, totalB: Int = 1
) -> FolderPair {
    FolderPair(
        folderA: a, folderB: b, similarity: similarity, matching: matching,
        onlyInA: onlyInA, onlyInB: onlyInB, changed: changed, totalA: totalA, totalB: totalB
    )
}

private let noon = ScanIdentifier.Instant(
    year: 2026, month: 8, day: 13, hour: 12, minute: 0, second: 0, microsecond: 0
)

private struct FolderScratch {
    let root: String
    let tree: String
    let state: StateDirectory
    let store: ScanStore
    let cacheURL: URL

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-folderscan-\(UUID().uuidString)"
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

    func session() -> FolderScanSession {
        FolderScanSession(
            store: store,
            trashResolver: FixedTrashRootResolver([root + "/faketrash"]),
            cacheURL: cacheURL
        )
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

@Suite("FolderScanCodec")
struct FolderScanCodecTests {

    @Test("A folder scan round-trips")
    func roundTrips() throws {
        let scan = FolderScan(
            scanID: "20260813-120000-000000",
            root: "/Volumes/WD12TB/Tmp",
            createdAt: "2026-08-13T12:00:00.000000Z",
            threshold: 0.9,
            pairs: [
                pair(
                    "/a", "/b", similarity: 1.0, matching: 3, totalA: 3, totalB: 3),
                pair(
                    "/c", "/d", similarity: 0.9333333333333333, matching: 7,
                    onlyInA: ["x.bin"], changed: ["y.bin"], totalA: 8, totalB: 7
                ),
            ]
        )
        let encoded = try JSONWriter.document(FolderScanCodec.encode(scan))
        let decoded = try FolderScanCodec.decode(JSONReader.parse(encoded))
        #expect(decoded == scan)
        // And re-encoding the decoded value gives the same bytes.
        #expect(try JSONWriter.document(FolderScanCodec.encode(decoded)) == encoded)
    }

    /// **An identical pair is the common case, and its similarity is the integral float that `JSONEncoder`
    /// would write as `1`.** Measured across the real documents on this machine: `"similarity": 1.0` appears
    /// 1,107 times.
    @Test("An identical pair writes 1.0, not 1")
    func writesIntegralFloats() throws {
        let scan = FolderScan(
            scanID: "20260813-120000-000000", root: "/r",
            createdAt: "2026-08-13T12:00:00.000000Z", threshold: 1.0,
            pairs: [pair("/a", "/b", similarity: 1.0, matching: 1)]
        )
        let text = String(
            decoding: try JSONWriter.document(FolderScanCodec.encode(scan)), as: UTF8.self)
        #expect(text.contains("\"similarity\": 1.0"))
        #expect(text.contains("\"threshold\": 1.0"))
    }

    /// The mirror mistake: the counts are integers, and writing `3.0` breaks the byte comparison just as
    /// surely as writing `1` for a float.
    @Test("The counts write as integers")
    func writesCountsAsIntegers() throws {
        let scan = FolderScan(
            scanID: "20260813-120000-000000", root: "/r",
            createdAt: "2026-08-13T12:00:00.000000Z", threshold: 0.9,
            pairs: [pair("/a", "/b", similarity: 1.0, matching: 3, totalA: 3, totalB: 3)]
        )
        let text = String(
            decoding: try JSONWriter.document(FolderScanCodec.encode(scan)), as: UTF8.self)
        #expect(text.contains("\"matching\": 3,"))
        #expect(text.contains("\"total_a\": 3,"))
        #expect(text.contains("\"total_b\": 3"))
        #expect(!text.contains("3.0"))
    }

    @Test("Keys are written in the CLI's order")
    func writesKeysInOrder() throws {
        let scan = FolderScan(
            scanID: "20260813-120000-000000", root: "/r",
            createdAt: "2026-08-13T12:00:00.000000Z", threshold: 0.9,
            pairs: [pair("/a", "/b", similarity: 1.0, matching: 1)]
        )
        let text = String(
            decoding: try JSONWriter.document(FolderScanCodec.encode(scan)), as: UTF8.self)
        let order = ["scan_id", "root", "created_at", "threshold", "pairs"]
        var last = -1
        for key in order {
            let position = try #require(text.range(of: "\"\(key)\"")).lowerBound.utf16Offset(
                in: text)
            #expect(position > last, "\(key) is out of order")
            last = position
        }
        let pairOrder = [
            "folder_a", "folder_b", "similarity", "matching", "only_in_a", "only_in_b", "changed",
            "total_a", "total_b",
        ]
        var lastPair = -1
        for key in pairOrder {
            let position = try #require(text.range(of: "\"\(key)\"")).lowerBound.utf16Offset(
                in: text)
            #expect(position > lastPair, "\(key) is out of order")
            lastPair = position
        }
    }

    @Test("A missing field is reported by name")
    func reportsMissingFields() throws {
        let value = JSONValue.object([
            JSONMember(key: "scan_id", value: .string("20260813-120000-000000")),
            JSONMember(key: "root", value: .string("/r")),
        ])
        #expect(throws: ScanDecodingError.missingField("created_at")) {
            try FolderScanCodec.decode(value)
        }
    }

    @Test("A malformed scan id is refused")
    func refusesBadIdentifiers() {
        let value = JSONValue.object([
            JSONMember(key: "scan_id", value: .string("../../etc/passwd"))
        ])
        #expect(throws: ScanDecodingError.malformedScanIdentifier("../../etc/passwd")) {
            try FolderScanCodec.decode(value)
        }
    }
}

@Suite("FolderScanSession")
struct FolderScanSessionTests {

    @Test("Two identical folders are found and saved")
    func findsAndSaves() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["copyA", "copyB"] {
            try scratch.write("\(folder)/one.txt", "first")
            try scratch.write("\(folder)/sub/two.txt", "second")
        }

        let result = try await scratch.session().run(
            FolderScanSession.Request(root: scratch.tree), instant: noon)

        #expect(result.scan.pairs.count >= 1)
        let top = try #require(result.scan.pairs.first)
        #expect(top.similarity == 1.0)
        #expect(top.matching == 2)
        #expect(result.saveFailure == nil)
        // And the document reads back through the store.
        let reloaded = try scratch.store.loadFolderScan(id: noon.identifier)
        #expect(reloaded == result.scan)
        #expect(reloaded.threshold == 0.9)
    }

    /// **Every file is hashed, not just size collisions.** That is the difference from the exact detector,
    /// and it is what makes the cache decisive here.
    @Test("A second scan of the same tree is served entirely by the cache")
    func usesTheCacheForEveryFile() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        // Deliberately all different sizes: the exact detector would hash none of these.
        for index in 0..<6 {
            try scratch.write("a/f\(index).txt", String(repeating: "x", count: index + 1))
            try scratch.write("b/f\(index).txt", String(repeating: "x", count: index + 1))
        }

        let session = scratch.session()
        let cold = try await session.run(
            FolderScanSession.Request(root: scratch.tree), instant: noon)
        #expect(cold.cacheHits == 0)

        let warm = try await session.run(
            FolderScanSession.Request(root: scratch.tree), instant: noon.nextMicrosecond)
        #expect(warm.cacheHits == 12)
        // Same answer, which is the part that matters.
        #expect(warm.scan.pairs.count == cold.scan.pairs.count)
        #expect(warm.scan.pairs.first?.similarity == cold.scan.pairs.first?.similarity)
    }

    @Test("A threshold above what the tree offers finds nothing")
    func honoursTheThreshold() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        try scratch.write("a/one.txt", "same")
        try scratch.write("a/two.txt", "different")
        try scratch.write("b/one.txt", "same")

        // 2*1/(2+1) = 0.667.
        let low = try await scratch.session().run(
            FolderScanSession.Request(root: scratch.tree, threshold: 0.6), instant: noon)
        #expect(low.scan.pairs.count == 1)

        let high = try await scratch.session().run(
            FolderScanSession.Request(root: scratch.tree, threshold: 0.9),
            instant: noon.nextMicrosecond)
        #expect(high.scan.pairs.isEmpty)
        // Saved anyway: "I looked and found nothing at 0.9" is a fact worth keeping.
        #expect(high.savedPath != nil)
    }

    @Test("A cancelled scan writes nothing")
    func writesNothingWhenCancelled() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for index in 0..<300 { try scratch.write("a/f\(index).txt", "c\(index)") }

        let session = scratch.session()
        let task = Task {
            try await session.run(
                FolderScanSession.Request(root: scratch.tree), instant: noon)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(scratch.store.identifiers(in: .folderScans).isEmpty)
    }

    @Test("Progress counts every file as a candidate")
    func reportsProgress() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for index in 0..<5 { try scratch.write("a/f\(index).txt", "c\(index)") }

        let counters = ProgressCounters()
        _ = try await scratch.session().run(
            FolderScanSession.Request(root: scratch.tree), instant: noon, progress: counters)

        let snapshot = counters.snapshot()
        #expect(snapshot.candidates == 5)
        #expect(snapshot.filesHashed == 5)
        #expect(snapshot.phase == .finished)
    }

    /// The CLI's live bug, closed here too: the Trash and quarantine roots are excluded by identity.
    @Test("Folders under a Trash root are never compared")
    func excludesTheTrashRoot() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        try scratch.write("real/one.txt", "same")
        let trash = scratch.root + "/faketrash"
        try FileManager.default.createDirectory(
            atPath: trash + "/real", withIntermediateDirectories: true)
        try Data("same".utf8).write(to: URL(filePath: trash + "/real/one.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: scratch.tree + "/trash-link", withDestinationPath: trash)

        let result = try await scratch.session().run(
            FolderScanSession.Request(root: scratch.tree), instant: noon)
        #expect(!result.scan.pairs.contains { $0.folderA.contains("faketrash") })
        #expect(!result.scan.pairs.contains { $0.folderB.contains("faketrash") })
    }

    @Test("A summary carries what a list needs")
    func summarises() async throws {
        let scratch = try FolderScratch()
        defer { scratch.remove() }
        for folder in ["a", "b"] { try scratch.write("\(folder)/one.txt", "same") }
        _ = try await scratch.session().run(
            FolderScanSession.Request(root: scratch.tree), instant: noon)

        let summary = try #require(scratch.store.folderSummaries().first)
        #expect(summary.scanID == noon.identifier)
        #expect(summary.threshold == 0.9)
        #expect(summary.pairCount == 1)
        #expect(summary.involvedFolderCount == 2)
        #expect(summary.hasRelativePaths == false)
    }
}
