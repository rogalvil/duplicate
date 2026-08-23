import Foundation

/// What one cached entry holds: the hashes of one file.
///
/// One for an image, up to eight for a video, in time order.
public struct PerceptualCacheEntry: Hashable, Sendable {
    public let kind: MediaKind
    public let hashes: [PerceptualHash]

    public init(kind: MediaKind, hashes: [PerceptualHash]) {
        self.kind = kind
        self.hashes = hashes
    }
}

/// The on-disk layout for the perceptual cache: a header, then fixed-size rows, appended and never
/// rewritten in place.
///
/// **A sibling of ``HashCacheFormat`` rather than a generalisation of it.** The two caches share their key
/// -- file identity plus generation -- and their corruption story, and nothing else: one holds 32 bytes of
/// SHA-256, this holds up to eight 64-bit numbers and which kind of media they came from. Forcing one
/// format to carry both would put a discriminator in every row of both files to save about sixty lines.
///
/// **Fixed rows with eight slots, even for an image that uses one.** 56 bytes go unused per image, which on
/// the 2,779 images of the measured tree is 156 KB -- against a scan that costs 140 seconds. Variable-length
/// rows would buy that back and give up the arithmetic that detects a torn tail: `(fileSize - headerSize) %
/// recordSize != 0` is the whole crash-recovery story, and it only works when rows are one size.
public enum PerceptualCacheFormat {
    /// `RAVPC` plus a layout version, so a file from a future layout is recognised and discarded rather than
    /// misread.
    public static let magic: [UInt8] = Array("RAVPC1\0\0".utf8)
    public static let version: UInt32 = 1
    public static let headerSize = 32
    /// The most frames one row can hold. The CLI samples eight.
    public static let maximumFrames = 8
    /// 8 volume + 8 inode + 8 size + 8 mtime + 8 generation + 1 kind + 1 count + 2 padding + 64 hashes + 4 crc.
    ///
    /// A multiple of eight, so a row never straddles a word boundary in the mapped file.
    public static let recordSize = 112

    /// A hand-bumped number for changes the parameters cannot see.
    ///
    /// **Both halves of the salt are needed.** This one covers a change in *code* -- the grey formula, the
    /// resampler's weights, which corner of the transform is cropped -- where every parameter stays the same
    /// and the meaning of the number changes. ``salt(imageConfiguration:videoConfiguration:)`` covers the
    /// other half, the parameters themselves, so that the common case cannot be forgotten.
    public static let semanticVersion: UInt64 = 1

    /// The salt for a given pipeline, mixing the hand version with the parameters that decide the bits.
    ///
    /// **Derived rather than declared, because "remember to bump the constant" is a rule that gets forgotten
    /// exactly once and then serves numbers that mean something else.** Change the decode cap from 256 to 512
    /// and every cached hash is wrong; this makes the file's own header disagree and the cache rebuild itself.
    public static func salt(
        imageConfiguration: ImageHasher.Configuration,
        videoConfiguration: VideoHasher.Configuration
    ) -> UInt64 {
        var hash = FNV1a()
        hash.combine(ImageHasher.Configuration.version)
        hash.combine(UInt64(imageConfiguration.hashSize))
        hash.combine(UInt64(imageConfiguration.highFrequencyFactor))
        hash.combine(UInt64(imageConfiguration.decodeMaxPixelSize))
        hash.combine(UInt64(videoConfiguration.frameCount))
        hash.combine(UInt64(videoConfiguration.maximumSize))
        // The seek tolerance decides *which* frames come back, so it belongs here too. In milliseconds, so a
        // change of a hundredth of a second still counts.
        hash.combine(UInt64(max(0, videoConfiguration.toleranceSeconds * 1000).rounded()))
        hash.combine(semanticVersion)
        return hash.rawValue
    }

    // MARK: - Encoding

