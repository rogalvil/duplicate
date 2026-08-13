@preconcurrency import CoreGraphics
import Foundation
@preconcurrency import ImageIO

public enum MediaHashingError: Error, Sendable, Equatable {
    case notAnImage(path: String)
    case decodeFailed(path: String)
    case emptyImage(path: String)
}

/// Turns an image file into a 64-bit perceptual hash.
///
/// The pipeline, and what each stage is pinned to:
///
/// | stage | what | pinned by |
/// |---|---|---|
/// | decode | ImageIO thumbnail, long side 256 | measured, see below |
/// | grey | Pillow's rounded integer luma | ``GrayscaleConvert`` |
/// | resize | Lanczos-3 to 32x32, aspect ratio **squashed** | ``Lanczos3`` |
/// | transform | 2D DCT-II over 32 | ``CosineTransform`` |
/// | crop | top-left 8x8, **including DC** | below |
/// | threshold | strictly greater than the median of those 64 | ``CosineTransform/median(_:)`` |
///
/// **256 for the decode, chosen by sweeping it over 2,763 of the user's real photographs** and scoring each
/// setting against `imagehash` on the same files:
///
/// | cap | identical | within 2 | max | pairs at ≤5 | Jaccard vs Python | wall |
/// |---|---|---|---|---|---|---|
/// | 32 | 10.89% | 48.50% | 12 | 4,223 | 0.6612 | 13.0 s |
/// | 64 | 42.74% | 90.52% | 8 | 4,384 | 0.7842 | 13.1 s |
/// | 128 | 83.17% | 99.82% | 6 | 4,329 | 0.9275 | 14.3 s |
/// | **256** | **90.88%** | 99.82% | 4 | 4,332 | 0.9670 | 18.2 s |
/// | 512 | 93.59% | 99.93% | 4 | 4,328 | 0.9719 | 26.3 s |
/// | 4096 (full) | 97.68% | 99.93% | 4 | 4,331 | 0.9879 | 48.3 s |
///
/// Two things fall out. **Asking ImageIO for a 32-pixel thumbnail is a disaster** -- 10.9% identical, and
/// 2.5% fewer pairs found -- which confirms the reason for not doing it: at that size ImageIO hands back its
/// cheapest reduction, effectively a box filter, an undocumented detail that also happens to be bad. And
/// **the answer this pipeline gives stops moving at 128**: 4,329 / 4,332 / 4,328 / 4,331 pairs across the top
/// four rows, a spread of 0.1%. Past 256 the extra decode buys agreement with Python, not better answers.
///
/// So the cost is not "nearly free" the way the plan assumed -- a full decode is 2.65x the wall time -- but it
/// buys nothing this app uses. **The plan's acceptance criterion of ≥0.98 Jaccard is therefore not met at the
/// shipped setting**; it needs the full decode. It is one field away for anyone who wants it.
///
/// **The DC coefficient is inside the 8x8 block, deliberately.** `imagehash` takes the median over all 64
/// values including `dct[0][0]`, and the DC of a natural image is far above the median, so it always
/// contributes a set bit -- but it occupies one of the 64 slots and shifts where the median falls. Dropping it
/// would change 63 other comparisons.
///
/// **How close it lands, measured over 2,779 real photographs**: 90.4% bit-identical to `imagehash`, 99.2%
/// within two bits. Sixteen images came out more than five bits away, and **all sixteen carry EXIF
/// orientation 8** -- they are the only sixteen in the corpus that carry any rotation flag at all. So the one
/// systematic divergence is the one chosen on purpose, and excluding those the worst case over 2,763 images
/// is **4 bits**.
///
/// **Applying the orientation is the divergence worth having**: a copy that differs from its original only by
/// a rotation flag should match it, and Pillow's `phash` would call them different pictures.
///
/// The rest is not bit-compatible either, on purpose. Guaranteed identical: the transform's scale, the DC's
/// participation in the median, the bit order, the grey conversion. Different: Pillow rounds to `UInt8`
/// *between* its two resampling passes (**measured: adopting that makes agreement worse**, 89.97% against
/// 90.88%, so the plan's instinct to refuse it was right), Pillow ignores alpha while a CoreGraphics context
/// composites it against black, and an ImageIO thumbnail is not Pillow's full decode. What makes all of it
/// affordable is a fact rather than a hope: **no hash appears in the shared JSON** -- `similar-scans` stores
/// `file_a`, `file_b`, `similarity` and `media_type` -- so bit compatibility would buy exactly one thing
/// nobody does, comparing a hash written by one tool against a hash written by the other.
public struct ImageHasher: Sendable {

    public struct Configuration: Sendable {
        /// The side of the block that becomes the hash. 8 gives 64 bits.
        public var hashSize: Int
        /// How much larger the transform is than the block. 4 gives 32, the size vDSP's DCT would also accept
        /// and the size `imagehash` uses.
        public var highFrequencyFactor: Int
        /// The long side ImageIO is asked to decode to.
        public var decodeMaxPixelSize: Int

        public init(hashSize: Int = 8, highFrequencyFactor: Int = 4, decodeMaxPixelSize: Int = 256)
        {
            self.hashSize = hashSize
            self.highFrequencyFactor = highFrequencyFactor
            self.decodeMaxPixelSize = decodeMaxPixelSize
        }

