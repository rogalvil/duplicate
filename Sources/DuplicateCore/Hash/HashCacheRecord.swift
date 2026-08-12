import Foundation

/// What identifies a file for cache purposes.
///
/// Five fields, and the interesting one is `generation`. Foundation's `NSURLGenerationIdentifierKey`
/// advances whenever the data fork changes and is documented as persistent across restarts, which makes
/// it strictly stronger than a modification date. Verified on APFS: it advances on an append, on a
/// same-length rewrite, **and on a rewrite whose modification date was forced backwards with `utimes`**
/// -- which is exactly the `rsync -t` and `touch -r` case that makes an mtime-keyed cache serve a stale
/// digest for changed content.
///
/// `mtimeNanoseconds` stays in the key anyway, because not every volume reports a generation. When it is
/// absent the field is zero, and it is *in the key*, so a volume that gains support invalidates its old
/// entries cleanly rather than mixing two notions of freshness.
public struct HashCacheKey: Hashable, Sendable {
    public let volume: UInt64
    public let inode: UInt64
    public let size: Int64
    public let mtimeNanoseconds: Int64
    public let generation: UInt64

    public init(
        volume: UInt64,
        inode: UInt64,
        size: Int64,
        mtimeNanoseconds: Int64,
        generation: UInt64
    ) {
        self.volume = volume
        self.inode = inode
        self.size = size
        self.mtimeNanoseconds = mtimeNanoseconds
        self.generation = generation
    }

    /// The key for a walked file, or `nil` when the volume did not report an identity.
    ///
    /// `nil` rather than a fabricated key: a file with no inode cannot be recognised again, and inventing
    /// a key from its path would make the cache serve a stale digest after a rename.
    public init?(entry: FileEntry) {
        guard let identity = entry.identity else { return nil }
        self.init(
            volume: identity.volume,
            inode: identity.inode,
            size: entry.size,
            mtimeNanoseconds: entry.modifiedNanoseconds ?? 0,
            generation: entry.generation ?? 0
        )
    }
}

/// One fixed-size row in the cache file.
public struct HashCacheRecord: Hashable, Sendable {
    public let key: HashCacheKey
    public let digest: Digest32

    public init(key: HashCacheKey, digest: Digest32) {
        self.key = key
        self.digest = digest
    }
}

/// The on-disk layout: a small header, then fixed-size rows, appended and never rewritten in place.
///
/// **Why not SQLite.** `libsqlite3.tbd` ships in the SDK and `.linkedLibrary("sqlite3")` downloads
/// nothing, so it would be *permitted* under the project's zero-dependency rule -- a system library like
/// CryptoKit. It is rejected on merit. The workload is a point lookup on a composite key: no range
/// queries, one writer. SQL, indices, a query planner and a WAL buy nothing, and they bring a WAL file, a
/// shm file, `busy_timeout` semantics and a `sqlite3_step` interop loop -- which is *more* corruption
/// surface, not less.
///
/// The corruption story here fits in one sentence, which is the point: a torn final record is detected by
/// arithmetic on the file length, an individually corrupt record by its CRC-32C, and a wrong magic or
/// version discards the whole file. **There is no state in which the cache can be wrong without also
/// failing its CRC.**
public enum HashCacheFormat {
    /// `RAVHC` plus a version, so a file from a future layout is recognised and discarded rather than
    /// misread.
    public static let magic: [UInt8] = Array("RAVHC1\0\0".utf8)
    public static let version: UInt32 = 1
    public static let headerSize = 32
    /// 8 volume + 8 inode + 8 size + 8 mtime + 8 generation + 32 digest + 4 crc + 4 padding.
    ///
    /// Padded to a multiple of eight so a record never straddles a word boundary in the mapped file.
    public static let recordSize = 80

    /// A value bumped when the *meaning* of a digest changes -- a different chunking scheme, say.
    ///
    /// Stored in the header rather than the key, because it invalidates every row at once. Without it, a
    /// change to the hashing pipeline would silently serve digests computed by the old one.
    public static let semanticSalt: UInt64 = 1

