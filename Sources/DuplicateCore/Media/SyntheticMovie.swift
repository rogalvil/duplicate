@preconcurrency import AVFoundation
@preconcurrency import CoreGraphics
@preconcurrency import CoreVideo
import Foundation

/// Writes a small movie so tests and the selftest can hash a real video file.
///
/// **Generated, not committed, and in Core rather than in the test target** -- the same two reasons as
/// ``SyntheticImage``. `make selftest` runs against the release build and has to exercise the production path,
/// and a committed `.mp4` is a binary nobody can review, while this states in code exactly what is on screen.
///
/// **H.264 baseline, deliberately.** A GitHub `macos-15` runner is a virtual machine and may have no hardware
/// HEVC encoder; H.264 is the one codec that is always there. And if even that is missing, ``write(_:)``
/// throws rather than returning a file that is not a movie -- a video test that quietly passes because it
/// hashed nothing is worse than one that fails.
public enum SyntheticMovie: Sendable {

    public enum Pattern: Sendable {
        /// A grey that steps up every second, so every sampled frame differs from its neighbours.
        case steppingGrey
        /// One fixed grey for the whole clip: every frame is the same picture, so every frame hashes alike.
        case constantGrey(UInt8)
        /// A bright square that moves left to right, which changes the low frequencies the hash reads.
        case movingBlock
    }

    public struct Specification: Sendable {
        public var width: Int
        public var height: Int
        public var frameRate: Int
        public var seconds: Double
        public var pattern: Pattern

        public init(
            width: Int = 320,
            height: Int = 240,
            frameRate: Int = 10,
            seconds: Double = 10,
            pattern: Pattern = .steppingGrey
        ) {
            self.width = width
            self.height = height
            self.frameRate = frameRate
            self.seconds = seconds
            self.pattern = pattern
        }
    }

    /// Writes the movie and returns its path.
    @discardableResult
    public static func write(
        _ specification: Specification, to path: String
    ) async throws
        -> String
    {
        let url = URL(filePath: path)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: specification.width,
            AVVideoHeightKey: specification.height,
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: specification.width,
                kCVPixelBufferHeightKey as String: specification.height,
            ]
        )
        guard writer.canAdd(input) else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(1, Int(specification.seconds * Double(specification.frameRate)))
        for index in 0..<frameCount {
            // Waiting rather than dropping: `isReadyForMoreMediaData` going false and the frame being skipped
            // would shorten the movie silently, and a test that samples eight timestamps would then miss for a
            // reason that has nothing to do with the code under test.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw MediaHashingError.decodeFailed(path: path)
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                let buffer
            else {
                throw MediaHashingError.decodeFailed(path: path)
            }
            fill(
                buffer, index: index, specification: specification)
            let time = CMTime(
                value: CMTimeValue(index), timescale: CMTimeScale(specification.frameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw MediaHashingError.decodeFailed(path: path)
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MediaHashingError.decodeFailed(path: path)
        }
        return path
    }

    /// Paints one frame, in BGRA.
    private static func fill(
        _ buffer: CVPixelBuffer, index: Int, specification: Specification
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytes = base.bindMemory(to: UInt8.self, capacity: stride * height)

        let second = index / max(1, specification.frameRate)
        for row in 0..<height {
            for column in 0..<width {
                let value: UInt8
                switch specification.pattern {
                case .constantGrey(let level):
                    value = level
                case .steppingGrey:
                    // 20 apart per second, which is far more than a re-encode moves a pixel.
                    value = UInt8(min(250, 20 + second * 20))
                case .movingBlock:
                    let position = (second * width / 10) % width
                    let inside =
                        column >= position && column < position + width / 4 && row > height / 4
                        && row < height * 3 / 4
                    value = inside ? 240 : 20
                }
                let offset = row * stride + column * 4
                bytes[offset] = value  // B
                bytes[offset + 1] = value  // G
                bytes[offset + 2] = value  // R
                bytes[offset + 3] = 255  // A
            }
        }
    }
}
