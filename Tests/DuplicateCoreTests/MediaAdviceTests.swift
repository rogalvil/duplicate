import Foundation
import Testing

@testable import DuplicateCore

private func video(
    _ path: String, codec: String = "h264", bitrate: Int = 1_000_000,
    width: Int = 1920, height: Int = 1080, seconds: Double = 600, bytes: Int64 = 1_000
) -> MediaFacts {
    MediaFacts(
        path: path, byteCount: bytes, pixelWidth: width, pixelHeight: height, codec: codec,
        isCodecKnown: CodecEfficiency.multiplier(for: codec).isKnown, bitrate: bitrate,
        duration: seconds
    )
}

private func pair(_ a: String, _ b: String, _ kind: MediaKind = .video) -> SimilarPair {
    SimilarPair(fileA: a, fileB: b, similarity: 1.0, mediaKind: kind)
}

@Suite("CodecEfficiency")
struct CodecEfficiencyTests {

    /// The CLI's table, value for value, because the score decides which file gets deleted.
    @Test(
        "The table is the CLI's",
        arguments: [
            ("av1", 3.0), ("hevc", 2.0), ("vp9", 1.8), ("h264", 1.0), ("mpeg4", 0.7),
            ("mpeg2video", 0.5),
        ])
    func matchesTheCLITable(codec: String, expected: Double) {
        let found = CodecEfficiency.multiplier(for: codec)
        #expect(found.value == expected)
        #expect(found.isKnown)
    }

    /// **1.0 and a flag, not 1.0 alone.** The CLI's `.get(codec, 1.0)` treats an unknown codec as H.264, which is
    /// a guess that can hand the decision to the wrong file. The number is kept; the flag lets a caller say so.
    @Test("An unknown codec scores 1.0 and is marked unknown")
    func flagsUnknownCodecs() {
        let found = CodecEfficiency.multiplier(for: "prores")
        #expect(found.value == 1.0)
        #expect(found.isKnown == false)
        #expect(CodecEfficiency.multiplier(for: "H264").isKnown, "the lookup is case-insensitive")
    }

    /// Both HEVC four-character codes are HEVC: one carries its parameter sets in the sample entry, the other in
    /// the stream.
    @Test(
        "Four-character codes map to the table's names",
        arguments: [
            ("avc1", "h264"), ("hvc1", "hevc"), ("hev1", "hevc"), ("av01", "av1"),
            ("vp09", "vp9"), ("mp4v", "mpeg4"),
        ])
    func mapsFourCharacterCodes(code: String, name: String) {
        #expect(CodecEfficiency.name(forFourCharacterCode: code) == name)
        #expect(CodecEfficiency.multiplier(for: name).isKnown)
    }
}

@Suite("MediaAdvisor")
struct MediaAdvisorTests {

    @Test("An image pair gets no opinion")
    func staysQuietAboutImages() {
        let advice = MediaAdvisor.advise(
            a: MediaFacts(path: "/a.jpg", byteCount: 10, pixelWidth: 100, pixelHeight: 100),
            b: MediaFacts(path: "/b.jpg", byteCount: 20, pixelWidth: 200, pixelHeight: 200),
            kind: .image
        )
        #expect(advice == .noOpinion)
        #expect(advice.keep == nil)
    }

    @Test("Unreadable metadata gets no opinion rather than a guess")
    func staysQuietWithoutFacts() {
        #expect(MediaAdvisor.advise(a: nil, b: video("/b.mp4"), kind: .video) == .noOpinion)
        #expect(MediaAdvisor.advise(a: video("/a.mp4"), b: nil, kind: .video) == .noOpinion)
    }

