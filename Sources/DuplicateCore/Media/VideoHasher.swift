@preconcurrency import AVFoundation
@preconcurrency import CoreGraphics
import Foundation

/// Turns a video into the list of perceptual hashes the CLI compares.
///
/// **`AVAssetImageGenerator` replaces two `ffmpeg` subprocesses per file, and the dependency was the smaller
/// half of the win.** The CLI shells out to `ffprobe` for the duration and to `ffmpeg` for the frames, which
/// writes **eight JPEGs into a temp directory** and reads them back. Every frame therefore passes through a
/// JPEG encode and decode before it is hashed, at `-q:v 2`, for no reason other than that a subprocess cannot
/// hand back a bitmap. Here the frame arrives as a `CGImage` and goes straight into the hash.
///
/// **The whole fast-seek branch collapses into one property, and that is the interesting part.**
/// `perceptual.py:26,119-131` splits on a 200 MB file size and runs a different extraction for large files,
/// because `ffmpeg -ss` before `-i` seeks cheaply to a sync sample while `-ss` after it decodes forward from
/// one. `requestedTimeToleranceBefore/After` **is** that switch: `.zero` makes AVFoundation decode forward
/// from the previous sync sample, and a tolerance of a second lets it take the nearest one.
///
/// And lax tolerance is the *better* answer, not just the cheaper one: two copies of the same file land on the
/// same keyframe, while a re-encode with a different GOP lands slightly differently -- which is exactly the
/// variation the 0.70 frame ratio exists to absorb.
///
/// **`dynamicRangePolicy` is set rather than assumed.** The header says the default is already
/// `forceSDR`, but "the default is what I want" is a thing that changes in an OS update, and an HDR video
/// decoded into an HDR space produces different pixel values and therefore a different hash for the same
/// picture.
public struct VideoHasher: Sendable {

    public struct Configuration: Sendable {
        /// How many frames to sample. The CLI's `_KEYFRAME_COUNT`.
        public var frameCount: Int
        /// Seek tolerance, in seconds. See the note above: this is the CLI's large-file branch.
        public var toleranceSeconds: Double
        /// The long side asked of the generator, before this pipeline's own resample.
        public var maximumSize: Int

        public init(
            frameCount: Int = VideoFrameSampler.defaultFrameCount,
            toleranceSeconds: Double = 1.0,
            maximumSize: Int = 256
        ) {
            self.frameCount = frameCount
            self.toleranceSeconds = toleranceSeconds
            self.maximumSize = maximumSize
        }
    }

    public struct Result: Sendable {
        /// One hash per frame that could be read, in time order.
        public let hashes: [PerceptualHash]
        /// The duration the container reported, in seconds. Zero when it reported none.
        public let duration: Double
        /// How many timestamps were asked for.
        public let requestedFrames: Int
        /// Timestamps that produced nothing -- past the end of a short clip, or a decode failure.
        public let missedFrames: Int
    }

    public let configuration: Configuration
    private let imageHasher: ImageHasher

    public init(
        configuration: Configuration = Configuration(),
        imageHasher: ImageHasher = ImageHasher()
    ) {
        self.configuration = configuration
        self.imageHasher = imageHasher
    }

    /// Samples and hashes.
    ///
    /// - Returns: a result whose `hashes` is empty when nothing could be read, which is the CLI's `None`.
    ///   Empty rather than an error because one unplayable file among nine thousand must not end the scan.
    public func hashes(fileURL: URL) async throws -> Result {
        let asset = AVURLAsset(url: fileURL)
        let duration: Double
        do {
            duration = try await CMTimeGetSeconds(asset.load(.duration))
        } catch {
            throw MediaHashingError.decodeFailed(path: fileURL.path)
        }
        // A NaN duration is what a container with no duration produces, and it would poison every timestamp.
        let seconds = duration.isFinite && duration > 0 ? duration : 0

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: configuration.maximumSize, height: configuration.maximumSize)
        generator.dynamicRangePolicy = .forceSDR
        let tolerance = CMTime(seconds: configuration.toleranceSeconds, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let stamps = VideoFrameSampler.timestamps(
            duration: seconds, count: configuration.frameCount)
        // **Marks past the end are dropped, and that is a divergence that had to be measured to be seen.**
        // `ffmpeg` returns nothing for a timestamp past the end, so the CLI hashes fewer frames for a short
        // clip -- four of eight for half a second. `AVAssetImageGenerator` with a one-second tolerance is
        // *helpful* instead: it hands back the nearest frame it has, so the same clip came back with eight
        // hashes, the last frame repeated four times. Measured, not predicted.
        //
        // That silently changes the frame ratio the 0.70 threshold is applied to, so the marks are filtered
        // here rather than left to the tolerance. With an unknown duration there is nothing to filter against,
        // and the failures do the counting instead.
        let usable = seconds > 0 ? stamps.filter { $0 < seconds } : stamps
        var hashes: [PerceptualHash] = []
        var missed = stamps.count - usable.count
        for stamp in usable {
            try Task.checkCancellation()
            let time = CMTime(seconds: stamp, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image,
                let hash = try? imageHasher.hash(image: image)
            else {
                missed += 1
                continue
            }
            hashes.append(hash)
        }

        return Result(
            hashes: hashes,
            duration: seconds,
            requestedFrames: stamps.count,
            missedFrames: missed
        )
    }
}
