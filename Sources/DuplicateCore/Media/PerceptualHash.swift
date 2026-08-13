import Foundation

/// A 64-bit perceptual hash of one image or one video frame.
///
/// **The bit layout is `imagehash`'s, and it is verified rather than assumed.** `imagehash` flattens the
/// 8x8 boolean block row-major into a bit string and parses it as one integer, so the **first** element is
/// the **most significant** bit. Measured against the installed library:
///
/// | element | hex | bit |
/// |---|---|---|
/// | (0,0) | `8000000000000000` | 63 |
/// | (0,1) | `4000000000000000` | 62 |
/// | (1,0) | `0080000000000000` | 55 |
/// | (7,7) | `0000000000000001` | 0 |
///
/// Matching it costs nothing and makes a disagreement debuggable side by side against Python, which is the
/// only reason to care: no hash ever appears in the shared JSON.
public struct PerceptualHash: Sendable, Hashable {
    public let bits: UInt64

    public init(bits: UInt64) { self.bits = bits }

    /// Parses the 16-character lowercase hex `imagehash` prints. Refuses anything else, because a short
    /// string would silently become a hash with high zero bits.
    public init?(hex: String) {
        guard hex.count == 16, let value = UInt64(hex, radix: 16) else { return nil }
        bits = value
    }

    /// The same 16 characters `str(imagehash.phash(img))` produces.
    public var hexString: String {
        String(format: "%016lx", bits)
    }

    /// Bits that differ. This is the CLI's `hamming_distance`, which counts the ones in `a ^ b`.
    public func distance(to other: PerceptualHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }

    /// `1.0 - hamming / 64.0`, the CLI's `image_similarity`.
    ///
    /// **This number is shared**: it is written into `similar-scans`. The hash it comes from is not, so two
    /// scans of the same pair -- one by Python, one by this app -- can disagree slightly here. Rendered and
    /// compared against a threshold only, so the divergence is cosmetic; it is written down rather than
    /// discovered.
    public func similarity(to other: PerceptualHash) -> Double {
        1.0 - Double(distance(to: other)) / Double(PerceptualHash.bitCount)
    }

    public static let bitCount = 64

    /// Where the block element at `row`, `column` lands, for an 8-wide block.
    ///
    /// Row-major with the first element most significant, so `(0,0)` is bit 63.
    public static func bitIndex(row: Int, column: Int, width: Int = 8) -> Int {
        bitCount - 1 - (row * width + column)
    }
}