    @Test("The more efficient codec wins, with its numbers")
    func prefersTheEfficientCodec() throws {
        let advice = MediaAdvisor.advise(
            a: video("/a.mp4", codec: "h264"), b: video("/b.mp4", codec: "hevc"), kind: .video)
        #expect(advice.keep == .b)
        guard case .prefer(_, let reasons) = advice else {
            Issue.record("expected a preference, got \(advice)")
            return
        }
        let codecReason = try #require(
            reasons.first {
                if case .moreEfficientCodec = $0 { return true }
                return false
            })
        guard
            case .moreEfficientCodec(
                let kept, let keptMultiplier, let other, let otherMultiplier, _, _) =
                codecReason
        else {
            Issue.record("wrong reason shape")
            return
        }
        #expect(kept == "hevc")
        #expect(keptMultiplier == 2.0)
        #expect(other == "h264")
        #expect(otherMultiplier == 1.0)
        // And the ratio it decided on is reported, since that is the number the comparison used.
        #expect(
            reasons.contains {
                if case .higherQualityScore(let ratio) = $0 { return abs(ratio - 2.0) < 1e-9 }
                return false
            })
    }

    /// **Trailer detection runs first, and the order is what makes it correct.** A 30-second HEVC trailer at a
    /// high bitrate outscores the two-hour H.264 film it advertises, so a quality-first chain would keep the
    /// trailer and delete the film.
    @Test("A short clip beside a long video keeps the long one, whatever it scores")
    func prefersTheFullVideoOverATrailer() {
        let trailer = video("/trailer.mp4", codec: "hevc", bitrate: 20_000_000, seconds: 30)
        let film = video("/film.mp4", codec: "h264", bitrate: 2_000_000, seconds: 7_200)
        #expect(trailer.videoQualityScore > film.videoQualityScore, "the fixture no longer inverts")

        let advice = MediaAdvisor.advise(a: trailer, b: film, kind: .video)
        #expect(advice.keep == .b)
        guard case .likelyTrailer(_, let short, let long) = advice else {
            Issue.record("expected a trailer verdict, got \(advice)")
            return
        }
        #expect(short == 30)
        #expect(long == 7_200)
        // And symmetrically.
        #expect(MediaAdvisor.advise(a: film, b: trailer, kind: .video).keep == .a)
    }

    /// The gap between 60 s and 300 s is deliberate: in it, nothing is claimed about trailers.
    @Test("A clip in the middle of the range is judged on quality, not length")
    func staysQuietInTheGap() {
        let ninetySeconds = video("/a.mp4", seconds: 90, bytes: 1)
        let fourMinutes = video("/b.mp4", codec: "hevc", seconds: 240, bytes: 2)
        let advice = MediaAdvisor.advise(a: ninetySeconds, b: fourMinutes, kind: .video)
        if case .likelyTrailer = advice {
            Issue.record("claimed a trailer inside the deliberate gap")
        }
        #expect(advice.keep == .b)
    }

    @Test("Equal scores are equivalent, which is not the same as keep either")
    func reportsEquivalence() {
        let advice = MediaAdvisor.advise(a: video("/a.mp4"), b: video("/b.mp4"), kind: .video)
        #expect(advice == .equivalent)
        #expect(advice.keep == nil)
    }

    @Test("Bitrate and resolution appear as reasons when they differ")
    func reportsEveryDifference() {
        let advice = MediaAdvisor.advise(
            a: video("/a.mp4", bitrate: 500_000, width: 640, height: 480),
            b: video("/b.mp4", bitrate: 4_000_000, width: 1920, height: 1080),
            kind: .video
        )
        guard case .prefer(.b, let reasons) = advice else {
            Issue.record("expected B, got \(advice)")
            return
        }
        #expect(
            reasons.contains {
                if case .higherBitrate(let kept, let other) = $0 {
                    return kept == 4_000_000 && other == 500_000
                }
                return false
            })
        #expect(
            reasons.contains {
                if case .higherResolution(let w, let h, _, _) = $0 { return w == 1920 && h == 1080 }
                return false
            })
        // The codec is the same, so it is not among the reasons -- a list of every field would bury the one
        // that mattered.
        #expect(
            !reasons.contains {
                if case .moreEfficientCodec = $0 { return true }
                return false
            })
    }

    /// **The winner can lose on a field and still win, and the sentence has to say so.**
    ///
    /// Measured on the demo tree: `clip-recodificado.mp4` is 320x240 at 232 kbps against
    /// `clip-original.mp4` at 640x480 and 49 kbps. The score weighs bitrate against pixels, so the smaller
    /// frame wins -- and the advice read "mayor resolucion (320 x 240 contra 640 x 480)", which is the
    /// opposite of what its own numbers show, in the line that decides which file goes to the Trash.
    ///
    /// The guard that emits the reason asks whether the two *differ*; only the case name said "higher".
    @Test("A winner with fewer pixels says fewer, not more")
    func namesTheDirectionItActuallyWent() {
        let advice = MediaAdvisor.advise(
            a: video("/original.mp4", bitrate: 49_000, width: 640, height: 480),
            b: video("/recoded.mp4", bitrate: 232_000, width: 320, height: 240),
            kind: .video
        )
        guard case .prefer(.b, let reasons) = advice else {
            Issue.record("expected B, got \(advice)")
            return
        }
        // It really did win on bitrate, so that reason keeps its name.
        #expect(
            reasons.contains {
                if case .higherBitrate(let kept, let other) = $0 {
                    return kept == 232_000 && other == 49_000
                }
                return false
            })
        // And it really did lose on pixels, so this one must not claim otherwise.
        #expect(
            reasons.contains {
                if case .lowerResolution(let w, let h, let ow, let oh) = $0 {
                    return w == 320 && h == 240 && ow == 640 && oh == 480
                }
                return false
            })
        #expect(
            !reasons.contains {
                if case .higherResolution = $0 { return true }
                return false
            })
    }

    /// The other direction of the same hole: `higherBitrate` was emitted on inequality too, and only
    /// happened to be right in the pair that exposed the resolution case.
    @Test("A winner with fewer bits says fewer, not more")
    func namesTheBitrateDirection() {
        let advice = MediaAdvisor.advise(
            a: video("/small.mp4", codec: "h264", bitrate: 4_000_000, width: 640, height: 480),
            b: video("/big.mp4", codec: "hevc", bitrate: 3_000_000, width: 3840, height: 2160),
            kind: .video
        )
        guard case .prefer(.b, let reasons) = advice else {
            Issue.record("expected B, got \(advice)")
            return
        }
        #expect(
            reasons.contains {
                if case .lowerBitrate(let kept, let other) = $0 {
                    return kept == 3_000_000 && other == 4_000_000
                }
                return false
            })
        #expect(
            !reasons.contains {
                if case .higherBitrate = $0 { return true }
                return false
            })
    }
}

