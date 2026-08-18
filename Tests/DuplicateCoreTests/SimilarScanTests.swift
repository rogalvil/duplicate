import Foundation
import Testing

@testable import DuplicateCore

private func pair(
    _ a: String, _ b: String, _ similarity: Double, _ kind: MediaKind = .image
) -> SimilarPair {
    SimilarPair(fileA: a, fileB: b, similarity: similarity, mediaKind: kind)
}

private let noon = ScanIdentifier.Instant(
    year: 2026, month: 8, day: 13, hour: 12, minute: 0, second: 0, microsecond: 0
)

private struct SimilarScratch {
    let root: String
    let tree: String
    let state: StateDirectory
    let store: ScanStore

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-similar-\(UUID().uuidString)"
        tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        store = ScanStore(state: state)
    }

    @discardableResult
    func writeImage(
        _ relative: String, _ pattern: SyntheticImage.Pattern, size: Int = 96,
        format: SyntheticImage.Format = .png
    ) throws -> String {
        let path = tree + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        return try SyntheticImage.write(
            pattern, width: size, height: size, format: format, to: path)
    }

    /// **The cache URL is injected, always.** A selftest or a unit test that used the real
    /// `~/Library/Caches` would pollute the next run -- which already happened once with the presence cache and
    /// made a teeth check fail on the wrong assertion.
    func session() -> SimilarScanSession {
        SimilarScanSession(
            store: store, trashResolver: FixedTrashRootResolver([root + "/faketrash"]),
            cacheURL: URL(filePath: root + "/phashes.v1"))
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite("SimilarScanCodec")
struct SimilarScanCodecTests {

    @Test("A perceptual scan round-trips")
    func roundTrips() throws {
        let scan = SimilarScan(
            scanID: "20260813-120000-000000",
            root: "/Volumes/WD12TB/Tmp",
            createdAt: "2026-08-13T12:00:00.000000Z",
            imageThreshold: 10,
            videoThreshold: 0.7,
            pairs: [
                pair("/a.jpg", "/b.jpg", 1.0),
                pair("/c.mp4", "/d.mp4", 0.875, .video),
            ]
        )
        let encoded = try JSONWriter.document(SimilarScanCodec.encode(scan))
        let decoded = try SimilarScanCodec.decode(JSONReader.parse(encoded))
        #expect(decoded == scan)
        #expect(try JSONWriter.document(SimilarScanCodec.encode(decoded)) == encoded)
    }

    /// **The two number types, and they are opposites.** Measured across the 31 real documents:
    /// `img_threshold` is an `int` in all of them and `vid_threshold` is a `float` in all of them.
    @Test("The image threshold writes as an integer and the video threshold as a float")
    func writesBothNumberTypes() throws {
        let scan = SimilarScan(
            scanID: "20260813-120000-000000", root: "/r",
            createdAt: "2026-08-13T12:00:00.000000Z", imageThreshold: 10, videoThreshold: 0.7,
            pairs: []
        )
        let text = String(
            decoding: try JSONWriter.document(SimilarScanCodec.encode(scan)), as: UTF8.self)
        #expect(text.contains("\"img_threshold\": 10,"))
        #expect(text.contains("\"vid_threshold\": 0.7,"))
        #expect(!text.contains("10.0"))
    }

    /// `"similarity": 1.0` is the most common value in the corpus: 1,100 of 1,271 pairs.
    @Test("An identical pair writes 1.0, not 1")
    func writesIntegralFloats() throws {
        let scan = SimilarScan(
            scanID: "20260813-120000-000000", root: "/r",
            createdAt: "2026-08-13T12:00:00.000000Z", imageThreshold: 5, videoThreshold: 1.0,
            pairs: [pair("/a.jpg", "/b.jpg", 1.0)]
        )
        let text = String(
            decoding: try JSONWriter.document(SimilarScanCodec.encode(scan)), as: UTF8.self)
        #expect(text.contains("\"similarity\": 1.0"))
        #expect(text.contains("\"vid_threshold\": 1.0"))
    }

    @Test("Keys are written in the CLI's order")
    func writesKeysInOrder() throws {
        let scan = SimilarScan(
            scanID: "20260813-120000-000000", root: "/r",
            createdAt: "2026-08-13T12:00:00.000000Z", imageThreshold: 5, videoThreshold: 0.7,
            pairs: [pair("/a.jpg", "/b.jpg", 1.0)]
        )
        let text = String(
            decoding: try JSONWriter.document(SimilarScanCodec.encode(scan)), as: UTF8.self)
        for keys in [
            ["scan_id", "root", "created_at", "img_threshold", "vid_threshold", "pairs"],
            ["file_a", "file_b", "similarity", "media_type"],
        ] {
            var last = -1
            for key in keys {
                let position = try #require(text.range(of: "\"\(key)\"")).lowerBound.utf16Offset(
                    in: text)
                #expect(position > last, "\(key) is out of order")
                last = position
            }
        }
    }

    /// **Refused rather than guessed.** The value decides which threshold the pair was judged against, so
    /// reading an unknown one as an image would misreport what the scan found.
    @Test("An unknown media type is refused by name")
    func refusesUnknownMediaTypes() {
        let value = JSONValue.object([
            JSONMember(key: "scan_id", value: .string("20260813-120000-000000")),
            JSONMember(key: "root", value: .string("/r")),
            JSONMember(key: "created_at", value: .string("t")),
            JSONMember(key: "img_threshold", value: .int(5)),
            JSONMember(key: "vid_threshold", value: .double(0.7)),
            JSONMember(
                key: "pairs",
                value: .array([
                    .object([
                        JSONMember(key: "file_a", value: .string("/a")),
                        JSONMember(key: "file_b", value: .string("/b")),
                        JSONMember(key: "similarity", value: .double(1.0)),
                        JSONMember(key: "media_type", value: .string("audio")),
                    ])
                ])),
        ])
        #expect(throws: ScanDecodingError.unknownMediaType("audio")) {
            try SimilarScanCodec.decode(value)
        }
    }

    @Test("A missing field is reported by name")
    func reportsMissingFields() {
        let value = JSONValue.object([
            JSONMember(key: "scan_id", value: .string("20260813-120000-000000")),
            JSONMember(key: "root", value: .string("/r")),
            JSONMember(key: "created_at", value: .string("t")),
        ])
        #expect(throws: ScanDecodingError.missingField("img_threshold")) {
            try SimilarScanCodec.decode(value)
        }
    }

    @Test("The counts split by media kind")
    func countsByKind() {
        let scan = SimilarScan(
            scanID: "20260813-120000-000000", root: "/r", createdAt: "t",
            imageThreshold: 5, videoThreshold: 0.7,
            pairs: [
                pair("/a.jpg", "/b.jpg", 1.0),
                pair("/b.jpg", "/c.jpg", 0.9),
                pair("/x.mp4", "/y.mp4", 0.8, .video),
            ]
        )
        #expect(scan.pairCount == 3)
        #expect(scan.pairCount(of: .image) == 2)
        #expect(scan.pairCount(of: .video) == 1)
        // a, b, c, x, y
        #expect(scan.involvedFileCount == 5)
        #expect(scan.hasRelativePaths == false)
    }
}

