import Foundation
import Testing

@testable import DuplicateCore

private struct MovieScratch {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-video-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { root + "/" + name }
    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite("VideoFrameSampler")
struct VideoFrameSamplerTests {

    /// **The CLI's arithmetic, checked against numbers worked out by hand.** Ten seconds over eight frames:
    /// `interval = 10/9 = 1.111…`, samples at `1.111, 2.222, … 8.889`. Never zero and never the last frame,
    /// which are the two places a video is most likely to be black.
    @Test("Eight frames of a ten-second video land where the CLI puts them")
    func matchesTheCLIArithmetic() {
        let stamps = VideoFrameSampler.timestamps(duration: 10)
        #expect(stamps.count == 8)
        #expect(abs(stamps[0] - 10.0 / 9.0) < 1e-12)
        #expect(abs(stamps[7] - 8 * 10.0 / 9.0) < 1e-12)
        #expect(stamps[0] > 0)
        #expect(stamps[7] < 10)
        // Evenly spaced, which is what makes the frame ratio mean anything.
        for index in 1..<stamps.count {
            #expect(abs((stamps[index] - stamps[index - 1]) - 10.0 / 9.0) < 1e-12)
        }
    }

    /// The floor of 0.1 s, and the consequence it drags along.
    @Test("A very short clip is sampled every 100 ms, past its own end")
    func honoursTheFloor() {
        let stamps = VideoFrameSampler.timestamps(duration: 0.5)
        #expect(stamps.count == 8)
        #expect(abs(stamps[0] - 0.1) < 1e-12)
        #expect(abs(stamps[7] - 0.8) < 1e-12)
        // **Preserved on purpose**: half the timestamps are past the end of a half-second clip -- 0.1 through
        // 0.4 are inside and 0.5 through 0.8 are not -- so the CLI hashes four frames and compares on those.
        // Clamping them would compare different frames at the same threshold.
        #expect(VideoFrameSampler.usableCount(duration: 0.5) == 4)
    }

    @Test("A container with no duration falls back to one second")
    func handlesUnknownDuration() {
        let stamps = VideoFrameSampler.timestamps(duration: 0)
        #expect(stamps == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(VideoFrameSampler.usableCount(duration: 0) == 0)
    }

    @Test("Asking for no frames gives none rather than dividing by zero")
    func handlesZeroCount() {
        #expect(VideoFrameSampler.timestamps(duration: 10, count: 0).isEmpty)
    }

    @Test("Every timestamp of a long video is inside it")
    func staysInsideLongVideos() {
        for duration in [1.0, 5.0, 60.0, 3600.0, 7200.5] {
            let stamps = VideoFrameSampler.timestamps(duration: duration)
            #expect(stamps.allSatisfy { $0 > 0 && $0 < duration }, "duration \(duration)")
            #expect(VideoFrameSampler.usableCount(duration: duration) == 8)
        }
    }
}

@Suite("VideoHasher")
struct VideoHasherTests {