    // MARK: - Encoding

    public static func encodeHeader() -> [UInt8] {
        var bytes = magic
        bytes += littleEndian(version)
        bytes += littleEndian(UInt32(recordSize))
        bytes += littleEndian(semanticSalt)
        bytes += [UInt8](repeating: 0, count: headerSize - bytes.count)
        return bytes
    }

    public static func encode(_ record: HashCacheRecord) -> [UInt8] {
        var payload: [UInt8] = []
        payload.reserveCapacity(recordSize)
        payload += littleEndian(record.key.volume)
        payload += littleEndian(record.key.inode)
        payload += littleEndian(UInt64(bitPattern: record.key.size))
        payload += littleEndian(UInt64(bitPattern: record.key.mtimeNanoseconds))
        payload += littleEndian(record.key.generation)
        payload += record.digest.bytes
        payload += littleEndian(CRC32C.checksum(payload))
        payload += [0, 0, 0, 0]
        return payload
    }

    // MARK: - Decoding

    /// Whether a header is one this build can read.
    public static func isReadableHeader(_ bytes: some Collection<UInt8>) -> Bool {
        let array = Array(bytes)
        guard array.count >= headerSize else { return false }
        guard Array(array[0..<8]) == magic else { return false }
        guard readUInt32(array, at: 8) == version else { return false }
        guard readUInt32(array, at: 12) == UInt32(recordSize) else { return false }
        guard readUInt64(array, at: 16) == semanticSalt else { return false }
        return true
    }

    /// Decodes one record, or `nil` when its CRC does not match.
    ///
    /// A `nil` here means exactly one row is unusable. The caller drops it and keeps the rest, which is
    /// the whole reason the checksum is per record rather than per file.
    public static func decode(_ bytes: some Collection<UInt8>) -> HashCacheRecord? {
        let array = Array(bytes)
        guard array.count == recordSize else { return nil }
        // The checksum covers the 40 key bytes plus the 32 digest bytes, and sits at offset 72. Getting
        // these two numbers wrong is silent: every record round-trips as nil and the cache simply never
        // hits, which looks like a cold machine rather than a bug. The round-trip test is what caught it.
        let checksummed = Array(array[0..<72])
        guard readUInt32(array, at: 72) == CRC32C.checksum(checksummed) else { return nil }
        guard let digest = Digest32(bytes: array[40..<72]) else { return nil }
        return HashCacheRecord(
            key: HashCacheKey(
                volume: readUInt64(array, at: 0),
                inode: readUInt64(array, at: 8),
                size: Int64(bitPattern: readUInt64(array, at: 16)),
                mtimeNanoseconds: Int64(bitPattern: readUInt64(array, at: 24)),
                generation: readUInt64(array, at: 32)
            ),
            digest: digest
        )
    }

    /// How many whole records a file of this length holds, ignoring a torn tail.
    ///
    /// A crash mid-append leaves a partial record. Detecting it by arithmetic rather than by a footer
    /// means the file needs no clean-shutdown marker, and every record written before the crash stays
    /// readable.
    public static func wholeRecordCount(inFileOfLength length: Int) -> Int {
        guard length >= headerSize else { return 0 }
        return (length - headerSize) / recordSize
    }

    /// Whether a file of this length ends in a torn record.
    public static func hasTornTail(inFileOfLength length: Int) -> Bool {
        guard length > headerSize else { return length != headerSize && length != 0 }
        return (length - headerSize) % recordSize != 0
    }

    // MARK: - Byte helpers

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    private static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }
}

/// CRC-32C, the Castagnoli polynomial.
///
/// Chosen over CRC-32 because it detects the burst errors a torn write produces slightly better, and
/// over a cryptographic hash because this is guarding against corruption, not against an adversary --
/// nobody is forging cache rows to make the app delete a file, and if they could write to the cache they
/// could write to the files.
enum CRC32C {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0x82F6_3B78 : value >> 1
            }
            return value
        }
    }()

    static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}