@Suite("SimilarScanSession")
struct SimilarScanSessionTests {

    @Test("Two copies of one picture are found and saved")
    func findsAndSaves() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a/one.png", .rampWithCorner)
        try scratch.writeImage("b/two.png", .rampWithCorner)
        // And something that looks nothing like them.
        try scratch.writeImage("b/three.png", .checkerboard(square: 3))

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)

        #expect(result.hashedCount == 3)
        #expect(result.scan.pairs.count == 1)
        let found = try #require(result.scan.pairs.first)
        #expect(found.similarity == 1.0)
        #expect(found.mediaKind == .image)
        #expect(result.saveFailure == nil)
        // Both kinds are looked at by default now, like the CLI -- there is simply no video in this tree.
        #expect(result.scannedKinds == [.image, .video])
        #expect(result.videoCount == 0)

        let reloaded = try scratch.store.loadSimilarScan(id: noon.identifier)
        #expect(reloaded == result.scan)
        #expect(reloaded.imageThreshold == 5)
        #expect(reloaded.videoThreshold == 0.70)
    }

    /// **`file_a` is the byte-smaller path**, because a review acts on which side is which: `similar-decisions`
    /// records `keep_a` or `keep_b`. Taking it from the walk order is the mistake the folder detector already
    /// made, where all 42 pairs came out mirrored from the CLI's.
    @Test("The pair is oriented by bytes, not by the walk")
    func orientsPairsByBytes() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        // "wen 2/..." is byte-smaller than "wen/..." -- the space beats the slash -- while a depth-first walk
        // reaches `wen` first because the shorter name sorts first.
        try scratch.writeImage("wen/s/pic.png", .rampWithCorner)
        try scratch.writeImage("wen 2/s/pic.png", .rampWithCorner)

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        let found = try #require(result.scan.pairs.first)
        #expect(found.fileA.contains("wen 2/s/pic.png"))
        #expect(found.fileB.hasSuffix("wen/s/pic.png"))
        #expect(PathOrder.lessThan(found.fileA, found.fileB))
    }

    @Test("Only the CLI's image extensions are hashed")
    func hashesOnlyImages() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        try scratch.writeImage("b.jpeg", .rampWithCorner, format: .jpeg(quality: 0.95))
        // Not an image extension, so it is never opened -- even though it is a real PNG inside.
        try scratch.writeImage("c.bin", .rampWithCorner)
        try Data("notes".utf8).write(to: URL(filePath: scratch.tree + "/d.txt"))

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.hashedCount == 2)
        #expect(result.unreadable.isEmpty)
        #expect(SimilarScanSession.imageExtensions == ["jpg", "jpeg", "png", "webp", "gif"])
    }

    /// One unreadable file must not lose the rest, which is what the CLI's `None` return does too.
    @Test("A corrupt image is skipped and named")
    func skipsUnreadableImages() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("good1.png", .rampWithCorner)
        try scratch.writeImage("good2.png", .rampWithCorner)
        let broken = scratch.tree + "/broken.png"
        try Data("this is not a PNG".utf8).write(to: URL(filePath: broken))

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.hashedCount == 2)
        #expect(result.unreadable == [broken])
        #expect(result.scan.pairs.count == 1)
    }

    @Test("A threshold of zero finds only exact hash matches")
    func honoursTheThreshold() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        try scratch.writeImage("b.png", .rampWithCorner)
        try scratch.writeImage("c.png", .checkerboard(square: 3))

        let strict = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree, imageThreshold: 0), instant: noon)
        #expect(strict.scan.pairs.count == 1)
        #expect(strict.scan.pairs.first?.similarity == 1.0)
        #expect(strict.savedPath != nil)
    }

    @Test("Identical images collapse into one class")
    func collapsesIdenticalHashes() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        for index in 0..<5 { try scratch.writeImage("copy\(index).png", .uniform(128)) }

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.hashedCount == 5)
        #expect(result.classCount == 1)
        // Every pair of the five, from one class and no comparisons at all.
        #expect(result.scan.pairs.count == 10)
        #expect(result.scan.pairs.allSatisfy { $0.similarity == 1.0 })
        #expect(result.examinedPairs == 0, "one class has no class pairs to examine")
    }

    @Test("A cancelled scan writes nothing")
    func writesNothingWhenCancelled() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        for index in 0..<40 { try scratch.writeImage("f\(index).png", .uniform(UInt8(index + 1))) }

        let session = scratch.session()
        let task = Task {
            try await session.run(
                SimilarScanSession.Request(root: scratch.tree), instant: noon)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(scratch.store.identifiers(in: .similarScans).isEmpty)
    }

    @Test("Progress counts every image as a candidate")
    func reportsProgress() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        for index in 0..<4 { try scratch.writeImage("f\(index).png", .uniform(UInt8(index + 10))) }

        let counters = ProgressCounters()
        _ = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon, progress: counters)
        let snapshot = counters.snapshot()
        #expect(snapshot.candidates == 4)
        #expect(snapshot.filesHashed == 4)
        #expect(snapshot.phase == .finished)
    }

    /// The CLI's live bug, closed here as everywhere else.
    @Test("Images under a Trash root are never compared")
    func excludesTheTrashRoot() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("real.png", .rampWithCorner)
        let trash = scratch.root + "/faketrash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        _ = try SyntheticImage.write(
            .rampWithCorner, width: 96, height: 96, format: .png, to: trash + "/real.png")
        try FileManager.default.createSymbolicLink(
            atPath: scratch.tree + "/trash-link", withDestinationPath: trash)

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(!result.scan.pairs.contains { $0.fileA.contains("faketrash") })
        #expect(!result.scan.pairs.contains { $0.fileB.contains("faketrash") })
    }

    @Test("A summary carries what a list needs")
    func summarises() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        try scratch.writeImage("b.png", .rampWithCorner)
        _ = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)

        let summary = try #require(scratch.store.similarSummaries().first)
        #expect(summary.scanID == noon.identifier)
        #expect(summary.imageThreshold == 5)
        #expect(summary.videoThreshold == 0.70)
        #expect(summary.pairCount == 1)
        #expect(summary.imagePairCount == 1)
        // The count that says this build has not looked at video yet.
        #expect(summary.videoPairCount == 0)
        #expect(summary.involvedFileCount == 2)
        #expect(summary.hasRelativePaths == false)
    }
}

