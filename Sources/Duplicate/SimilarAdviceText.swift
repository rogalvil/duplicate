import DuplicateCore
import Foundation

/// Turns ``MediaAdvice`` into a sentence.
///
/// **This file is the other half of "Core does not produce prose."** Core decided and said *why* as values; this
/// is where the why becomes Spanish or English. The CLI builds the same sentence inside its decision function,
/// where it cannot be translated and where a test that checks it is checking wording.
@MainActor
enum SimilarAdviceText {

    static func label(for decision: SimilarDecision) -> String {
        switch decision {
        case .keepA: return Strings.string("similar.decision.keepA")
        case .keepB: return Strings.string("similar.decision.keepB")
        case .keepBoth: return Strings.string("similar.decision.keepBoth")
        case .keepNone: return Strings.string("similar.decision.keepNone")
        }
    }

    /// The one-line "why" under a suggestion.
    static func explanation(for ground: SimilarDecisionDefaults.Ground) -> String {
        switch ground {
        case .copyName: return Strings.string("similar.why.copyName")
        case .quality: return Strings.string("similar.why.quality")
        case .depth: return Strings.string("similar.why.depth")
        case .advice(let advice): return sentence(for: advice)
        }
    }

    static func sentence(for advice: MediaAdvice) -> String {
        switch advice {
        case .equivalent:
            return Strings.string("similar.why.equivalent")
        case .noOpinion:
            return Strings.string("similar.why.noOpinion")
        case .likelyTrailer(_, let short, let long):
            return String(
                format: Strings.string("similar.why.trailer"),
                duration(short), duration(long))
        case .prefer(_, let reasons):
            // Joined in the order Core listed them, which is most-important-first: the codec decides the score
            // by the largest factor, and the ratio is the number the comparison actually used.
            return reasons.map(phrase(for:)).joined(separator: ", ")
        }
    }

    private static func phrase(for reason: MediaAdvice.Reason) -> String {
        switch reason {
        case .moreEfficientCodec(
            let keptCodec, let keptMultiplier, let otherCodec, let otherMultiplier,
            let keptKnown, let otherKnown):
            // **An unknown codec says so.** Its 1.0 is a placeholder, not a measurement, and presenting it as one
            // would dress up a guess as a reason to delete a file.
            if !keptKnown || !otherKnown {
                let unknown = keptKnown ? otherCodec : keptCodec
                let multiplier = keptKnown ? otherMultiplier : keptMultiplier
                return String(
                    format: Strings.string("similar.why.codecUnknown"),
                    unknown.uppercased(), number(multiplier))
            }
            return String(
                format: Strings.string("similar.why.codec"),
                keptCodec.uppercased(), otherCodec.uppercased(),
                number(keptMultiplier), number(otherMultiplier))
        case .higherBitrate(let kept, let other):
            return String(
                format: Strings.string("similar.why.bitrate"), bitrate(kept), bitrate(other))
        case .higherResolution(let keptWidth, let keptHeight, let otherWidth, let otherHeight):
            return String(
                format: Strings.string("similar.why.resolution"),
                keptWidth, keptHeight, otherWidth, otherHeight)
        case .higherQualityScore(let ratio):
            return String(format: Strings.string("similar.why.qualityRatio"), number(ratio))
        }
    }

    /// One decimal, and a full stop in both languages.
    ///
    /// Same rule as the byte sizes: a locale-aware separator makes the width of a label depend on the user, and
    /// these numbers are compared against the CLI's output by eye.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "∞" }
        return String(format: "%.1f", value)
    }

    static func bitrate(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        if bitsPerSecond >= 1_000 {
            return String(format: "%.0f kbps", Double(bitsPerSecond) / 1_000)
        }
        return "\(bitsPerSecond) bps"
    }

    /// `h:mm:ss` or `m:ss`, which is how a duration is read rather than in seconds.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%d:%02d", minutes, remainder)
    }
}