    /// - Parameter rowsAtLastPrune: how many rows the file held when dead ones were last removed. Lives in the
    ///   header's padding, which an older build ignores and this one reads as zero -- "never pruned", which is
    ///   right.
    public static func encodeHeader(salt: UInt64, rowsAtLastPrune: UInt64 = 0) -> [UInt8] {
        var bytes = magic
        bytes += littleEndian(version)
        bytes += littleEndian(UInt32(recordSize))
        bytes += littleEndian(salt)
        bytes += littleEndian(rowsAtLastPrune)
        bytes += [UInt8](repeating: 0, count: headerSize - bytes.count)
        return bytes
    }

    /// The marker written by ``encodeHeader(salt:rowsAtLastPrune:)``, or zero.
    public static func rowsAtLastPrune(_ bytes: [UInt8]) -> UInt64 {
        let offset = magic.count + 4 + 4 + 8
        guard bytes.count >= offset + 8 else { return 0 }
        var value: UInt64 = 0
        for index in (0..<8).reversed() {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return value
    }

    public static func decodeHeader(_ bytes: [UInt8], salt: UInt64) -> Bool {
        guard bytes.count >= headerSize else { return false }
        guard Array(bytes[0..<magic.count]) == magic else { return false }
        guard readUInt32(bytes, at: 8) == version else { return false }
        guard readUInt32(bytes, at: 12) == UInt32(recordSize) else { return false }
        return readUInt64(bytes, at: 16) == salt
    }

    public static func encode(key: HashCacheKey, entry: PerceptualCacheEntry) -> [UInt8] {
        var payload: [UInt8] = []
        payload.reserveCapacity(recordSize)
        payload += littleEndian(key.volume)
        payload += littleEndian(key.inode)
        payload += littleEndian(UInt64(bitPattern: key.size))
        payload += littleEndian(UInt64(bitPattern: key.mtimeNanoseconds))
        payload += littleEndian(key.generation)
        payload += [entry.kind == .image ? 0 : 1]
        let stored = entry.hashes.prefix(maximumFrames)
        payload += [UInt8(stored.count)]
        payload += [0, 0]
        for hash in stored { payload += littleEndian(hash.bits) }
        payload += [UInt8](repeating: 0, count: (maximumFrames - stored.count) * 8)
        payload += littleEndian(CRC32C.checksum(payload))
        return payload
    }

    /// Decodes one row, or `nil` when its CRC does not match.
    public static func decode(
        _ payload: [UInt8]
    ) -> (key: HashCacheKey, entry: PerceptualCacheEntry)? {
        guard payload.count == recordSize else { return nil }
        let stored = readUInt32(payload, at: recordSize - 4)
        guard CRC32C.checksum(Array(payload[0..<(recordSize - 4)])) == stored else { return nil }

        let volume = readUInt64(payload, at: 0)
        let inode = readUInt64(payload, at: 8)
        let size = Int64(bitPattern: readUInt64(payload, at: 16))
        let mtime = Int64(bitPattern: readUInt64(payload, at: 24))
        let generation = readUInt64(payload, at: 32)
        let kind: MediaKind = payload[40] == 0 ? .image : .video
        let count = Int(payload[41])
        guard count <= maximumFrames else { return nil }
        var hashes: [PerceptualHash] = []
        hashes.reserveCapacity(count)
        for index in 0..<count {
            hashes.append(PerceptualHash(bits: readUInt64(payload, at: 44 + index * 8)))
        }
        // A row claiming zero frames is a row that says nothing; treated as corrupt so it cannot mask a file
        // that should be hashed.
        guard !hashes.isEmpty else { return nil }
        return (
            HashCacheKey(
                volume: volume, inode: inode, size: size, mtimeNanoseconds: mtime,
                generation: generation),
            PerceptualCacheEntry(kind: kind, hashes: hashes)
        )
    }

    // MARK: - Bytes

    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        var value: UInt32 = 0
        for offset in 0..<4 { value |= UInt32(bytes[index + offset]) << (8 * UInt32(offset)) }
        return value
    }