@Suite("SimilarDecision")
struct SimilarDecisionTests {

    @Test("The raw values are the CLI's")
    func matchesTheCLIStrings() {
        #expect(SimilarDecision.keepA.rawValue == "keep_a")
        #expect(SimilarDecision.keepB.rawValue == "keep_b")
        #expect(SimilarDecision.keepBoth.rawValue == "keep_both")
        #expect(SimilarDecision.keepNone.rawValue == "keep_none")
        #expect(SimilarDecision(rawValue: "keep_a") == .keepA)
    }

    @Test("Kept and removed are complements")
    func splitsThePair() {
        let subject = pair("/a.mp4", "/b.mp4")
        for decision in SimilarDecision.allCases {
            let kept = decision.kept(in: subject)
            let removed = decision.removed(in: subject)
            #expect(Set(kept).isDisjoint(with: Set(removed)))
            #expect(Set(kept).union(removed) == ["/a.mp4", "/b.mp4"])
        }
        #expect(SimilarDecision.keepA.removed(in: subject) == ["/b.mp4"])
        #expect(SimilarDecision.keepNone.kept(in: subject).isEmpty)
    }

    /// Two pipes and no escaping: the CLI's format, with the hole it implies reported rather than hidden.
    @Test("The key is a||b, and an ambiguous one is flagged")
    func buildsTheKey() {
        #expect(SimilarPairKey.key(for: pair("/a.mp4", "/b.mp4")) == "/a.mp4||/b.mp4")
        #expect(SimilarPairKey.isAmbiguous(pair("/a.mp4", "/b.mp4")) == false)
        #expect(SimilarPairKey.isAmbiguous(pair("/we||rd.mp4", "/b.mp4")))
    }
}

@Suite("SimilarDecisionDefaults")
struct SimilarDecisionDefaultsTests {

    @Test("A copy-looking name loses first, before anything is measured")
    func prefersTheOriginalName() {
        let suggestion = SimilarDecisionDefaults.suggestion(
            for: pair("/r/photo copy.jpg", "/r/photo.jpg", .image), root: "/r")
        #expect(suggestion.decision == .keepB)
        #expect(suggestion.ground == .copyName)
    }

    @Test("The advice decides when the names tie")
    func fallsThroughToAdvice() {
        let suggestion = SimilarDecisionDefaults.suggestion(
            for: pair("/r/a.mp4", "/r/b.mp4"),
            root: "/r",
            factsA: video("/r/a.mp4", codec: "h264"),
            factsB: video("/r/b.mp4", codec: "hevc")
        )
        #expect(suggestion.decision == .keepB)
        guard case .advice = suggestion.ground else {
            Issue.record("expected the advice to decide, got \(suggestion.ground)")
            return
        }
    }