    @Test("A real movie yields one hash per sampled frame")
    func hashesEveryFrame() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        let path = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 10, pattern: .steppingGrey),
            to: scratch.path("stepping.mp4"))

        let result = try await VideoHasher().hashes(fileURL: URL(filePath: path))
        #expect(result.requestedFrames == 8)
        #expect(result.hashes.count == 8, "\(result.missedFrames) frames missed")
        #expect(abs(result.duration - 10) < 0.5, "duration read as \(result.duration)")
    }

    /// **The property the video comparison is built on.** Every frame of a flat clip is the same picture, so
    /// every frame has to produce the *same* hash -- if they came out as noise the frame ratio would compare
    /// unrelated numbers. This is the end-to-end version of the exact-cancellation argument in
    /// ``CosineTransform``.
    @Test("Every frame of a constant clip hashes identically")
    func collapsesAConstantClip() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        let path = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 6, pattern: .constantGrey(128)),
            to: scratch.path("flat.mp4"))

        let result = try await VideoHasher().hashes(fileURL: URL(filePath: path))
        #expect(result.hashes.count >= 6)
        #expect(
            Set(result.hashes).count == 1, "a flat clip produced \(Set(result.hashes).count) hashes"
        )
        // And it is the derived answer for a flat picture, through a video decoder this time.
        #expect(result.hashes.first?.hexString == "8000000000000000")
    }

    /// A clip whose picture changes has to produce hashes that change with it, or the detector would call
    /// every video similar to every other.
    @Test("A moving picture produces different hashes")
    func distinguishesFrames() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        let path = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 10, pattern: .movingBlock),
            to: scratch.path("moving.mp4"))

        let result = try await VideoHasher().hashes(fileURL: URL(filePath: path))
        #expect(result.hashes.count >= 6)
        #expect(
            Set(result.hashes).count >= 4,
            "a moving block produced \(Set(result.hashes).count) distinct hashes")
    }

    /// One unplayable file among nine thousand must not end a scan, which is what the CLI's `None` does.
    @Test("A file that is not a movie is refused rather than crashing")
    func refusesNonMovies() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        let path = scratch.path("notes.mp4")
        try Data("this is not a movie".utf8).write(to: URL(filePath: path))

        await #expect(throws: MediaHashingError.self) {
            _ = try await VideoHasher().hashes(fileURL: URL(filePath: path))
        }
    }

    @Test("A short clip yields fewer hashes and says how many it missed")
    func reportsMissedFrames() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        // Half a second: the 0.1 s floor puts four of the eight timestamps past the end.
        let path = try await SyntheticMovie.write(
            SyntheticMovie.Specification(frameRate: 20, seconds: 0.5, pattern: .steppingGrey),
            to: scratch.path("short.mp4"))

        let result = try await VideoHasher().hashes(fileURL: URL(filePath: path))
        #expect(result.requestedFrames == 8)
        #expect(result.hashes.count + result.missedFrames == 8)
        #expect(result.hashes.count >= 1, "even a half-second clip yields something")
    }

    /// Cancellation has to be checked between frames, or a scan of a folder of long videos would keep
    /// decoding after the user pressed stop.
    @Test("A cancelled hash stops between frames")
    func stopsWhenCancelled() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        let path = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 10, pattern: .movingBlock),
            to: scratch.path("cancel.mp4"))

        let task = Task {
            try await VideoHasher().hashes(fileURL: URL(filePath: path))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }
}

private func hashes(_ values: [UInt64]) -> [PerceptualHash] {
    values.map(PerceptualHash.init(bits:))
}

@Suite("VideoSimilarity")
struct VideoSimilarityTests {

    @Test("Two identical frame lists match completely")
    func matchesIdenticalLists() {
        let list = hashes([1, 2, 4, 8])
        #expect(VideoSimilarity.similarity(list, list) == 1.0)
    }

    @Test("An empty side scores zero rather than dividing by zero")
    func handlesEmptyLists() {
        #expect(VideoSimilarity.similarity([], hashes([1])) == 0.0)
        #expect(VideoSimilarity.similarity(hashes([1]), []) == 0.0)
        #expect(VideoSimilarity.similarity([], []) == 0.0)
    }

    /// **The asymmetry, with the exact numbers.** Eight frames of a still scene against a one-frame clip of
    /// the same scene: every one of the eight finds its partner, so `8/8`; the other way one frame finds a
    /// partner among eight, so `1/8`. Preserved, because the 0.70 threshold was calibrated against it.
    @Test("The comparison is asymmetric, and that is the CLI's behaviour")
    func isAsymmetric() {
        let many = hashes([0, 0, 0, 0, 0, 0, 0, 0])
        let one = hashes([0])
        #expect(VideoSimilarity.similarity(many, one) == 1.0)
        #expect(VideoSimilarity.similarity(one, many) == 0.125)
        // Which straddles the threshold, so the pair is found in one direction and not the other. Stated with
        // the two numbers rather than through a helper: the helper existed only for this and nothing in the app
        // ever asked it anything.
        let ratio = VideoSimilarity.defaultFrameRatio
        #expect(VideoSimilarity.similarity(many, one) >= ratio)
        #expect(VideoSimilarity.similarity(one, many) < ratio)
    }

