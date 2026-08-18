import Foundation

/// Which of two similar files to keep, and why -- as structure, never as a sentence.
///
/// **Core does not produce prose, and this is the case that makes the rule earn its keep.** The CLI builds the
/// explanation as a Spanish string right where it decides (`similar_review.py:172-227`): `"→ Conservar B: HEVC
/// más eficiente que H264 (2.0× vs 1.0×), mayor bitrate (…)"`. With two languages that string is a string that
/// cannot be translated, and a test that asserts on it is testing wording. Here the decision and its grounds are
/// values, the executable turns them into a sentence, and a test asserts
/// `.prefer(.b, because: [.moreEfficientCodec(…), .higherBitrate(…)])`.
public enum MediaAdvice: Sendable, Hashable {
    /// One side is better, for these reasons, most important first.
    case prefer(Side, because: [Reason])
    /// One side is a short clip of the other -- a trailer, a preview, a fragment.
    case likelyTrailer(keep: Side, shortSeconds: Double, longSeconds: Double)
    /// The two score the same. **Not "keep either"**: it means this app has nothing to add.
    case equivalent
    /// There is nothing to compare: an image pair, or a video whose metadata could not be read.
    case noOpinion

    public enum Side: Sendable, Hashable {
        case a
        case b

        public var other: Side { self == .a ? .b : .a }
    }

    public enum Reason: Sendable, Hashable {
        /// The kept side's codec delivers more picture per bit.
        case moreEfficientCodec(
            keptCodec: String, keptMultiplier: Double, otherCodec: String,
            otherMultiplier: Double, keptCodecKnown: Bool, otherCodecKnown: Bool)
        case higherBitrate(kept: Int, other: Int)
        case higherResolution(
            keptWidth: Int, keptHeight: Int, otherWidth: Int, otherHeight: Int)
        /// The ratio of the two quality scores, which is the number the decision was actually made on.
        case higherQualityScore(ratio: Double)
    }

    /// The preferred side, when there is one.
    public var keep: Side? {
        switch self {
        case .prefer(let side, _): return side
        case .likelyTrailer(let side, _, _): return side
        case .equivalent, .noOpinion: return nil
        }
    }
}

/// Turns two files' facts into advice.
public enum MediaAdvisor {

    /// Under this many seconds is "short".
    public static let shortClipSeconds = 60.0
    /// Over this many seconds is "long". The gap between the two is deliberate: a 90-second clip beside a
    /// 4-minute one is not obviously a trailer, so nothing is claimed.
    public static let longClipSeconds = 300.0

    /// The CLI's `_similar_recommendation`, as values.
    ///
    /// **Trailer detection runs first and short-circuits, exactly as it does there**, and the order matters: a
    /// 30-second trailer encoded in HEVC at a high bitrate can outscore the two-hour H.264 film it advertises.
    /// Quality would keep the trailer and throw away the film. Length is the stronger signal, so it is asked
    /// first.
    public static func advise(a: MediaFacts?, b: MediaFacts?, kind: MediaKind) -> MediaAdvice {
        // Images get no opinion: the CLI's recommendation is video-only, and the fallback chain in
        // ``SimilarDecisionDefaults`` is what ranks two photographs.
        guard kind == .video, let a, let b else { return .noOpinion }

        if a.duration > 0, b.duration > 0 {
            if a.duration < shortClipSeconds, b.duration > longClipSeconds {
                return .likelyTrailer(keep: .b, shortSeconds: a.duration, longSeconds: b.duration)
            }
            if b.duration < shortClipSeconds, a.duration > longClipSeconds {
                return .likelyTrailer(keep: .a, shortSeconds: b.duration, longSeconds: a.duration)
            }
        }

        let scoreA = a.videoQualityScore
        let scoreB = b.videoQualityScore
        guard scoreA != scoreB else { return .equivalent }
        // A score of zero on both sides is handled above; one side at zero means its bitrate or dimensions were
        // unreadable, and the other side wins by default -- which is the CLI's behaviour and worth naming rather
        // than dressing up as a measurement.
        let winner: MediaAdvice.Side = scoreA > scoreB ? .a : .b
        let kept = winner == .a ? a : b
        let other = winner == .a ? b : a

        var reasons: [MediaAdvice.Reason] = []
        if kept.codec != other.codec {
            let keptMultiplier = CodecEfficiency.multiplier(for: kept.codec)
            let otherMultiplier = CodecEfficiency.multiplier(for: other.codec)
            reasons.append(
                .moreEfficientCodec(
                    keptCodec: kept.codec,
                    keptMultiplier: keptMultiplier.value,
                    otherCodec: other.codec,
                    otherMultiplier: otherMultiplier.value,
                    keptCodecKnown: keptMultiplier.isKnown,
                    otherCodecKnown: otherMultiplier.isKnown
                ))
        }
        if kept.bitrate > 0, other.bitrate > 0, kept.bitrate != other.bitrate {
            reasons.append(.higherBitrate(kept: kept.bitrate, other: other.bitrate))
        }
        if kept.pixelCount > 0, other.pixelCount > 0, kept.pixelCount != other.pixelCount {
            reasons.append(
                .higherResolution(
                    keptWidth: kept.pixelWidth, keptHeight: kept.pixelHeight,
                    otherWidth: other.pixelWidth, otherHeight: other.pixelHeight))
        }
        let ratio =
            winner == .a
            ? (scoreB > 0 ? scoreA / scoreB : .infinity)
            : (scoreA > 0 ? scoreB / scoreA : .infinity)
        reasons.append(.higherQualityScore(ratio: ratio))
        return .prefer(winner, because: reasons)
    }
}
