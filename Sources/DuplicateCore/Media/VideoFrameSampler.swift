import Foundation

/// Where to sample a video, in seconds.
///
/// **The arithmetic is preserved exactly, and that is not pedantry.** `perceptual.py:139` computes
/// `interval = max(duration / (n + 1), 0.1)` and takes frames at `interval · (i + 1)`. The video threshold of
/// 0.70 -- seven of ten sampled frames must match -- was calibrated against *that* sampling. Sampling
/// differently changes what fraction of frames a re-encode preserves, so it silently changes what the
/// threshold means while every number on screen keeps its name.
///
/// `n + 1` rather than `n` is what keeps the samples off both ends: eight frames of a ten-second video land at
/// 1.11 s through 8.89 s, never at 0 and never at the last frame, which are the two places a video is most
/// likely to be black.
public enum VideoFrameSampler {

    /// The CLI's `_KEYFRAME_COUNT`.
    public static let defaultFrameCount = 8

    /// The floor on the interval, from the same line. A very short clip is sampled every 100 ms rather than
    /// every few milliseconds, which is why some of its timestamps can land past the end -- see below.
    public static let minimumInterval = 0.1

    /// Timestamps for `count` frames of a video `duration` seconds long.
    ///
    /// **Some timestamps can be past the end, and that is preserved on purpose.** For a half-second clip the
    /// floor of 0.1 puts the eighth sample at 0.8 s, which does not exist. The CLI hands those to `ffmpeg`,
    /// gets nothing back for them, and hashes the frames it did get -- so a short video is compared on fewer
    /// frames. Clamping them into range would compare *different* frames than the CLI compares, at the same
    /// threshold.
    ///
    /// A duration of zero means the container did not say. The CLI falls back to a one-second interval there,
    /// which for a real file usually yields a few frames and then failures.
    public static func timestamps(duration: Double, count: Int = defaultFrameCount) -> [Double] {
        guard count > 0 else { return [] }
        let interval =
            duration > 0 ? max(duration / Double(count + 1), minimumInterval) : 1.0
        return (0..<count).map { interval * Double($0 + 1) }
    }

    /// How many of those timestamps are inside a video of that length.
    ///
    /// Reported rather than enforced: a caller that wants to warn "this clip was judged on three frames" needs
    /// the number, and one that wants the CLI's behaviour needs the timestamps unclamped.
    public static func usableCount(duration: Double, count: Int = defaultFrameCount) -> Int {
        guard duration > 0 else { return 0 }
        return timestamps(duration: duration, count: count).count { $0 < duration }
    }
}