    /// The greedy `break`: one frame of B can partner every frame of A.
    @Test("One frame can be the partner of every frame")
    func greedyBreakInflates() {
        // A is eight copies of one picture; B holds that picture once plus seven unrelated ones.
        let a = hashes([0, 0, 0, 0, 0, 0, 0, 0])
        let b = hashes([0, 0xFFFF_FFFF, 0xAAAA_AAAA, 0x5555_5555, 0x1234_5678, 0x9ABC_DEF0, 7, 9])
        #expect(
            VideoSimilarity.similarity(a, b) == 1.0,
            "the greedy break should call this a perfect match")
    }

    @Test("The threshold is per frame, in bits")
    func honoursTheThreshold() {
        let a = hashes([0])
        // Six bits apart.
        let b = hashes([0b111111])
        #expect(VideoSimilarity.similarity(a, b, threshold: 5) == 0.0)
        #expect(VideoSimilarity.similarity(a, b, threshold: 6) == 1.0)
    }

    /// **Orientation makes the number a property of the two files rather than of the walk order.**
    @Test("Orientation by path bytes is stable whichever way the caller holds the pair")
    func orientsByBytes() {
        let many = hashes([0, 0, 0, 0, 0, 0, 0, 0])
        let one = hashes([0])
        let forward = VideoSimilarity.orientedSimilarity(
            pathA: "/r/a.mp4", hashesA: many, pathB: "/r/b.mp4", hashesB: one)
        let backward = VideoSimilarity.orientedSimilarity(
            pathA: "/r/b.mp4", hashesA: one, pathB: "/r/a.mp4", hashesB: many)
        #expect(forward == backward)
        // And it is the byte-smaller path that gets walked: "/r/a.mp4" holds the eight frames.
        #expect(forward == 1.0)
    }

    @Test("The fraction is frames matched over the longer list")
    func dividesByTheLongerList() {
        // **Far apart on purpose.** A first draft used 0, 1, 2 and 0xFFFF and expected two matches; at a
        // threshold of five bits, `2` is one bit from `0`, so three of the four matched. The fixture was
        // wrong, not the code -- and it is a useful reminder that at 5 of 64 bits, small integers are all
        // neighbours.
        let a = hashes([
            0, 0xFFFF_FFFF_FFFF_FFFF, 0x0F0F_0F0F_0F0F_0F0F, 0xF0F0_F0F0_F0F0_F0F0,
        ])
        let b = hashes([0, 0xFFFF_FFFF_FFFF_FFFF])
        // Two of A's four frames find a partner, over max(4, 2). The other two are 32 bits from both.
        #expect(VideoSimilarity.similarity(a, b) == 0.5)
    }
}

@Suite("Video asymmetry on real files")
struct VideoAsymmetryTests {

    /// **The asymmetry, measured on two real movies rather than on hand-written hashes.** A six-second flat
    /// clip yields eight identical frames; a very short one yields fewer, because the 0.1 s sampling floor puts
    /// half the timestamps past its end. Comparing the long one against the short one asks "did each of my
    /// eight frames find a partner" -- yes, all eight -- while the other direction divides the short one's few
    /// matches by the longer list.
    ///
    /// The two answers land on opposite sides of the 0.70 threshold, so **which file the caller happens to hold
    /// first decides whether the pair exists at all**. That is why the walked side is fixed by path bytes.
    @Test("The two directions of a real comparison disagree across the threshold")
    func directionsDisagreeOnRealFiles() async throws {
        let scratch = try MovieScratch()
        defer { scratch.remove() }
        let long = try await SyntheticMovie.write(
            SyntheticMovie.Specification(seconds: 6, pattern: .constantGrey(128)),
            to: scratch.path("long.mp4"))
        let short = try await SyntheticMovie.write(
            SyntheticMovie.Specification(frameRate: 20, seconds: 0.4, pattern: .constantGrey(128)),
            to: scratch.path("short.mp4"))

        let hasher = VideoHasher()
        let longHashes = try await hasher.hashes(fileURL: URL(filePath: long)).hashes
        let shortHashes = try await hasher.hashes(fileURL: URL(filePath: short)).hashes
        #expect(
            longHashes.count > shortHashes.count, "the fixture no longer has two different lengths")

        let forward = VideoSimilarity.similarity(longHashes, shortHashes)
        let backward = VideoSimilarity.similarity(shortHashes, longHashes)
        #expect(forward == 1.0)
        #expect(backward < forward)
        let ratio = VideoSimilarity.defaultFrameRatio
        #expect(
            forward >= ratio && backward < ratio,
            "forward \(forward), backward \(backward) -- both on the same side of \(ratio)"
        )
        // And the oriented answer is the same whichever way the caller holds it.
        let a = VideoSimilarity.orientedSimilarity(
            pathA: long, hashesA: longHashes, pathB: short, hashesB: shortHashes)
        let b = VideoSimilarity.orientedSimilarity(
            pathA: short, hashesA: shortHashes, pathB: long, hashesB: longHashes)
        #expect(a == b)
    }
}
