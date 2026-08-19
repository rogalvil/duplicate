import Foundation

/// Which pairs a perceptual review is showing.
///
/// **4,771 pairs cannot be reviewed one at a time, and the answer is not a button that decides them all.** That
/// button is the CLI's defect: it writes a decision for every pair including the ones nobody opened, which is why
/// this app tracks a tri-state at all.
///
/// The honest answer is the same one the exact detector reached: **narrowing decides nothing**. It changes which
/// pairs are on screen, and then a decision is taken over exactly what is on screen -- named, counted, and
/// confirmed. The pairs outside the filter stay undecided, unwritten and unacted on.
///
/// What is worth narrowing by, measured on the real scan of 4,771 pairs: **2,106 are identical** and 2,665 are
/// merely alike, and 431 are video against 4,340 image. "The identical images" is a set somebody can make a
/// decision about in one go; "everything" is not.
public struct PairFilter: Sendable, Equatable {
    /// Lowest similarity worth showing.
    public var minimumSimilarity: Double
    /// Show only one kind, or both.
    public var kind: MediaKind?
    /// Show only pairs with no decision yet.
    public var onlyUndecided: Bool

    public init(
        minimumSimilarity: Double = 0,
        kind: MediaKind? = nil,
        onlyUndecided: Bool = false
    ) {
        self.minimumSimilarity = minimumSimilarity
        self.kind = kind
        self.onlyUndecided = onlyUndecided
    }

    /// The similarities offered in a menu.
    ///
    /// **1.0 is its own choice, and it is the useful one.** An identical pair is the ordinary case -- 2,106 of
    /// 4,771 on the real scan -- and it is the only class where "keep the first" needs no judgement about what
    /// would be lost. The rest are round numbers a person recognises.
    public static let similarityChoices: [Double] = [0, 0.90, 0.95, 1.0]

    public var isNarrowing: Bool {
        minimumSimilarity > 0 || kind != nil || onlyUndecided
    }

    /// Indices of the pairs that pass, in the scan's own order.
    ///
    /// - Parameter decision: the review's decision for an index, so this stays a pure function over the filter
    ///   rather than reaching into a review's storage.
    public func matchingIndices(
        in pairs: [SimilarPair],
        decision: (Int) -> PairDecision
    ) -> [Int] {
        pairs.indices.filter { index in
            let pair = pairs[index]
            if pair.similarity < minimumSimilarity { return false }
            if let kind, pair.mediaKind != kind { return false }
            if onlyUndecided, decision(index) != .undecided { return false }
            return true
        }
    }
}