    @Test("More pixels wins, and equal pixels fall to more bytes")
    func fallsThroughToQuality() {
        let bigger = SimilarDecisionDefaults.suggestion(
            for: pair("/r/a.jpg", "/r/b.jpg", .image),
            root: "/r",
            factsA: MediaFacts(path: "/r/a.jpg", byteCount: 10, pixelWidth: 100, pixelHeight: 100),
            factsB: MediaFacts(path: "/r/b.jpg", byteCount: 10, pixelWidth: 200, pixelHeight: 200)
        )
        #expect(bigger.decision == .keepB)
        #expect(bigger.ground == .quality)

        let heavier = SimilarDecisionDefaults.suggestion(
            for: pair("/r/a.jpg", "/r/b.jpg", .image),
            root: "/r",
            factsA: MediaFacts(path: "/r/a.jpg", byteCount: 900, pixelWidth: 100, pixelHeight: 100),
            factsB: MediaFacts(path: "/r/b.jpg", byteCount: 100, pixelWidth: 100, pixelHeight: 100)
        )
        #expect(heavier.decision == .keepA)
        #expect(heavier.ground == .quality)
    }

    /// **The deeper file wins, which is counter-intuitive and deliberate**: it is the exact detector's rule, and
    /// the two detectors disagreeing about the same two files would be worse than either rule being odd.
    @Test("With nothing else to go on, the deeper path wins")
    func fallsThroughToDepth() {
        let suggestion = SimilarDecisionDefaults.suggestion(
            for: pair("/r/a.jpg", "/r/deep/nested/b.jpg", .image), root: "/r")
        #expect(suggestion.decision == .keepB)
        #expect(suggestion.ground == .depth)
    }

    @Test("A suggestion is produced for every pair, and none of them is a decision")
    func alwaysSuggestsSomething() {
        for kind in MediaKind.allCases {
            let suggestion = SimilarDecisionDefaults.suggestion(
                for: pair("/r/one", "/r/two", kind), root: "/r")
            #expect(SimilarDecision.allCases.contains(suggestion.decision))
        }
    }
}

@Suite("MediaProbe")
struct MediaProbeTests {

    private func scratch() throws -> String {
        let root = NSTemporaryDirectory() + "/duplicate-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    /// Read from the header, not from a decode: a review pane asks for this while the user arrows through a list.
    @Test("An image reports its pixels and its size on disk")
    func readsImageFacts() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try SyntheticImage.write(
            .rampWithCorner, width: 321, height: 123, format: .png, to: root + "/a.png")

        let facts = try #require(MediaProbe().facts(ofImage: path))
        #expect(facts.pixelWidth == 321)
        #expect(facts.pixelHeight == 123)
        #expect(facts.pixelCount == 321 * 123)
        #expect(facts.byteCount > 0)
        // An image has no codec or duration to report, and reporting one would be an invention.
        #expect(facts.codec.isEmpty)
        #expect(facts.duration == 0)
        #expect(facts.videoQualityScore == 0)
    }

    @Test("A file that is not an image reports nothing")
    func refusesNonImages() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/notes.jpg"
        try Data("not an image".utf8).write(to: URL(filePath: path))
        #expect(MediaProbe().facts(ofImage: path) == nil)
    }

    @Test("A video reports its codec, dimensions, bitrate and duration")
    func readsVideoFacts() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = try await SyntheticMovie.write(
            SyntheticMovie.Specification(
                width: 320, height: 240, seconds: 4, pattern: .movingBlock),
            to: root + "/clip.mp4")

        let facts = try #require(await MediaProbe().facts(ofVideo: path))
        #expect(facts.pixelWidth == 320)
        #expect(facts.pixelHeight == 240)
        // Written as H.264 by `SyntheticMovie`, and recognised by the table rather than defaulted into it.
        #expect(facts.codec == "h264")
        #expect(facts.isCodecKnown)
        #expect(facts.bitrate > 0)
        #expect(abs(facts.duration - 4) < 0.5, "duration read as \(facts.duration)")
        #expect(facts.videoQualityScore > 0)
    }

    @Test("A file that is not a movie reports nothing")
    func refusesNonMovies() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/notes.mp4"
        try Data("not a movie".utf8).write(to: URL(filePath: path))
        #expect(await MediaProbe().facts(ofVideo: path) == nil)
    }

    @Test("A four-character code round-trips through the reader")
    func readsFourCharacterCodes() {
        // 'avc1' as a FourCharCode.
        let code: FourCharCode =
            (FourCharCode(UInt8(ascii: "a")) << 24) | (FourCharCode(UInt8(ascii: "v")) << 16)
            | (FourCharCode(UInt8(ascii: "c")) << 8) | FourCharCode(UInt8(ascii: "1"))
        #expect(MediaProbe().fourCharacterCode(code) == "avc1")
    }
}
