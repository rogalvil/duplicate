import CryptoKit
import Foundation

/// What a file's content hashes to, plus how many bytes were actually read.
///
/// The byte count is returned rather than assumed because a file can change between the walk and the
/// hash. A digest computed over a different length than the walk recorded is still a correct digest
/// of what is on disk now -- but it is no longer evidence that this file matches the others in its
/// size bucket, and the caller has to know that.
public struct HashResult: Hashable, Sendable {
    public let digest: Digest32
    public let byteCount: Int64

    public init(digest: Digest32, byteCount: Int64) {
        self.digest = digest
        self.byteCount = byteCount
    }
}

/// Hashes file content. Injected so downstream stages can be driven without a filesystem.
public protocol FileHashing: Sendable {
    /// Whether a file of this size is worth probing before reading it whole.
    func usesPrefixStage(forSize size: Int64) -> Bool
    /// A cheap discriminator over the head, the tail and the length. Never a content identity.
    func prefixDigest(atPath path: String, size: Int64) throws -> Digest32
    /// The full SHA-256, and the number of bytes it covered.
    func fullDigest(atPath path: String) throws -> HashResult
}

/// SHA-256 over `pread`, with an optional cheap prefix stage.
///
/// SHA-256 and not something faster, for two reasons. It is the digest in the JSON shared with the
/// CLI, so it is not negotiable for the full stage. And `Insecure.MD5` would be a *pessimisation*
/// dressed as an optimisation: Apple Silicon has dedicated SHA-256 instructions and none for MD5, so
/// the "fast" hash is the slower one here. If measurement ever shows hashing dominating, the answer is
/// a hand-written xxHash for the prefix stage -- not a slower cryptographic hash, and not before the
/// benchmark says so.
public struct ContentHasher: FileHashing, Sendable {
    public struct Configuration: Sendable {
        /// Read size. The CLI uses 1 MiB (`src/rav/core/duplicates.py:213`); keeping it means a
        /// chunk-boundary bug shows up the same way in both tools. Whether 4 MiB is better under
        /// `F_NOCACHE` is a measurement nobody has taken yet, so the default stays where the CLI is.
        public var chunkBytes: Int
        /// Files at least this large are read with `F_NOCACHE`.
        ///
        /// Below it there is no second read to benefit from the cache, so caching costs one entry the
        /// OS reclaims anyway -- and it makes a cancelled-then-restarted scan fast. Above it, caching
        /// costs gigabytes of eviction for zero reuse.
        public var noCacheThreshold: Int64
        /// Files larger than this get a prefix probe before the full read.
        ///
        /// Below it, the probe costs a second `open` of a file that one `pread` could have consumed
        /// whole, so it is pure overhead.
        public var prefixThreshold: Int64
        /// How many bytes to take from each end during the probe.
        public var prefixWindow: Int

        public init(
            chunkBytes: Int = 1 << 20,
            noCacheThreshold: Int64 = 1 << 20,
            prefixThreshold: Int64 = 256 << 10,
            prefixWindow: Int = 4 << 10
        ) {
            self.chunkBytes = chunkBytes
            self.noCacheThreshold = noCacheThreshold
            self.prefixThreshold = prefixThreshold
            self.prefixWindow = prefixWindow
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Whether a file of this size is worth probing before reading it whole.
    public func usesPrefixStage(forSize size: Int64) -> Bool {
        size > configuration.prefixThreshold
    }

    /// Hashes the first and last `prefixWindow` bytes together with the length.
    ///
    /// **Head and tail, not head alone.** The failure mode is media containers: a burst of photos from
    /// one camera shares an identical EXIF/JFIF header for hundreds of bytes, and two MP4s that differ
    /// only in a trailing `moov` atom share their entire leading `mdat`. Reading the tail costs one
    /// extra `pread` and separates exactly the cases the head cannot.
    ///
    /// Honest about what this buys: size bucketing already eliminates most distinct files, because a
    /// camera JPEG's byte length is effectively a hash of its content. This is **insurance against a
    /// pathological bucket**, not a throughput win for the median library -- two 4 GB disk images of
    /// the same length go from 8 GB of reads to 16 KiB. A prefix collision is harmless: it only costs
    /// a full read that would have happened anyway.
    public func prefixDigest(atPath path: String, size: Int64) throws -> Digest32 {
        let window = min(configuration.prefixWindow, Int(clamping: size))
        let reader = try ChunkedReader(
            path: path,
            capacity: max(window, 1),
            bypassingCache: size >= configuration.noCacheThreshold
        )
        var hasher = SHA256()
        // The length participates so two files that share both windows but differ in length cannot
        // collide -- which matters when this is used outside a size bucket.
        var length = size.bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }

        let head = try reader.read(at: 0, upTo: window)
        hasher.update(bufferPointer: head)
        if size > Int64(window) {
            let tail = try reader.read(at: size - Int64(window), upTo: window)
            hasher.update(bufferPointer: tail)
        }
        guard let digest = Digest32(bytes: hasher.finalize()) else {
            throw HashingError.readFailed(path: path, code: EINVAL)
        }
        return digest
    }

    /// Hashes the whole file, reading until end of file rather than trusting a recorded size.
    public func fullDigest(atPath path: String) throws -> HashResult {
        // The threshold decision needs a size, and asking the file is cheaper and more truthful than
        // trusting what the walk saw minutes ago.
        let probe = try ChunkedReader(path: path, capacity: 1, bypassingCache: false)
        let size = try probe.currentSize()

        let reader = try ChunkedReader(
            path: path,
            capacity: configuration.chunkBytes,
            bypassingCache: size >= configuration.noCacheThreshold
        )
        var hasher = SHA256()
        var offset: Int64 = 0
        while true {
            let chunk = try reader.read(at: offset)
            if chunk.count == 0 { break }
            hasher.update(bufferPointer: chunk)
            offset += Int64(chunk.count)
        }
        guard let digest = Digest32(bytes: hasher.finalize()) else {
            throw HashingError.readFailed(path: path, code: EINVAL)
        }
        return HashResult(digest: digest, byteCount: offset)
    }
}
