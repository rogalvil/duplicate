import CryptoKit
import Foundation
import Testing

@testable import DuplicateCore

/// A scratch tree for tests that need real files. Created and removed explicitly, so a failure leaves
/// no debris in the temp directory.
struct ScratchTree {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-hash-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func write(_ name: String, bytes: [UInt8]) throws -> String {
        let path = root + "/" + name
        try Data(bytes).write(to: URL(filePath: path))
        return path
    }

    /// A repeating pattern rather than random bytes, so a failure is reproducible and a chunk-boundary
    /// bug produces one specific wrong digest instead of a different one every run.
    static func pattern(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8($0 % 251) }
    }

    /// SHA-256 in one shot: the reference the chunked read loop is checked against.
    static func oneShot(_ bytes: [UInt8]) -> Digest32 {
        Digest32(bytes: Array(SHA256.hash(data: Data(bytes))))!
    }
}

@Suite("ContentHasher")
struct ContentHasherTests {
    static let emptyHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let abcHex = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    @Test("Matches the published SHA-256 known answers")
    func matchesKnownAnswers() throws {
        // Not "matches CryptoKit" -- matches the values in the standard, which is what hashlib
        // produces and therefore what the shared format already contains.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher()

        let empty = try tree.write("empty", bytes: [])
        let emptyResult = try hasher.fullDigest(atPath: empty)
        #expect(emptyResult.digest.hexString == Self.emptyHex)
        #expect(emptyResult.byteCount == 0)

        let abc = try tree.write("abc", bytes: Array("abc".utf8))
        let abcResult = try hasher.fullDigest(atPath: abc)
        #expect(abcResult.digest.hexString == Self.abcHex)
        #expect(abcResult.byteCount == 3)
    }

    @Test(
        "Hashes correctly across every chunk boundary",
        arguments: [0, 1, 2, 4095, 4096, 4097, 8191, 8192, 8193, 24577]
    )
    func hashesAcrossChunkBoundaries(size: Int) throws {
        // The test most likely to catch the most likely defect. A read loop with an off-by-one at the
        // chunk edge yields a digest that is wrong only for particular sizes, and every one of those
        // sizes silently splits or merges a duplicate group.
        //
        // The chunk is shrunk to 4 KiB so the boundaries are cheap to straddle; the production default
        // is 1 MiB and the arithmetic is identical.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher(configuration: .init(chunkBytes: 4096))

        let bytes = ScratchTree.pattern(size)
        let path = try tree.write("f-\(size)", bytes: bytes)
        let result = try hasher.fullDigest(atPath: path)
        #expect(result.digest == ScratchTree.oneShot(bytes), "size \(size)")
        #expect(result.byteCount == Int64(size))
    }

    @Test("Reads a file spanning many chunks in the right order")
    func readsManyChunksInOrder() throws {
        // A reader that mismanaged its offset would still produce *a* digest -- just not this one.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let bytes = ScratchTree.pattern(70_000)
        let path = try tree.write("big", bytes: bytes)
        let hasher = ContentHasher(configuration: .init(chunkBytes: 4096))
        #expect(try hasher.fullDigest(atPath: path).digest == ScratchTree.oneShot(bytes))
    }

    @Test("The F_NOCACHE path produces the same digest as the cached path")
    func noCachePathAgrees() throws {
        // F_NOCACHE changes how the kernel serves the read, not what it returns -- but an unaligned
        // buffer under F_NOCACHE is the kind of thing that works until it does not, so both paths are
        // asserted against the same reference.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let bytes = ScratchTree.pattern(50_000)
        let path = try tree.write("nc", bytes: bytes)
        let cached = ContentHasher(configuration: .init(chunkBytes: 4096, noCacheThreshold: .max))
        let uncached = ContentHasher(configuration: .init(chunkBytes: 4096, noCacheThreshold: 0))
        let reference = ScratchTree.oneShot(bytes)
        #expect(try cached.fullDigest(atPath: path).digest == reference)
        #expect(try uncached.fullDigest(atPath: path).digest == reference)
    }

    @Test("Reports a missing file as skippable rather than fatal")
    func reportsMissingFileAsSkippable() throws {
        // The CLI's sha256_file returns None for an unreadable file and the scan carries on
        // (src/rav/core/duplicates.py:208-219). A scan that aborts on the first vanished temporary
        // file is useless on a live machine.
        let hasher = ContentHasher()
        let missing = "/nonexistent-\(UUID().uuidString)/file"
        do {
            _ = try hasher.fullDigest(atPath: missing)
            Issue.record("expected a failure for \(missing)")
        } catch let error as HashingError {
            #expect(error.isSkippable)
            guard case .cannotOpen(let path, let code) = error else {
                Issue.record("expected cannotOpen, got \(error)")
                return
            }
            #expect(path == missing)
            #expect(code == ENOENT)
        }
    }

    @Test("Reports a directory as skippable")
    func reportsDirectoryAsSkippable() throws {
        // open(2) on a directory succeeds on macOS; the read is what fails, with EISDIR. A hasher that
        // only guarded the open would surface this as an unexpected error mid-scan.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher()
        do {
            _ = try hasher.fullDigest(atPath: tree.root)
            Issue.record("expected a failure")
        } catch let error as HashingError {
            #expect(error.isSkippable)
        }
    }

