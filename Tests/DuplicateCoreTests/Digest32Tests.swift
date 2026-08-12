import Testing

@testable import DuplicateCore

@Suite("Digest32")
struct Digest32Tests {
    // Published SHA-256 known answers. Nothing here computes a hash yet -- the hasher arrives with
    // the scanner -- but the hex parsing and rendering have to agree with hashlib's hexdigest now,
    // because the digest is a key in the JSON shared with the CLI.
    static let emptyHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let abcHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test("Round-trips lowercase hex unchanged")
    func roundTripsHex() throws {
        for hex in [Self.emptyHex, Self.abcHex, String(repeating: "0", count: 64)] {
            let digest = try #require(Digest32(hexString: hex))
            #expect(digest.hexString == hex)
        }
    }

    @Test("Renders lowercase regardless of input case")
    func normalisesCase() throws {
        let upper = try #require(Digest32(hexString: Self.abcHex.uppercased()))
        #expect(upper.hexString == Self.abcHex)
    }

    @Test("Rejects hex that is not exactly 64 characters")
    func rejectsWrongLength() {
        #expect(Digest32(hexString: "") == nil)
        #expect(Digest32(hexString: String(Self.abcHex.dropLast())) == nil)
        #expect(Digest32(hexString: Self.abcHex + "0") == nil)
    }

    @Test("Rejects non-hex characters")
    func rejectsNonHex() {
        #expect(Digest32(hexString: String(repeating: "g", count: 64)) == nil)
        #expect(Digest32(hexString: String(repeating: " ", count: 64)) == nil)
    }

    @Test("Rejects a byte sequence that is not exactly 32 bytes")
    func rejectsWrongByteCount() {
        #expect(Digest32(bytes: [UInt8](repeating: 0, count: 31)) == nil)
        #expect(Digest32(bytes: [UInt8](repeating: 0, count: 33)) == nil)
        #expect(Digest32(bytes: [UInt8](repeating: 0, count: 32)) != nil)
    }

    @Test("Bytes round-trip through hex")
    func bytesRoundTrip() throws {
        let bytes = (0..<32).map { UInt8($0 * 7 % 256) }
        let digest = try #require(Digest32(bytes: bytes))
        #expect(digest.bytes == bytes)
        #expect(Digest32(hexString: digest.hexString) == digest)
    }

    @Test("Integer ordering agrees with hex string ordering")
    func orderingMatchesHexOrdering() throws {
        // This equivalence is load-bearing. The CLI sorts groups with key=(-size, digest), where
        // digest is the lowercase hex string. Sorting Digest32 values instead avoids allocating a
        // string per group, but only produces the same order if the two orderings coincide -- which
        // they do because the words are loaded big-endian and hex digits are monotonic in nibble
        // value. If that stopped holding, two tools would report the same scan in different orders.
        let hexes = [
            Self.emptyHex,
            Self.abcHex,
            String(repeating: "0", count: 64),
            String(repeating: "f", count: 64),
            "0000000000000000000000000000000000000000000000000000000000000001",
            "1000000000000000000000000000000000000000000000000000000000000000",
            "00000000000000000000000000000000000000000000000000000000000000ff",
            "0000000000000000ffffffffffffffff0000000000000000ffffffffffffffff",
        ]
        let digests = try hexes.map { try #require(Digest32(hexString: $0)) }
        #expect(digests.sorted().map(\.hexString) == hexes.sorted())
    }

    @Test("Ordering compares later words when earlier ones tie")
    func ordersOnLaterWords() throws {
        // A digest differing only in its final byte must still order correctly: an implementation
        // that compared only the first word would call these equal and produce an unstable sort.
        let low = try #require(Digest32(hexString: String(repeating: "a", count: 63) + "0"))
        let high = try #require(Digest32(hexString: String(repeating: "a", count: 63) + "b"))
        #expect(low < high)
        #expect(low != high)
    }
}
