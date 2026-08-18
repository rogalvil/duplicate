import Foundation

/// One file a perceptual review would move, and the pair that says so.
public struct SimilarApplyItem: Hashable, Sendable {
    public let path: String
    /// The other file of the pair -- the one being kept, or the second victim of `keep_none`.
    public let counterpart: String
    /// The `a||b` key, so the journal can name what decided this.
    public let pairKey: String
    public let mediaKind: MediaKind
    /// The similarity the scan recorded for the pair, to be re-checked before the move.
    public let recordedSimilarity: Double

    public init(
        path: String, counterpart: String, pairKey: String, mediaKind: MediaKind,
        recordedSimilarity: Double
    ) {
        self.path = path
        self.counterpart = counterpart
        self.pairKey = pairKey
        self.mediaKind = mediaKind
        self.recordedSimilarity = recordedSimilarity
    }
}

/// What a perceptual apply would do, and what an apply is authorised against.
///
/// **Three things this plan does that the exact one does not have to.**
///
/// A file can appear in several pairs -- 4,771 pairs over 2,460 files on the measured corpus -- so the items are
/// **deduplicated by path**. Moving the same file twice would fail the second time on a file already in the
/// Trash, and report an error for something that worked.
///
/// A path that one decision removes and another keeps is **excluded**, not warned about. Both decisions are the
/// user's, and the only reading that respects them both is to act on neither: acting would delete a file they
/// chose to keep one pair later. Excluded paths are named in ``contradicted``.
///
/// And there is **no recorded digest to verify against**. `similar-scans` stores paths, a similarity and a media
/// type; it never held a SHA-256. So the check before moving cannot be "are these the bytes the scan saw" -- see
/// ``SimilarVerifier`` for what it is instead.
public struct SimilarApplyPlan: Sendable {
    public let items: [SimilarApplyItem]
    /// Paths dropped because another decision keeps them.
    public let contradicted: [String]
    /// The threshold the pairs were found at, which is what the verification re-checks against.
    public let imageThreshold: Int
    public let videoThreshold: Double
    public let scanID: String

    public init(
        items: [SimilarApplyItem],
        contradicted: [String],
        imageThreshold: Int,
        videoThreshold: Double,
        scanID: String
    ) {
        self.items = items
        self.contradicted = contradicted
        self.imageThreshold = imageThreshold
        self.videoThreshold = videoThreshold
        self.scanID = scanID
    }

    public var isEmpty: Bool { items.isEmpty }
    public var pairCount: Int { Set(items.map(\.pairKey)).count }

    /// Builds the plan from a review.
    ///
    /// Ordered by path bytes, so a dry run and the apply that follows it act in the same order and the journal
    /// reads the way the sheet did.
    public static func from(_ state: SimilarReviewState) -> SimilarApplyPlan {
        let contradicted = Set(state.contradictions)
        var seen: Set<String> = []
        var items: [SimilarApplyItem] = []

        for entry in state.removalPlan {
            for path in entry.paths where !contradicted.contains(path) {
                guard seen.insert(path).inserted else { continue }
                items.append(
                    SimilarApplyItem(
                        path: path,
                        counterpart: path == entry.pair.fileA ? entry.pair.fileB : entry.pair.fileA,
                        pairKey: SimilarPairKey.key(for: entry.pair),
                        mediaKind: entry.pair.mediaKind,
                        recordedSimilarity: entry.pair.similarity
                    ))
            }
        }
        items.sort { PathOrder.lessThan($0.path, $1.path) }
        return SimilarApplyPlan(
            items: items,
            contradicted: PathOrder.sorted(state.contradictions),
            imageThreshold: state.scan.imageThreshold,
            videoThreshold: state.scan.videoThreshold,
            scanID: state.scan.scanID
        )
    }

    /// A fingerprint of the plan, for ``ApplyGate``.
    ///
    /// Process-independent, like the exact one: it has to survive a relaunch, so Swift's seeded `Hasher` is out.
    public var fingerprint: String {
        var hash = FNV1a()
        for item in items {
            hash.combine(item.pairKey)
            hash.combine("\u{1}")
            hash.combine(item.path)
            hash.combine("\u{2}")
        }
        return hash.value
    }
}