        public var transformSize: Int { hashSize * highFrequencyFactor }

        /// Stamped into any cache key that stores a hash, so a change to this pipeline invalidates it instead
        /// of serving numbers that mean something else.
        public static let version = "RavPHash v1"
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Hashes a file on disk.
    public func hash(fileURL: URL) throws -> PerceptualHash {
        let decoded = try decodeGrey(fileURL: fileURL)
        return hash(grey: decoded.grey, width: decoded.width, height: decoded.height)
    }

    /// Hashes grey samples directly, which is what makes the arithmetic testable without a file.
    public func hash(grey: [Float], width: Int, height: Int) -> PerceptualHash {
        let size = configuration.transformSize
        let resized = Lanczos3.resize(
            grey, width: width, height: height, toWidth: size, toHeight: size)
        let transformed = CosineTransform.forward2D(quantised(resized), size: size)

        let block = configuration.hashSize
        var lowFrequency = [Float](repeating: 0, count: block * block)
        for row in 0..<block {
            for column in 0..<block {
                lowFrequency[row * block + column] = transformed[row * size + column]
            }
        }

        let threshold = CosineTransform.median(lowFrequency)
        var bits: UInt64 = 0
        for row in 0..<block {
            for column in 0..<block where lowFrequency[row * block + column] > threshold {
                bits |= 1 << UInt64(PerceptualHash.bitIndex(row: row, column: column, width: block))
            }
        }
        return PerceptualHash(bits: bits)
    }

    /// Rounds and clamps the resampled image back to whole 0...255 values, which is what Pillow's `UInt8`
    /// buffer does.
    ///
    /// **Not fidelity -- determinism.** Lanczos ringing and `Float` weights leave a flat region at
    /// `255 ± 1e-3` instead of exactly 255, and the transform of an almost-constant image is 63 tiny
    /// coefficients of mixed sign instead of 63 zeros. The median then falls among them and about half land
    /// above it: **32 bits set instead of 1**, measured, and the bits differ from one flat image to the next.
    ///
    /// Which would break the thing the video path is built on. Every black frame, every letterboxed bar and
    /// every solid title card has to produce the *same* hash, or the equivalence classes that keep a
    /// degenerate bucket from swallowing ten thousand frames never form.
    ///
    /// Rounding rather than truncating, to match ``GrayscaleConvert``.
    func quantised(_ values: [Float]) -> [Float] {
        values.map { Float(min(255, max(0, ($0).rounded()))) }
    }

    // MARK: - Decoding

    /// Decodes to grey samples: an ImageIO thumbnail, then ``grey(from:path:)``.
    func decodeGrey(fileURL: URL) throws -> (grey: [Float], width: Int, height: Int) {
        let path = fileURL.path
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard
            let source = CGImageSourceCreateWithURL(
                fileURL as CFURL, sourceOptions as CFDictionary),
            CGImageSourceGetCount(source) > 0
        else {
            throw MediaHashingError.notAnImage(path: path)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: configuration.decodeMaxPixelSize,
            // **From the image always.** An embedded EXIF thumbnail is a different picture -- often
            // differently cropped -- so hashing it would hash something the file only claims to look like.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Apply the orientation flag. Pillow does not, and this is the divergence worth having: a copy
            // that differs only by a rotation flag should match its original.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary)
        else {
            throw MediaHashingError.decodeFailed(path: path)
        }

        return try grey(from: image, path: path)
    }

    /// Hashes a `CGImage` that is already in memory.
    ///
    /// This is what the video path uses: a frame comes back from `AVAssetImageGenerator` as a `CGImage`, and
    /// writing it to a temporary file only to decode it again -- which is what shelling out to `ffmpeg` forces
    /// the CLI to do, eight JPEGs per video into a temp directory -- would be slower and would put the
    /// encoder's quantisation between the frame and its hash.
    public func hash(image: CGImage) throws -> PerceptualHash {
        let decoded = try grey(from: image, path: "<in memory>")
        return hash(grey: decoded.grey, width: decoded.width, height: decoded.height)
    }

    /// Draws into a known byte layout and applies Pillow's luma.
    ///
    /// Drawn into an explicit sRGB RGBX context rather than read from the `CGImage` directly, because a
    /// `CGImage` can arrive in any layout -- planar, 16-bit, CMYK, premultiplied, with its own colour space --
    /// and reading its bytes without normalising would make the hash depend on how the file happened to be
    /// encoded, or on which decoder produced the frame.
    func grey(from image: CGImage, path: String) throws -> (grey: [Float], width: Int, height: Int)
    {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw MediaHashingError.emptyImage(path: path) }

        let bytesPerPixel = 4
        // An explicit row stride, so there is no padding to skip and the buffer is exactly the pixels.
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: space,
                    // No alpha channel: the fourth byte is ignored, the way Pillow ignores an alpha channel
                    // when it converts to grey. A transparent pixel therefore reads as black here.
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw MediaHashingError.decodeFailed(path: path) }

        let grey = GrayscaleConvert.convert(
            interleaved: buffer, pixelCount: width * height, bytesPerPixel: bytesPerPixel)
        return (grey, width, height)
    }
}