    static func readUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for offset in 0..<8 { value |= UInt64(bytes[index + offset]) << (8 * UInt64(offset)) }
        return value
    }
}

/// Remembers the perceptual hashes of files that have not changed.
///
/// **This is where the cache stops being an optimisation.** Measured on the real test tree: 2,779 images and
/// 617 videos take **140 seconds**, and the video half is 93 of them because a video costs eight decodes. A
/// second scan of the same folder -- which is what a person does after moving a few files -- paid all of it
/// again.
///
/// Same shape as ``HashCache``, and for the same reasons: an append-only file of fixed rows in
/// `~/Library/Caches`, never in the state directory the CLI shares. A scan document is interop that cannot be
/// lost; this is derived data that macOS is free to purge under disk pressure, which is exactly the semantics
/// wanted.
///
/// **The key is the same too** -- volume, inode, size, mtime and generation -- so a file rewritten in place with
/// its modification date forced backwards still misses, which is the `rsync -t` case an mtime-keyed cache
/// serves stale.
public actor PerceptualCache {
    /// Where the cache lives for a bundle identifier.
    public static func defaultURL(
        bundleIdentifier: String = "com.rogalvil.duplicate",
        caches: URL? = nil
    ) -> URL {
        let base =
            caches
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Caches")
        return
            base
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "phashes.v1", directoryHint: .notDirectory)
    }

    /// What loading found, so a caller can report it instead of guessing.
    public struct LoadReport: Sendable, Equatable {
        public var recordsRead = 0
        /// Rows whose CRC did not match. Dropped individually.
        public var corruptRecords = 0
        /// Whether the file ended in a partial row, which is what a crash mid-append leaves.
        public var hadTornTail = false
        /// Whether the whole file was discarded: wrong magic, version, row size or salt.
        public var discardedFile = false
        /// Whether another process holds the write lock, so this instance reads but never appends.
        public var isReadOnly = false
    }

    private let url: URL
    private let salt: UInt64
    private var entries: [HashCacheKey: PerceptualCacheEntry] = [:]
    private var appended: [(key: HashCacheKey, entry: PerceptualCacheEntry)] = []
    private var recordsOnDisk = 0
    private var lockDescriptor: Int32 = -1
    private var rowsAtLastPrune: UInt64 = 0
    private let pruneFloor: Int
    private(set) public var report = LoadReport()

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    public init(
        url: URL = PerceptualCache.defaultURL(),
        imageConfiguration: ImageHasher.Configuration = ImageHasher.Configuration(),
        videoConfiguration: VideoHasher.Configuration = VideoHasher.Configuration(),
        pruneFloor: Int = HashCache.defaultPruneFloor
    ) {
        self.url = url
        self.pruneFloor = pruneFloor
        self.salt = PerceptualCacheFormat.salt(
            imageConfiguration: imageConfiguration, videoConfiguration: videoConfiguration)
    }

    /// Reads the file, dropping what it cannot trust.
    public func load() {
        report = LoadReport()
        entries.removeAll()
        recordsOnDisk = 0
        rowsAtLastPrune = 0
        acquireLock()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let bytes = [UInt8](data)
        guard bytes.count >= PerceptualCacheFormat.headerSize,
            PerceptualCacheFormat.decodeHeader(bytes, salt: salt)
        else {
            // A salt that no longer matches is the ordinary case, not an error: the pipeline changed and every
            // number in the file means something else now.
            report.discardedFile = !bytes.isEmpty
            return
        }

        rowsAtLastPrune = PerceptualCacheFormat.rowsAtLastPrune(bytes)
        let body = bytes.count - PerceptualCacheFormat.headerSize
        let whole = body / PerceptualCacheFormat.recordSize
        report.hadTornTail = body % PerceptualCacheFormat.recordSize != 0
        for index in 0..<whole {
            let start = PerceptualCacheFormat.headerSize + index * PerceptualCacheFormat.recordSize
            let row = Array(bytes[start..<(start + PerceptualCacheFormat.recordSize)])
            guard let decoded = PerceptualCacheFormat.decode(row) else {
                report.corruptRecords += 1
                continue
            }
            entries[decoded.key] = decoded.entry
            report.recordsRead += 1
        }
        recordsOnDisk = whole
    }

    /// The hashes for a file that has not changed, or `nil`.
    ///
    /// The kind is checked as well as the key: a file whose extension changed from `.mp4` to `.jpg` on the same
    /// inode would otherwise be served a list of eight frames as if it were an image.
    public func hashes(for entry: FileEntry, kind: MediaKind) -> [PerceptualHash]? {
        guard let key = HashCacheKey(entry: entry), let found = entries[key], found.kind == kind
        else { return nil }
        return found.hashes
    }

    public func store(_ hashes: [PerceptualHash], for entry: FileEntry, kind: MediaKind) {
        guard let key = HashCacheKey(entry: entry), !hashes.isEmpty else { return }
        let capped = Array(hashes.prefix(PerceptualCacheFormat.maximumFrames))
        let value = PerceptualCacheEntry(kind: kind, hashes: capped)
        // Only appended when it is new or different, so a warm scan writes nothing.
        if entries[key] == value { return }
        entries[key] = value
        appended.append((key, value))
    }

    /// Appends what is new. Returns how many rows were written.
    @discardableResult
    public func persist() throws -> Int {
        guard !appended.isEmpty else { return 0 }
        // Another process holds the lock. Every hit this instance served is still valid; only writing is off,
        // because two writers appending to one file interleave rows that no CRC can reassemble.
        guard !report.isReadOnly else { return 0 }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var payload: [UInt8] = []
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists || recordsOnDisk == 0 && report.recordsRead == 0 && report.discardedFile {
            // A fresh file, or one whose header this build cannot use: rewrite the header and every row known,
            // rather than appending rows under a header that says something else.
            payload += PerceptualCacheFormat.encodeHeader(salt: salt)
            for (key, entry) in entries {
                payload += PerceptualCacheFormat.encode(key: key, entry: entry)
            }
            try Data(payload).write(to: url, options: .atomic)
            let written = appended.count
            recordsOnDisk = entries.count
            appended.removeAll()
            return written
        }

        for row in appended {
            payload += PerceptualCacheFormat.encode(key: row.key, entry: row.entry)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(payload))
        let written = appended.count
        recordsOnDisk += written
        appended.removeAll()
        return written
    }

    /// Whether the file holds bytes this build cannot trust, so rewriting it reclaims something.
    ///
    /// Same reasoning as ``HashCache/needsRewrite``, including why a superseded-row ratio is the wrong rule: the
    /// key carries mtime and generation, so a changed file gets a new key instead of superseding a row. Measured
    /// on the real file: 3,396 rows, 3,396 distinct keys.
    ///
    /// A salt mismatch is not a trigger either. It means the pipeline changed and every number in the file
    /// means something else now -- ``persist()`` already rewrites the whole file in that case, under the new
    /// header, and doing it here as well would throw away a file a different build can still use.
    public var needsRewrite: Bool {
        (report.hadTornTail || report.corruptRecords > 0) && !report.isReadOnly
    }

    /// Whether enough rows have piled up since the last prune to be worth checking them.
    ///
    /// **Measured today at zero waste, and built for the bound rather than for the reclaim.** All 3,396 rows of
    /// the real file describe files that still exist -- a photo library churns far slower than the temporary
    /// trees that had made the digest cache 55.8% dead weight. What is still true is that the file grows a row
    /// per `(file, version)` ever seen and reclaims none, so a corpus that gets re-encoded or deleted leaves rows
    /// forever. The mechanism is shared with the digest cache, so this costs no new risk.
    public var needsPruning: Bool {
        !report.isReadOnly
            && recordsOnDisk >= max(pruneFloor, Int(rowsAtLastPrune) + pruneFloor)
    }

    /// Drops rows whose file is gone, and rewrites the file.
    ///
    /// Same three exceptions as the digest cache, for the same reasons: a row on an unmounted volume cannot be
    /// judged and this user's corpus lives on an external disk; a row that fails to resolve with anything other
    /// than `ENOENT` is this process being unable to look, not a deleted file; and a row that still matches is
    /// the point of a cache. Length is compared and mtime never is -- the key's mtime is `Date`-derived and
    /// `stat`'s is exact.
    @discardableResult
    public func prune() throws -> Int {
        guard !report.isReadOnly else { return 0 }
        let volumes = CacheLiveness.mountedVolumes()
        guard !volumes.isEmpty else { return 0 }

        var dropped = 0
        for (key, _) in entries {
            guard let devices = volumes[key.volume] else { continue }
            switch CacheLiveness.resolve(key: key, devices: devices) {
            case .gone, .lengthChanged:
                entries.removeValue(forKey: key)
                dropped += 1
            case .live, .cannotTell:
                continue
            }
        }
        // The marker moves either way, or every load pays for the lookups again.
        _ = try? compact()
        rowsAtLastPrune = UInt64(entries.count)
        return dropped
    }

    /// Loads, then rewrites the file if it holds bytes that cannot be trusted.
    ///
    /// A failed repair is dropped, not propagated: the hashes already loaded are still good, and a perceptual
    /// scan costs 177 seconds on a real tree.
    public func loadAndRepair() {
        load()
        if needsRewrite { _ = try? compact() }
        if needsPruning { _ = try? prune() }
    }

    /// Rewrites the file with one row per live key.
    ///
    /// Atomic: a temporary file in the same directory swapped in with `replaceItemAt`, so a crash during the
    /// rewrite leaves the old file rather than half of a new one. Rows go out in key order, which makes a
    /// byte-diff between two rewrites of the same content meaningful.
    @discardableResult
    public func compact() throws -> Int {
        guard !report.isReadOnly else { return 0 }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var payload = PerceptualCacheFormat.encodeHeader(
            salt: salt, rowsAtLastPrune: UInt64(entries.count))
        for key in entries.keys.sorted(by: PerceptualCache.isOrdered) {
            payload += PerceptualCacheFormat.encode(key: key, entry: entries[key]!)
        }

        let temporary = directory.appending(
            path: "phashes.v1.compacting-\(ProcessInfo.processInfo.processIdentifier)",
            directoryHint: .notDirectory
        )
        try Data(payload).write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        appended.removeAll()
        recordsOnDisk = entries.count
        report.hadTornTail = false
        report.corruptRecords = 0
        return entries.count
    }

    public var count: Int { entries.count }

    // MARK: - Locking

    /// Takes a non-blocking exclusive lock, degrading to read-only rather than waiting.
    ///
    /// The digest cache has had this since it shipped and this one did not, which was an inconsistency and not
    /// a decision: two processes appending 112-byte rows to one file interleave them, and a CRC can tell you a
    /// row is broken without being able to tell you which two writers made it. Derived data must never make two
    /// windows of the app wait on each other, so a loser reads and serves every hit it has.
    private func acquireLock() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = url.path(percentEncoded: false) + ".lock"
        if lockDescriptor >= 0 { close(lockDescriptor) }
        lockDescriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        guard lockDescriptor >= 0 else {
            report.isReadOnly = true
            return
        }
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            report.isReadOnly = true
        }
    }

    private static func isOrdered(_ a: HashCacheKey, _ b: HashCacheKey) -> Bool {
        if a.volume != b.volume { return a.volume < b.volume }
        if a.inode != b.inode { return a.inode < b.inode }
        if a.size != b.size { return a.size < b.size }
        if a.mtimeNanoseconds != b.mtimeNanoseconds {
            return a.mtimeNanoseconds < b.mtimeNanoseconds
        }
        return a.generation < b.generation
    }
}
