@preconcurrency import AVFoundation
@preconcurrency import CoreGraphics
import Foundation
@preconcurrency import ImageIO

/// What a file says about itself: size on disk, pixels, and for a video its codec, bitrate and duration.
///
/// Deliberately **not** the hash. This is the metadata a person would use to choose between two files that a
/// perceptual hash already called alike.
public struct MediaFacts: Sendable, Hashable {
    public let path: String
    public let byteCount: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// The codec, in the names ``CodecEfficiency`` is keyed by. Empty for an image.
    public let codec: String
    /// Whether ``CodecEfficiency`` recognised that codec.
    public let isCodecKnown: Bool
    /// Bits per second, or zero when the container did not say.
    public let bitrate: Int
    /// Seconds, or zero for an image.
    public let duration: Double

    public init(
        path: String,
        byteCount: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        codec: String = "",
        isCodecKnown: Bool = false,
        bitrate: Int = 0,
        duration: Double = 0
    ) {
        self.path = path
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.isCodecKnown = isCodecKnown
        self.bitrate = bitrate
        self.duration = duration
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }

    /// `bitrate × codec efficiency × pixels`, the CLI's `_video_quality_score`.
    ///
    /// **Higher is better, and the shape of the formula is why it works on two encodings of one picture**: the
    /// same content at the same resolution differs only in how many bits it spent and how well the codec spends
    /// them. It is meaningless between two different videos, and nothing here compares two different videos.
    public var videoQualityScore: Double {
        Double(bitrate) * CodecEfficiency.multiplier(for: codec).value * Double(pixelCount)
    }
}

/// Reads those facts without a subprocess.
///
/// **The CLI runs `ffprobe` twice per pair** (`similar_review.py:36,121`) and parses its JSON; a missing or slow
/// `ffprobe` makes the recommendation vanish. AVFoundation and ImageIO answer the same questions in-process.
public struct MediaProbe: Sendable {

    public init() {}

    /// Facts for an image: pixel dimensions from the file's properties, without decoding it.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` reads the header, so a 24-megapixel photograph costs no more than a
    /// thumbnail -- which matters because a review pane asks for this while the user is arrowing through a list.
    public func facts(ofImage path: String) -> MediaFacts? {
        let url = URL(filePath: path)
        let size = fileSize(path)
        guard
            let source = CGImageSourceCreateWithURL(
                url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return nil }
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return MediaFacts(
            path: path, byteCount: size, pixelWidth: width, pixelHeight: height)
    }

    /// Facts for a video: dimensions, codec, bitrate and duration from the first video track.
    public func facts(ofVideo path: String) async -> MediaFacts? {
        let url = URL(filePath: path)
        let size = fileSize(path)
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return nil
        }
        let duration = (try? await CMTimeGetSeconds(asset.load(.duration))) ?? 0
        // **The natural size, transformed.** A phone video is stored landscape with a rotation matrix; reporting
        // its stored dimensions would call a portrait clip 1920x1080 and compare it against a portrait copy that
        // reports 1080x1920, then declare them different resolutions.
        var width = 0
        var height = 0
        if let naturalSize = try? await track.load(.naturalSize),
            let transform = try? await track.load(.preferredTransform)
        {
            let applied = naturalSize.applying(transform)
            width = Int(abs(applied.width).rounded())
            height = Int(abs(applied.height).rounded())
        }
        let rate = (try? await track.load(.estimatedDataRate)) ?? 0

        var codec = ""
        if let descriptions = try? await track.load(.formatDescriptions),
            let first = descriptions.first
        {
            let subtype = CMFormatDescriptionGetMediaSubType(first)
            codec = CodecEfficiency.name(forFourCharacterCode: fourCharacterCode(subtype))
        }
        return MediaFacts(
            path: path,
            byteCount: size,
            pixelWidth: width,
            pixelHeight: height,
            codec: codec,
            isCodecKnown: CodecEfficiency.multiplier(for: codec).isKnown,
            bitrate: rate.isFinite && rate > 0 ? Int(rate) : 0,
            duration: duration.isFinite && duration > 0 ? duration : 0
        )
    }

    /// The size on disk, or zero when it cannot be read.
    ///
    /// **`attributesOfItem` does not follow symlinks**, measured, and here that is what is wanted: the facts are
    /// about the file the scan recorded, and a symlink standing where it was is not that file.
    func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    /// Four bytes of a `FourCharCode`, most significant first.
    func fourCharacterCode(_ value: FourCharCode) -> String {
        let bytes = [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}
