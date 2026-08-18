import Foundation

/// What a review decided about one similar pair.
///
/// The four raw values are the CLI's (`similar_review.py:100-105`) and they are interop: `similar-decisions` is
/// a **bare map** of `"a||b"` to one of these strings, with no wrapper -- unlike `decisions/`, which wraps its
/// map in `{scan_id, created_at, decisions}`. Verified against a real file.
public enum SimilarDecision: String, Sendable, Hashable, CaseIterable {
    case keepA = "keep_a"
    case keepB = "keep_b"
    case keepBoth = "keep_both"
    case keepNone = "keep_none"

    /// Which files survive this decision, in the pair's own order.
    public func kept(in pair: SimilarPair) -> [String] {
        switch self {
        case .keepA: return [pair.fileA]
        case .keepB: return [pair.fileB]
        case .keepBoth: return [pair.fileA, pair.fileB]
        case .keepNone: return []
        }
    }

    /// Which files this decision would remove.
    public func removed(in pair: SimilarPair) -> [String] {
        switch self {
        case .keepA: return [pair.fileB]
        case .keepB: return [pair.fileA]
        case .keepBoth: return []
        case .keepNone: return [pair.fileA, pair.fileB]
        }
    }
}

/// The key a decision is stored under: `file_a` and `file_b` joined by two pipes.
///
/// **Two pipes and no escaping, which is the CLI's format and has a real hole**: a path containing `||` would
/// produce a key that cannot be split back apart. Preserved because the key is what is written to disk and a
/// different one would make the two tools disagree about which pair a decision belongs to. Measured on this
/// machine: **no path in the corpus contains `||`**, and ``SimilarPairKey/isAmbiguous(_:)`` reports the case
/// rather than hiding it.
public enum SimilarPairKey {
    public static let separator = "||"

    public static func key(for pair: SimilarPair) -> String {
        pair.fileA + separator + pair.fileB
    }

    /// Whether either path contains the separator, so a caller can warn instead of writing a key that cannot be
    /// parsed back.
    public static func isAmbiguous(_ pair: SimilarPair) -> Bool {
        pair.fileA.contains(separator) || pair.fileB.contains(separator)
    }
}

/// What a review starts from, before the user touches anything.
///
/// **The chain is the CLI's, in its order** (`similar_review.py:229-251`): a name that looks like a copy loses to
/// one that does not; then the media advice; then resolution and size; then depth. Each step only speaks when the
/// one before it tied.
///
/// **And it is a *suggestion*, not a decision.** The same rule the exact detector learned the hard way: a pair
/// nobody looked at must not be written to disk as decided. This produces what the UI should show highlighted;
/// what gets saved is what the user confirmed.
public enum SimilarDecisionDefaults {

    /// The suggestion for one pair, and which step in the chain produced it.
    public struct Suggestion: Sendable, Hashable {
        public let decision: SimilarDecision
        public let ground: Ground

        public init(decision: SimilarDecision, ground: Ground) {
            self.decision = decision
            self.ground = ground
        }
    }

    public enum Ground: Sendable, Hashable {
        /// One name looks like a copy and the other does not.
        case copyName
        /// The media advice decided it.
        case advice(MediaAdvice)
        /// More pixels, or the same pixels and more bytes.
        case quality
        /// Nothing else separated them, so the deeper path wins -- the same tie-break the exact detector uses.
        case depth
    }

    public static func suggestion(
        for pair: SimilarPair,
        root: String,
        factsA: MediaFacts? = nil,
        factsB: MediaFacts? = nil
    ) -> Suggestion {
        // 1. A copy-looking name loses. `CopyNamePattern` is the same one the exact detector uses, quirks and
        // all, so the two detectors agree about what a copy is called.
        let copyA = CopyNamePattern.score(path: pair.fileA)
        let copyB = CopyNamePattern.score(path: pair.fileB)
        if copyA != copyB {
            return Suggestion(decision: copyA < copyB ? .keepA : .keepB, ground: .copyName)
        }

        // 2. The advice, which only speaks for video.
        let advice = MediaAdvisor.advise(a: factsA, b: factsB, kind: pair.mediaKind)
        if let keep = advice.keep {
            return Suggestion(
                decision: keep == .a ? .keepA : .keepB, ground: .advice(advice))
        }

        // 3. More pixels wins; equal pixels, more bytes wins. The CLI sorts on `(-pixels, -size)` and takes the
        // minimum, which is the same order stated forwards.
        let pixelsA = factsA?.pixelCount ?? 0
        let pixelsB = factsB?.pixelCount ?? 0
        let bytesA = factsA?.byteCount ?? 0
        let bytesB = factsB?.byteCount ?? 0
        if pixelsA != pixelsB || bytesA != bytesB {
            let aWins = pixelsA != pixelsB ? pixelsA > pixelsB : bytesA > bytesB
            return Suggestion(decision: aWins ? .keepA : .keepB, ground: .quality)
        }

        // 4. Depth, as a last resort. `depthScore` is negative depth, so the deeper file wins -- counter-intuitive
        // and deliberate: it is the exact detector's rule, and the two must not disagree about the same pair of
        // files.
        let depthA = KeeperHeuristic.depthScore(path: pair.fileA, root: root)
        let depthB = KeeperHeuristic.depthScore(path: pair.fileB, root: root)
        return Suggestion(decision: depthA <= depthB ? .keepA : .keepB, ground: .depth)
    }
}
