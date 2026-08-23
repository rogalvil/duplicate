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
    /// Rows the file held when dead ones were last removed, from the header.
    private var rowsAtLastPrune: UInt64 = 0
    private let pruneFloor: Int
    public private(set) var report = LoadReport()
    public private(set) var hits = 0
    public private(set) var misses = 0

    /// - Parameter pruneFloor: how many rows must pile up before dead ones are looked for. Injectable so a test
    ///   can reach the rule without writing four thousand files; production never passes it.
    public init(
        url: URL = HashCache.defaultURL(), pruneFloor: Int = HashCache.defaultPruneFloor
    ) {
        self.url = url
        self.pruneFloor = pruneFloor
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
        rowsAtLastPrune = 0

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
        rowsAtLastPrune = HashCacheFormat.rowsAtLastPrune(bytes)

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

    /// Whether enough rows have piled up since the last prune to be worth checking them.
    ///
    /// **Measured, and the number is why this exists.** On this machine the digest cache held 7,741 rows of
    /// which **1,609 still described a file that is there**: 4,320 gone and 1,812 an older version of a file
    /// that still exists. **79.2% waste.** A cache that is four-fifths garbage also loads four-fifths garbage
    /// into a dictionary on every scan.
    ///
    /// The check itself is not free -- one inode lookup per row, measured at 3.4 µs, so 26 ms for 7,741 rows and
    /// about 340 ms at a hundred thousand. Too much to pay on every load, which is why the file remembers how
    /// many rows it held when it was last cleaned and this only fires once another few thousand have arrived.
    public var needsPruning: Bool {
        !report.isReadOnly && recordsOnDisk >= max(pruneFloor, Int(rowsAtLastPrune) + pruneFloor)
    }

    /// How many rows have to accumulate before a prune is worth its inode lookups.
    ///
    /// Injectable so a test can reach the rule without writing four thousand files; production never passes it.
    public static let defaultPruneFloor = 4_000

    /// Drops rows whose file is gone, and rewrites the file.
    ///
    /// **Three classes of row are deliberately kept.** A row on a volume that is not mounted right now cannot be
    /// judged at all, and this user's corpus lives on an external disk -- reading "cannot resolve" as "delete"
    /// would throw away the cache that took 177 seconds to build the moment it is unplugged. A row whose inode
    /// fails to resolve for any reason other than `ENOENT` is kept for the same reason one step smaller:
    /// revoking Desktop access makes every row for a file there stop resolving, and those files never moved.
    /// And a row that still matches is kept because that is the point of a cache.
    ///
    /// - Returns: how many rows were dropped.
    @discardableResult
    public func prune() throws -> Int {
        guard !report.isReadOnly else { return 0 }
        let volumes = CacheLiveness.mountedVolumes()
        guard !volumes.isEmpty else { return 0 }

        var dropped = 0
        for (key, _) in entries {
            guard let devices = volumes[key.volume] else { continue }
            // `.cannotTell` and an unmounted volume are both kept: see the note on ``prune()``.
            switch CacheLiveness.resolve(key: key, devices: devices) {
            case .gone, .lengthChanged:
                entries.removeValue(forKey: key)
                dropped += 1
            case .live, .cannotTell:
                continue
            }
        }
        guard dropped > 0 else {
            // Nothing to drop, and the marker still has to move or every load pays the lookups again.
            rowsAtLastPrune = UInt64(entries.count)
            _ = try? compact()
            return 0
        }
        _ = try compact()
        rowsAtLastPrune = UInt64(entries.count)
        return dropped
    }

    /// Loads, then rewrites the file if it holds bytes that cannot be trusted.
    ///
    /// **A failed repair is not a failed scan.** The cache still serves everything it loaded, so the error is
    /// dropped here rather than propagated: a read-only cache directory would otherwise turn a twenty-minute
    /// scan into nothing.
    public func loadAndRepair() {
        load()
        if needsRewrite { _ = try? compact() }
        // Pruning after the repair, because a repair drops junk rows and pruning should see the file it leaves.
        if needsPruning { _ = try? prune() }
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

        var payload = HashCacheFormat.encodeHeader(rowsAtLastPrune: UInt64(entries.count))
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
