import Foundation

/// How alike two videos are, as the fraction of sampled frames that found a partner.
///
/// **This is a faithful port of `video_similarity` (`perceptual.py:173-187`), quirks included**, because the
/// number it produces is written into the shared `similar-scans` document and compared against a threshold of
/// 0.70 that was calibrated against exactly this arithmetic. Two of its quirks are worth naming, since both
/// look like bugs and only one is:
///
/// **It is asymmetric.** The loop walks A's frames and asks whether each found a partner in B, then divides by
/// `max(|A|, |B|)`. Swap the arguments and the numerator changes. A concrete case, and it is not exotic: eight
/// frames of a still scene against a one-frame clip of that same scene scores `8/8 = 1.0` one way and
/// `1/8 = 0.125` the other.
///
/// **The greedy `break` inflates.** The first partner found ends the search for that frame, and nothing stops
/// *one* frame of B from being the partner of every frame of A. A ten-minute video of a mostly static scene
/// therefore "matches" any clip containing one similar frame.
///
/// Neither is fixed here. The threshold's meaning comes from this arithmetic, and quietly making the number
/// stricter would reclassify every pair in a corpus scanned by the CLI while every label on screen kept its
/// name. What *is* fixed is which video is A: see ``orientedSimilarity(pathA:hashesA:pathB:hashesB:threshold:)``.
public enum VideoSimilarity {

    /// The CLI's default: 70% of the frames.
    public static let defaultFrameRatio = 0.70

    /// The raw port. `hashesA` is the side that is walked.
    public static func similarity(
        _ hashesA: [PerceptualHash],
        _ hashesB: [PerceptualHash],
        threshold: Int = 5
    ) -> Double {
        guard !hashesA.isEmpty, !hashesB.isEmpty else { return 0.0 }
        let total = max(hashesA.count, hashesB.count)
        var matches = 0
        for first in hashesA {
            for second in hashesB where first.distance(to: second) <= threshold {
                matches += 1
                break
            }
        }
        return Double(matches) / Double(total)
    }

    /// The same comparison with the walked side decided by path bytes.
    ///
    /// **Because the function is asymmetric, the answer depends on which file the caller happens to have
    /// first** -- and in the CLI that is `os.walk` order, which is not reproducible across machines or after a
    /// file moves. So the same two videos can score 1.0 on one run and 0.125 on another, land on opposite sides
    /// of the 0.70 threshold, and appear or not appear in the document.
    ///
    /// Taking the byte-smaller path as A makes the number a property of the two files rather than of the walk.
    /// It is the same rule the folder and image detectors use for `folder_a` and `file_a`, and it is a
    /// divergence from the CLI in *value*, not in format: for pairs where the two directions disagree, this
    /// answers one of the two the CLI could have answered.
    public static func orientedSimilarity(
        pathA: String,
        hashesA: [PerceptualHash],
        pathB: String,
        hashesB: [PerceptualHash],
        threshold: Int = 5
    ) -> Double {
        PathOrder.lessThan(pathA, pathB)
            ? similarity(hashesA, hashesB, threshold: threshold)
            : similarity(hashesB, hashesA, threshold: threshold)
    }

    /// Whether the two directions of the comparison disagree about a pair.
    ///
    /// Reported so a caller can count them rather than pretend they do not exist: it is the honest measure of
    /// how much the asymmetry matters on a real corpus.
    public static func directionsDisagree(
        _ hashesA: [PerceptualHash],
        _ hashesB: [PerceptualHash],
        threshold: Int = 5,
        ratio: Double = defaultFrameRatio
    ) -> Bool {
        let forward = similarity(hashesA, hashesB, threshold: threshold) >= ratio
        let backward = similarity(hashesB, hashesA, threshold: threshold) >= ratio
        return forward != backward
    }
}