    @Test("Running out of memory is not skippable")
    func outOfMemoryIsNotSkippable() {
        // Skipping a file because the machine ran out of memory would under-report duplicates while
        // reporting success. Only the "this file is not readable" errnos are skippable.
        #expect(!HashingError.outOfMemory(bytes: 1).isSkippable)
        #expect(!HashingError.cannotOpen(path: "/x", code: EIO).isSkippable)
        #expect(HashingError.cannotOpen(path: "/x", code: EACCES).isSkippable)
        #expect(HashingError.readFailed(path: "/x", code: EISDIR).isSkippable)
    }
}

@Suite("ContentHasher prefix stage")
struct ContentHasherPrefixTests {
    @Test("Separates two same-size files that differ only in their last byte")
    func separatesOnTail() throws {
        // The case a head-only probe cannot see, and the whole reason the window is taken from both
        // ends: two MP4s differing only in a trailing moov atom share their entire leading mdat.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher(configuration: .init(prefixThreshold: 16, prefixWindow: 8))

        let base = ScratchTree.pattern(1000)
        var changed = base
        changed[999] = changed[999] &+ 1
        let a = try tree.write("a", bytes: base)
        let b = try tree.write("b", bytes: changed)

        let left = try hasher.prefixDigest(atPath: a, size: 1000)
        let right = try hasher.prefixDigest(atPath: b, size: 1000)
        #expect(left != right)
    }

    @Test("Does not separate identical content")
    func agreesForIdenticalContent() throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher(configuration: .init(prefixThreshold: 16, prefixWindow: 8))
        let bytes = ScratchTree.pattern(1000)
        let a = try tree.write("a", bytes: bytes)
        let b = try tree.write("b", bytes: bytes)
        #expect(
            try hasher.prefixDigest(atPath: a, size: 1000)
                == (try hasher.prefixDigest(atPath: b, size: 1000))
        )
    }

    @Test("Handles a file shorter than the window, and an empty one")
    func handlesShortFiles() throws {
        // The head and the tail overlap, or the tail read is skipped entirely. Neither may trap, and a
        // zero-length read must not ask for a zero-byte aligned allocation.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher(configuration: .init(prefixThreshold: 0, prefixWindow: 4096))
        let tiny = try tree.write("tiny", bytes: [1, 2, 3])
        #expect(throws: Never.self) { try hasher.prefixDigest(atPath: tiny, size: 3) }
        let empty = try tree.write("empty", bytes: [])
        #expect(throws: Never.self) { try hasher.prefixDigest(atPath: empty, size: 0) }
    }

    @Test("The probe is skipped for small files")
    func skipsProbeForSmallFiles() {
        // Below the threshold the probe costs a second open of a file one pread could consume whole,
        // so it is overhead rather than insurance.
        //
        // **8 MiB, not the 256 KiB this test used to pin.** Measured over a real 3,421-file tree: at 256 KiB the
        // probe fired on 1,912 files, cost 0.31 s of 0.89, and saved 1 MB of 1.517 GB. The threshold moved and
        // this expectation moved with it -- the tail case the probe exists for is a pair of multi-gigabyte files,
        // not a photograph.
        let hasher = ContentHasher()
        #expect(!hasher.usesPrefixStage(forSize: 1024))
        #expect(!hasher.usesPrefixStage(forSize: 256 << 10))
        #expect(!hasher.usesPrefixStage(forSize: 8 << 20))
        #expect(hasher.usesPrefixStage(forSize: (8 << 20) + 1))
    }

    @Test("Length participates, so files sharing both windows still differ")
    func lengthParticipates() throws {
        // Only reachable outside a size bucket, but the probe is a general-purpose discriminator and a
        // collision here would be silent. Both files start 0,1,2,3 and end 4,5,6,7.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher(configuration: .init(prefixThreshold: 0, prefixWindow: 4))
        let padded = try tree.write("padded", bytes: [0, 1, 2, 3, 9, 9, 4, 5, 6, 7])
        let tight = try tree.write("tight", bytes: [0, 1, 2, 3, 4, 5, 6, 7])
        #expect(
            try hasher.prefixDigest(atPath: padded, size: 10)
                != (try hasher.prefixDigest(atPath: tight, size: 8))
        )
    }

    @Test("A prefix collision costs work, never correctness")
    func prefixCollisionIsHarmless() throws {
        // Documented as a property, because it is what makes the probe safe to add: two files that
        // agree on head, tail and length still get a full read, and the full digest is what decides.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let hasher = ContentHasher(configuration: .init(prefixThreshold: 0, prefixWindow: 2))
        var left = ScratchTree.pattern(100)
        var right = left
        left[50] = 1
        right[50] = 2
        let a = try tree.write("a", bytes: left)
        let b = try tree.write("b", bytes: right)
        // The probe cannot tell them apart...
        #expect(
            try hasher.prefixDigest(atPath: a, size: 100)
                == (try hasher.prefixDigest(atPath: b, size: 100))
        )
        // ...and the full digest can.
        #expect(
            try hasher.fullDigest(atPath: a).digest != (try hasher.fullDigest(atPath: b).digest))
    }
}