@Suite("SimilarScanSession video")
struct SimilarScanSessionVideoTests {

    private func writeMovie(
        _ scratch: SimilarScratch, _ relative: String, _ pattern: SyntheticMovie.Pattern,
        seconds: Double = 6
    ) async throws -> String {
        let path = scratch.tree + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        return try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: seconds, pattern: pattern), to: path)
    }

    @Test("Two copies of one clip are found as a video pair")
    func findsVideoPairs() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        _ = try await writeMovie(scratch, "a/one.mp4", .movingBlock)
        _ = try await writeMovie(scratch, "b/two.mp4", .movingBlock)
        // And a clip that looks nothing like them.
        _ = try await writeMovie(scratch, "b/three.mp4", .constantGrey(200))

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)

        #expect(result.videoCount == 3)
        #expect(result.videoPairsCompared == 3, "three videos are three pairs")
        let videoPairs = result.scan.pairs.filter { $0.mediaKind == .video }
        #expect(videoPairs.count == 1, "\(videoPairs.count) video pairs, wanted 1")
        #expect(videoPairs.first?.similarity == 1.0)
        #expect(result.scannedKinds == [.image, .video])
    }

    @Test("Video can be turned off, and then nothing video is read")
    func skipsVideoWhenAsked() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        _ = try await writeMovie(scratch, "one.mp4", .movingBlock)
        _ = try await writeMovie(scratch, "two.mp4", .movingBlock)

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree, includesVideo: false), instant: noon)
        #expect(result.videoCount == 0)
        #expect(result.videoPairsCompared == 0)
        #expect(result.scan.pairs.isEmpty)
        #expect(result.scannedKinds == [.image])
    }

    /// **The orientation rule, on the side where it changes the number.** `video_similarity` is asymmetric, so
    /// which file is A decides the answer; taking it from the walk would make the same pair score differently
    /// on another machine.
    @Test("A video pair is oriented by bytes")
    func orientsVideoPairsByBytes() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        _ = try await writeMovie(scratch, "wen/s/clip.mp4", .movingBlock)
        _ = try await writeMovie(scratch, "wen 2/s/clip.mp4", .movingBlock)

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        let pair = try #require(result.scan.pairs.first { $0.mediaKind == .video })
        #expect(pair.fileA.contains("wen 2/s/clip.mp4"))
        #expect(PathOrder.lessThan(pair.fileA, pair.fileB))
    }

    /// A file with a video extension that no demuxer opens is named, not silently dropped -- which is where
    /// `.mkv` and `.avi` land.
    @Test("A video nothing can read is reported unreadable")
    func reportsUnreadableVideo() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        let broken = scratch.tree + "/broken.mp4"
        try Data("not a movie".utf8).write(to: URL(filePath: broken))
        _ = try await writeMovie(scratch, "fine.mp4", .movingBlock)

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.unreadable.contains(broken))
        #expect(result.videoCount == 1)
    }

    @Test("Images and videos are found in one scan and counted apart")
    func findsBothKinds() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        try scratch.writeImage("b.png", .rampWithCorner)
        _ = try await writeMovie(scratch, "one.mp4", .movingBlock)
        _ = try await writeMovie(scratch, "two.mp4", .movingBlock)

        let result = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(result.scan.pairCount(of: .image) == 1)
        #expect(result.scan.pairCount(of: .video) == 1)
        #expect(result.hashedCount == 4)
        // Sorted by similarity, so both being 1.0 leaves the byte order to break the tie.
        #expect(result.scan.pairs.count == 2)
    }

    @Test("Progress counts videos as candidates too")
    func countsVideosInProgress() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        _ = try await writeMovie(scratch, "one.mp4", .movingBlock)

        let counters = ProgressCounters()
        _ = try await scratch.session().run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon, progress: counters)
        let snapshot = counters.snapshot()
        #expect(snapshot.candidates == 2)
        #expect(snapshot.filesHashed == 2)
    }
}

