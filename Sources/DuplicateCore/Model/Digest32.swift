/// A 256-bit digest held as raw bytes rather than a hex `String`.
///
/// The shape is a deliberate memory and ordering decision. A scan of 800,000 files would need
/// 800,000 64-character hex strings, which is 60+ MB of heap and makes every group comparison do
/// Unicode work. Four `UInt64` values are 32 bytes inline, and comparing them is four integer
/// compares.
///
/// The words are loaded big-endian so that comparing `(a, b, c, d)` lexicographically gives the
/// same order as comparing the 32 bytes lexicographically -- which in turn gives the same order as
/// comparing the lowercase hex strings, because hex digits are monotonic in nibble value. That
/// equivalence is what lets the group sort match the CLI's `key=lambda g: (-g.size, g.digest)`
/// (`src/rav/core/duplicates.py:94`) without materialising a single string.
public struct Digest32: Hashable, Sendable, Comparable {
    public let a: UInt64
    public let b: UInt64
    public let c: UInt64
    public let d: UInt64

    public init(a: UInt64, b: UInt64, c: UInt64, d: UInt64) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }

    /// Builds a digest from exactly 32 bytes, most significant first.
    ///
    /// - Returns: `nil` when `bytes` is not exactly 32 elements long. A short digest is a bug in
    ///   the caller, not a value to be padded.
    public init?(bytes: some Sequence<UInt8>) {
        var words: [UInt64] = [0, 0, 0, 0]
        var count = 0
        for byte in bytes {
            guard count < 32 else { return nil }
            words[count / 8] = (words[count / 8] << 8) | UInt64(byte)
            count += 1
        }
        guard count == 32 else { return nil }
        self.init(a: words[0], b: words[1], c: words[2], d: words[3])
    }

    /// Parses 64 lowercase or uppercase hex characters.
    public init?(hexString: String) {
        let characters = Array(hexString.utf8)
        guard characters.count == 64 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = 0
        while index < 64 {
            guard
                let high = Self.nibble(characters[index]),
                let low = Self.nibble(characters[index + 1])
            else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes: bytes)
    }

    /// The 32 bytes, most significant first.
    public var bytes: [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity(32)
        for word in [a, b, c, d] {
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return result
    }

    /// Lowercase hex, matching Python's `hashlib.sha256(...).hexdigest()`.
    ///
    /// Built by hand instead of with `String(format:)`, which is locale-sensitive and, at 800,000
    /// calls, measurably slower. Only used when serialising, never when comparing.
    public var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var scalars = [UInt8]()
        scalars.reserveCapacity(64)
        for byte in bytes {
            scalars.append(digits[Int(byte >> 4)])
            scalars.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: scalars, as: UTF8.self)
    }

    public static func < (lhs: Digest32, rhs: Digest32) -> Bool {
        if lhs.a != rhs.a { return lhs.a < rhs.a }
        if lhs.b != rhs.b { return lhs.b < rhs.b }
        if lhs.c != rhs.c { return lhs.c < rhs.c }
        return lhs.d < rhs.d
    }

    private static func nibble(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): ascii - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): ascii - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): ascii - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
