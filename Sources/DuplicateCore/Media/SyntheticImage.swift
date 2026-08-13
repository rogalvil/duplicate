@preconcurrency import CoreGraphics
import Foundation
@preconcurrency import ImageIO
import UniformTypeIdentifiers

/// Writes small images to disk so tests and the selftest can hash a real file.
///
/// **In Core rather than in the test target**, for the same reason the tree fixtures are: `make selftest` runs
/// against the release build and has to exercise the production path, so it cannot carry its own copy of the
/// generator. And generating beats committing binaries -- a committed PNG is a file nobody can review, while
/// this says in code exactly what the pixels are.
public enum SyntheticImage: Sendable {

    public enum Pattern: Sendable {
        /// Every pixel the same value.
        case uniform(UInt8)
        /// Left-to-right ramp from 0 to 255.
        case horizontalRamp
        /// Squares of `size` pixels alternating black and white.
        case checkerboard(square: Int)
        /// A ramp with a bright block in one corner, which breaks the symmetry a ramp has.
        case rampWithCorner
    }

    public enum Format: Sendable {
        case png
        /// JPEG at a quality in `0...1`, for the re-encode invariance the hash is supposed to survive.
        case jpeg(quality: Double)

        var identifier: CFString {
            switch self {
            case .png: return UTType.png.identifier as CFString
            case .jpeg: return UTType.jpeg.identifier as CFString
            }
        }
    }

    /// The grey samples for a pattern, which is also what a test compares a decode against.
    public static func samples(_ pattern: Pattern, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let value: UInt8
                switch pattern {
                case .uniform(let level):
                    value = level
                case .horizontalRamp:
                    value = UInt8(column * 255 / max(1, width - 1))
                case .checkerboard(let square):
                    let dark = ((row / square) + (column / square)) % 2 == 0
                    value = dark ? 0 : 255
                case .rampWithCorner:
                    let ramp = UInt8(column * 255 / max(1, width - 1))
                    value = (row < height / 4 && column < width / 4) ? 255 : ramp
                }
                pixels[row * width + column] = value
            }
        }
        return pixels
    }

    /// Writes the pattern and returns the path.
    @discardableResult
    public static func write(
        _ pattern: Pattern,
        width: Int,
        height: Int,
        format: Format,
        to path: String
    ) throws -> String {
        let grey = samples(pattern, width: width, height: height)
        // Expanded to RGBX, because a grey CGImage would drag in a grey colour space and the point of the
        // fixture is to exercise the same path a photograph takes.
        var rgbx = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            rgbx[index * 4] = grey[index]
            rgbx[index * 4 + 1] = grey[index]
            rgbx[index * 4 + 2] = grey[index]
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: Data(rgbx) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw MediaHashingError.decodeFailed(path: path)
        }

        let url = URL(filePath: path)
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, format.identifier, 1, nil)
        else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        var properties: [CFString: Any] = [:]
        if case .jpeg(let quality) = format {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        return path
    }
}