@Suite("SimilarScanSession cache")
struct SimilarScanSessionCacheTests {

    private func writeMovie(_ scratch: SimilarScratch, _ relative: String) async throws -> String {
        let path = scratch.tree + "/" + relative
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        return try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 4, pattern: .movingBlock), to: path)
    }

    /// **The whole reason the cache exists.** A second scan of the same tree must read nothing: measured on the
    /// real tree, 617 videos cost 93 seconds because each one is eight decodes.
    @Test("A second scan is served entirely by the cache, both kinds")
    func servesAWarmScan() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        try scratch.writeImage("b.png", .checkerboard(square: 3))
        _ = try await writeMovie(scratch, "one.mp4")
        _ = try await writeMovie(scratch, "two.mp4")

        let session = scratch.session()
        let cold = try await session.run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        #expect(cold.imageCacheHits == 0)
        #expect(cold.videoCacheHits == 0)
        #expect(cold.hashedCount == 4)

        let warm = try await session.run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon.nextMicrosecond)
        #expect(warm.imageCacheHits == 2)
        #expect(warm.videoCacheHits == 2)
        // And the answer is the same, which is the part that matters.
        #expect(warm.scan.pairs == cold.scan.pairs)
    }

    @Test("With the cache off, a second scan hashes again")
    func honoursTheCacheToggle() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)

        let session = scratch.session()
        _ = try await session.run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)
        let warm = try await session.run(
            SimilarScanSession.Request(root: scratch.tree, usesCache: false),
            instant: noon.nextMicrosecond)
        #expect(warm.imageCacheHits == 0)
    }

    /// A file rewritten in place is hashed again even though its path did not change.
    @Test("A changed image is not served from the cache")
    func invalidatesAChangedFile() async throws {
        let scratch = try SimilarScratch()
        defer { scratch.remove() }
        try scratch.writeImage("a.png", .rampWithCorner)
        let session = scratch.session()
        _ = try await session.run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon)

        // Same path, different picture.
        try scratch.writeImage("a.png", .checkerboard(square: 3))
        let warm = try await session.run(
            SimilarScanSession.Request(root: scratch.tree), instant: noon.nextMicrosecond)
        #expect(warm.imageCacheHits == 0, "a rewritten file was served from the cache")
    }
}
