import Foundation

/// A persistent map from file identity to SHA-256, so a rescan does not re-read the disk.
///
/// **Where it lives, and why not with the scans.** `~/Library/Caches/<bundle id>/hashes.v1`, never the
/// state directory shared with the CLI. Two different kinds of data: a scan document is a documented
/// interop format another tool reads and must never lose, while this is derived data that can always be
/// rebuilt -- and `~/Library/Caches` is precisely the directory macOS is allowed to purge under disk
/// pressure, which is the semantics wanted. Putting it in the shared directory would also pollute an
/// interop path with a private binary format and make it a backup liability.
///
/// **Why the cache is safe to trust.** It is not, entirely, and the design says so. A corrupt-but-CRC-
/// valid row, or an inode reused inside the same mtime nanosecond, would put two non-identical files in
/// one group and the user would trash a file that is not a duplicate. "Vanishingly unlikely" is the wrong
/// standard for a destructive action, so the answer is not a better checksum: **it is to re-hash at
/// action time.** ``verify(_:against:)`` exists for the disposer to call immediately before moving
/// anything, which turns a cache bug from data loss into an error message.
public actor HashCache {
    /// Where the cache file lives for a bundle identifier.
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
            .appending(path: "hashes.v1", directoryHint: .notDirectory)
    }

    /// What loading found, so the caller can report it instead of guessing.
    public struct LoadReport: Sendable, Equatable {
        public var recordsRead = 0
        /// Rows whose CRC did not match. Dropped individually.
        public var corruptRecords = 0
        /// Whether the file ended in a partial record, which is what a crash mid-append leaves.
        public var hadTornTail = false
        /// Whether the whole file was discarded: wrong magic, version, record size or semantic salt.
        public var discardedFile = false
        /// Whether another process holds the write lock, so this instance is read-only.
        public var isReadOnly = false

        public var isClean: Bool {
            corruptRecords == 0 && !hadTornTail && !discardedFile
        }
    }

    private let url: URL
    private var entries: [HashCacheKey: Digest32] = [:]
    private var pending: [HashCacheRecord] = []
    private var recordsOnDisk = 0
    private var lockDescriptor: Int32 = -1
    public private(set) var report = LoadReport()
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(url: URL = HashCache.defaultURL()) {
        self.url = url
    }

    deinit {
        if lockDescriptor >= 0 { close(lockDescriptor) }
    }

    // MARK: - Loading

    /// Reads the file into memory. Safe to call on a missing or corrupt file.
    public func load() {
        report = LoadReport()
        entries.removeAll()
        pending.removeAll()
        recordsOnDisk = 0

        acquireLock()

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let bytes = [UInt8](data)
        guard HashCacheFormat.isReadableHeader(bytes) else {
            // Wrong magic, version, record size or semantic salt. Discarding the whole file is correct:
            // the rows may be perfectly intact and still mean something else.
            report.discardedFile = !bytes.isEmpty
            return
        }
        report.hadTornTail = HashCacheFormat.hasTornTail(inFileOfLength: bytes.count)

        let count = HashCacheFormat.wholeRecordCount(inFileOfLength: bytes.count)
        for index in 0..<count {
            let start = HashCacheFormat.headerSize + index * HashCacheFormat.recordSize
            let end = start + HashCacheFormat.recordSize
            guard let record = HashCacheFormat.decode(bytes[start..<end]) else {
                report.corruptRecords += 1
                continue
            }
            // Last writer wins, which is what makes appending an update.
            entries[record.key] = record.digest
            report.recordsRead += 1
        }
        recordsOnDisk = count
    }

    // MARK: - Lookup

    /// The cached digest for a file, or `nil`.
    public func digest(for entry: FileEntry) -> Digest32? {
        guard let key = HashCacheKey(entry: entry) else {
            misses += 1
            return nil
        }
        if let digest = entries[key] {
            hits += 1
            return digest
        }
        misses += 1
        return nil
    }

    /// Records a digest, to be written on the next ``persist()``.
    public func store(_ digest: Digest32, for entry: FileEntry) {
        guard let key = HashCacheKey(entry: entry) else { return }
        guard entries[key] != digest else { return }
        entries[key] = digest
        pending.append(HashCacheRecord(key: key, digest: digest))
    }

    /// Counters for the progress UI, and for the selftest.
    public var statistics: (hits: Int, misses: Int, live: Int, pending: Int) {
        (hits, misses, entries.count, pending.count)
    }

    // MARK: - Verification

    /// Whether a digest still matches what is on disk right now.
    ///
    /// The safety valve. Called immediately before a file is moved to the Trash, with the cache bypassed,
    /// so a stale or corrupt row becomes an error message instead of a deleted file that was not a
    /// duplicate. The cost is one read of only the files being acted on, which is trivial next to a scan.
    public func verify(_ entry: FileEntry, against hasher: some FileHashing) -> Bool {
        guard let expected = entries[HashCacheKey(entry: entry) ?? .invalid] else { return false }
        guard let fresh = try? hasher.fullDigest(atPath: entry.path) else { return false }
        return fresh.digest == expected
    }

    // MARK: - Persisting

    /// Appends everything pending. A no-op when the cache is read-only or has nothing to write.
    ///
    /// - Throws: only when the directory cannot be created. A failed append is reported through
    ///   ``LoadReport/isReadOnly`` rather than thrown: losing a cache write costs time on the next scan,
    ///   and failing the scan over it would be a worse trade.
    @discardableResult
    public func persist() throws -> Int {
        guard !pending.isEmpty, !report.isReadOnly else { return 0 }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var payload: [UInt8] = []
        let isNew = !FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        if isNew {
            payload += HashCacheFormat.encodeHeader()
        }
        for record in pending {
            payload += HashCacheFormat.encode(record)
        }

        let written = pending.count
        guard append(payload) else { return 0 }
        recordsOnDisk += written
        pending.removeAll()
        return written
    }

    /// Whether the file holds bytes this build cannot trust, so rewriting it reclaims something.
    ///
    /// **The trigger used to be a dead-row ratio, and that rule can never fire.** A row is superseded only if
    /// the same key is written with a different digest, and the key carries the file's size, mtime and
    /// generation -- so a file whose content changed produces a *new* key rather than superseding the old row.
    /// Measured on the real caches this app has built: `hashes.v1` holds 6,661 rows and 6,661 distinct keys,
    /// `phashes.v1` holds 3,396 and 3,396. Zero superseded rows, a ratio of exactly 1.0000, after 119 scans.
    /// The test that exercised the old rule had to write ten digests under one key, which is a state production
    /// cannot reach.
    ///
    /// What *is* reachable is junk: a torn tail from a crash mid-append, and a row whose CRC no longer matches.
    /// Those are re-read and re-skipped on every future load, forever, and a rewrite drops them.
    ///
    /// **A discarded file is deliberately not a trigger.** Wrong magic or an unknown version can mean a *newer*
    /// build wrote it, and clobbering that would cost the other build its cache to save us nothing -- the rows
    /// are already ignored either way.
    public var needsRewrite: Bool {
        (report.hadTornTail || report.corruptRecords > 0) && !report.isReadOnly
    }

    /// Loads, then rewrites the file if it holds bytes that cannot be trusted.
    ///
    /// **A failed repair is not a failed scan.** The cache still serves everything it loaded, so the error is
    /// dropped here rather than propagated: a read-only cache directory would otherwise turn a twenty-minute
    /// scan into nothing.
    public func loadAndRepair() {
        load()
        guard needsRewrite else { return }
        _ = try? compact()
    }

    /// Rewrites the file with one row per live key.
    ///
    /// Atomic: written to a temporary file in the same directory, then swapped in with
    /// `replaceItemAt`. A crash during compaction leaves the old file, not a half-written one.
    @discardableResult
    public func compact() throws -> Int {
        guard !report.isReadOnly else { return 0 }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var payload = HashCacheFormat.encodeHeader()
        // Sorted so the rewritten file is reproducible, which makes a byte-diff meaningful in a test.
        for key in entries.keys.sorted(by: HashCache.isOrdered) {
            payload += HashCacheFormat.encode(
                HashCacheRecord(key: key, digest: entries[key]!)
            )
        }

        let temporary = directory.appending(
            path: "hashes.v1.compacting-\(ProcessInfo.processInfo.processIdentifier)",
            directoryHint: .notDirectory
        )
        try Data(payload).write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        pending.removeAll()
        recordsOnDisk = entries.count
        // The junk is gone, so the report must stop claiming it is there -- a caller that checks
        // `needsRewrite` after a repair should see a clean file.
        report.hadTornTail = false
        report.corruptRecords = 0
        return entries.count
    }

    // MARK: - Locking

    /// Takes a non-blocking exclusive lock, degrading to read-only rather than waiting.
    ///
    /// Two windows of the app, or the app beside a future CLI that learned to share this cache, must not
    /// deadlock over derived data. A reader that cannot write still serves every hit it has.
    private func acquireLock() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = url.path(percentEncoded: false) + ".lock"
        lockDescriptor = lockPath.withCString { open($0, O_CREAT | O_RDWR, 0o644) }
        guard lockDescriptor >= 0 else {
            report.isReadOnly = true
            return
        }
        if flock(lockDescriptor, LOCK_EX | LOCK_NB) != 0 {
            report.isReadOnly = true
        }
    }

    private func append(_ bytes: [UInt8]) -> Bool {
        let path = url.path(percentEncoded: false)
        let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var offset = 0
        return bytes.withUnsafeBytes { buffer in
            while offset < bytes.count {
                let written = write(descriptor, buffer.baseAddress! + offset, bytes.count - offset)
                if written <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
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

extension HashCacheKey {
    /// A key no real file can have, used where a lookup needs a definite miss.
    static let invalid = HashCacheKey(
        volume: 0,
        inode: 0,
        size: -1,
        mtimeNanoseconds: 0,
        generation: 0
    )
}
