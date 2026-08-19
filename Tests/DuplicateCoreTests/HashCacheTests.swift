import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private func entry(
    path: String = "/x/a.bin",
    size: Int64 = 1000,
    volume: UInt64 = 7,
    inode: UInt64 = 42,
    mtime: Int64? = 1_700_000_000_000_000_000,
    generation: UInt64? = 5
) -> FileEntry {
    FileEntry(
        path: path,
        size: size,
        identity: FileIdentity(volume: volume, inode: inode),
        generation: generation,
        modifiedNanoseconds: mtime
    )
}

private struct CacheScratch {
    let directory: String
    var url: URL {
        URL(filePath: directory).appending(path: "hashes.v1", directoryHint: .notDirectory)
    }

    init() throws {
        directory = NSTemporaryDirectory() + "/duplicate-cache-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(atPath: directory) }

    func bytes() throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }
    func write(_ bytes: [UInt8]) throws { try Data(bytes).write(to: url) }
}

@Suite("CRC32C")
struct CRC32CTests {
    @Test("Matches the published check value")
    func matchesPublishedCheckValue() {
        // The standard check vector for CRC-32C: the ASCII string "123456789" gives 0xE3069283. Asserting
        // a published value rather than "whatever this code produced" is the difference between a
        // regression test and a tautology.
        #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
        #expect(CRC32C.checksum([]) == 0)
    }

    @Test("Changes when any byte changes")
    func detectsSingleByteChange() {
        var bytes = Array("the quick brown fox".utf8)
        let original = CRC32C.checksum(bytes)
        for index in bytes.indices {
            var mutated = bytes
            mutated[index] = mutated[index] &+ 1
            #expect(CRC32C.checksum(mutated) != original, "byte \(index) went undetected")
        }
        bytes.append(0)
        #expect(CRC32C.checksum(bytes) != original)
    }
}

@Suite("HashCacheFormat")
struct HashCacheFormatTests {
    @Test("A record round-trips through its byte layout")
    func recordRoundTrips() throws {
        let record = HashCacheRecord(
            key: HashCacheKey(
                volume: 0xDEAD_BEEF_CAFE_0001,
                inode: 12345,
                size: 987_654_321,
                mtimeNanoseconds: -42,  // negative is representable: a date before 1970
                generation: 0xFFFF_FFFF_FFFF_FFFF
            ),
            digest: digest("a")
        )
        let bytes = HashCacheFormat.encode(record)
        #expect(bytes.count == HashCacheFormat.recordSize)
        #expect(HashCacheFormat.decode(bytes) == record)
    }

    @Test("Rejects a record whose CRC does not match")
    func rejectsCorruptRecord() {
        // Per record, not per file, so one flipped byte costs one row rather than the whole cache.
        var bytes = HashCacheFormat.encode(
            HashCacheRecord(key: HashCacheKey(entry: entry())!, digest: digest("b"))
        )
        #expect(HashCacheFormat.decode(bytes) != nil)
        bytes[20] = bytes[20] &+ 1
        #expect(HashCacheFormat.decode(bytes) == nil)
    }

    @Test("Rejects a record of the wrong length")
    func rejectsWrongLength() {
        let bytes = HashCacheFormat.encode(
            HashCacheRecord(key: HashCacheKey(entry: entry())!, digest: digest("c"))
        )
        #expect(HashCacheFormat.decode(Array(bytes.dropLast())) == nil)
        #expect(HashCacheFormat.decode(bytes + [0]) == nil)
    }

    @Test("Accepts only its own header")
    func acceptsOnlyItsOwnHeader() {
        var header = HashCacheFormat.encodeHeader()
        #expect(header.count == HashCacheFormat.headerSize)
        #expect(HashCacheFormat.isReadableHeader(header))

        // Wrong magic: a file from another tool, or a truncated one.
        var wrongMagic = header
        wrongMagic[0] = UInt8(ascii: "X")
        #expect(!HashCacheFormat.isReadableHeader(wrongMagic))

        // Wrong version, record size, or semantic salt: the rows may be perfectly intact and still mean
        // something else, which is why the whole file is refused rather than read.
        for offset in [8, 12, 16] {
            var mutated = header
            mutated[offset] = mutated[offset] &+ 1
            #expect(!HashCacheFormat.isReadableHeader(mutated), "offset \(offset) was accepted")
        }
        header.removeLast()
        #expect(!HashCacheFormat.isReadableHeader(header))
    }

    @Test("Counts whole records and spots a torn tail")
    func countsRecordsAndTornTails() {
        let header = HashCacheFormat.headerSize
        let record = HashCacheFormat.recordSize
        #expect(HashCacheFormat.wholeRecordCount(inFileOfLength: header) == 0)
        #expect(HashCacheFormat.wholeRecordCount(inFileOfLength: header + record) == 1)
        #expect(HashCacheFormat.wholeRecordCount(inFileOfLength: header + record * 3) == 3)
        // A crash mid-append leaves a partial row. Detecting it by arithmetic means the file needs no
        // clean-shutdown marker and everything written before the crash stays readable.
        #expect(HashCacheFormat.wholeRecordCount(inFileOfLength: header + record + 7) == 1)
        #expect(!HashCacheFormat.hasTornTail(inFileOfLength: header + record * 2))
        #expect(HashCacheFormat.hasTornTail(inFileOfLength: header + record + 7))
    }
}

@Suite("HashCacheKey")
struct HashCacheKeyTests {
    @Test("Refuses a file with no identity")
    func refusesFileWithoutIdentity() {
        // A file with no inode cannot be recognised again, and inventing a key from its path would make
        // the cache serve a stale digest after a rename.
        #expect(HashCacheKey(entry: FileEntry(path: "/x", size: 1)) == nil)
        #expect(HashCacheKey(entry: entry()) != nil)
    }

    @Test("Treats a missing generation or mtime as zero, inside the key")
    func absentFieldsAreInTheKey() {
        // Not every volume reports a generation. Keeping the field in the key means a volume that gains
        // support invalidates its old rows cleanly instead of mixing two notions of freshness.
        let withGeneration = HashCacheKey(entry: entry(generation: 5))!
        let without = HashCacheKey(entry: entry(generation: nil))!
        #expect(withGeneration != without)
        #expect(without.generation == 0)
        #expect(HashCacheKey(entry: entry(mtime: nil))!.mtimeNanoseconds == 0)
    }
}

@Suite("HashCache")
struct HashCacheTests {
    @Test("Stores, persists and reloads a digest")
    func roundTripsThroughDisk() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }

        let writer = HashCache(url: scratch.url)
        await writer.load()
        await writer.store(digest("a"), for: entry())
        #expect(try await writer.persist() == 1)

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.digest(for: entry()) == digest("a"))
        #expect(await reader.report.isClean)
        #expect(await reader.report.recordsRead == 1)
    }

    @Test("Any change to the key is a miss")
    func anyKeyChangeMisses() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let cache = HashCache(url: scratch.url)
        await cache.load()
        await cache.store(digest("a"), for: entry())

        #expect(await cache.digest(for: entry()) != nil)
        #expect(await cache.digest(for: entry(size: 1001)) == nil)
        #expect(await cache.digest(for: entry(inode: 43)) == nil)
        #expect(await cache.digest(for: entry(volume: 8)) == nil)
        #expect(await cache.digest(for: entry(mtime: 1_700_000_000_000_000_001)) == nil)
        // The generation is the interesting one: it advances even when the modification date is forced
        // backwards with utimes, which is exactly the `rsync -t` case an mtime-only key serves stale.
        #expect(await cache.digest(for: entry(generation: 6)) == nil)
    }

    @Test("A rewritten file with the same length and mtime still misses")
    func generationCatchesWhatMtimeCannot() async throws {
        // The scenario spelled out: same size, same modification date, different content. An mtime-keyed
        // cache would serve the old digest and the app would group two files that no longer match.
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let cache = HashCache(url: scratch.url)
        await cache.load()
        let before = entry(size: 100, mtime: 1_700_000_000_000_000_000, generation: 5)
        await cache.store(digest("a"), for: before)
        let after = entry(size: 100, mtime: 1_700_000_000_000_000_000, generation: 9)
        #expect(await cache.digest(for: after) == nil)
    }

    @Test("A later write for the same key wins")
    func lastWriterWins() async throws {
        // Appending is how an update is recorded, so the loader has to prefer the last row for a key.
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let first = HashCache(url: scratch.url)
        await first.load()
        await first.store(digest("a"), for: entry())
        _ = try await first.persist()

        // A second row for the same key, appended after the first.
        var bytes = try scratch.bytes()
        bytes += HashCacheFormat.encode(
            HashCacheRecord(key: HashCacheKey(entry: entry())!, digest: digest("b"))
        )
        try scratch.write(bytes)

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.digest(for: entry()) == digest("b"))
    }

    @Test("A torn final record is ignored and the rest survives")
    func toleratesTornTail() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let writer = HashCache(url: scratch.url)
        await writer.load()
        await writer.store(digest("a"), for: entry(path: "/x/1", inode: 1))
        await writer.store(digest("b"), for: entry(path: "/x/2", inode: 2))
        _ = try await writer.persist()

        // Simulate a crash halfway through appending a third row.
        var bytes = try scratch.bytes()
        bytes += Array(
            HashCacheFormat.encode(
                HashCacheRecord(key: HashCacheKey(entry: entry(inode: 3))!, digest: digest("c"))
            ).prefix(31))
        try scratch.write(bytes)

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.report.hadTornTail)
        #expect(await reader.report.recordsRead == 2)
        #expect(await reader.digest(for: entry(path: "/x/1", inode: 1)) == digest("a"))
        #expect(await reader.digest(for: entry(path: "/x/2", inode: 2)) == digest("b"))
        #expect(await reader.digest(for: entry(inode: 3)) == nil)
    }

    @Test("One corrupt record costs one row, not the file")
    func toleratesOneCorruptRecord() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let writer = HashCache(url: scratch.url)
        await writer.load()
        await writer.store(digest("a"), for: entry(inode: 1))
        await writer.store(digest("b"), for: entry(inode: 2))
        _ = try await writer.persist()

        var bytes = try scratch.bytes()
        // Flip a byte inside the first record's payload.
        bytes[HashCacheFormat.headerSize + 4] = bytes[HashCacheFormat.headerSize + 4] &+ 1
        try scratch.write(bytes)

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.report.corruptRecords == 1)
        #expect(await reader.report.recordsRead == 1)
        #expect(await reader.digest(for: entry(inode: 1)) == nil)
        #expect(await reader.digest(for: entry(inode: 2)) == digest("b"))
        #expect(!(await reader.report.isClean))
    }

    @Test("A file from another layout is discarded whole")
    func discardsForeignFile() async throws {
        // The rows may be perfectly intact and still mean something else -- a different chunking scheme,
        // say. Reading them would serve digests computed by code that no longer exists.
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        try scratch.write(Array("not a cache at all, but long enough to look like one....".utf8))

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.report.discardedFile)
        #expect(await reader.report.recordsRead == 0)
        #expect(await reader.digest(for: entry()) == nil)
    }

    @Test("A missing file is not an error")
    func missingFileIsFine() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let cache = HashCache(url: scratch.url)
        await cache.load()
        #expect(await cache.report.isClean)
        #expect(await cache.report.recordsRead == 0)
        #expect(await cache.digest(for: entry()) == nil)
    }

    @Test("A rewrite keeps the live rows and shrinks the file")
    func compactionKeepsLiveRows() async throws {
        // Ten digests under one key. **Production cannot reach this state** -- the key carries size, mtime and
        // generation, so changed content means a new key -- and the mechanism is still worth testing, because a
        // torn tail and a bad CRC reach the same rewrite by a route that is reachable.
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let cache = HashCache(url: scratch.url)
        await cache.load()
        for index in 0..<10 {
            await cache.store(digest(String(index)), for: entry())
            _ = try await cache.persist()
        }
        let before = try scratch.bytes().count

        #expect(try await cache.compact() == 1)
        let after = try scratch.bytes().count
        #expect(after < before)

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.digest(for: entry()) == digest("9"))
        #expect(await reader.report.recordsRead == 1)
    }

    @Test("A torn tail is what triggers a rewrite, and the rewrite drops it")
    func tornTailTriggersRewrite() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        // Each instance in its own scope, because the lock is held for the life of the object -- two live
        // instances over one file is exactly the case the lock exists to make read-only.
        var full = 0
        do {
            let cache = HashCache(url: scratch.url)
            await cache.load()
            for inode in UInt64(1)...4 {
                await cache.store(digest(String(inode)), for: entry(inode: inode))
            }
            _ = try await cache.persist()
            full = try scratch.bytes().count
        }

        // A crash mid-append leaves a partial record. Half a row, written by hand.
        var bytes = try scratch.bytes()
        bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: 40))
        try Data(bytes).write(to: scratch.url)

        do {
            let repaired = HashCache(url: scratch.url)
            await repaired.loadAndRepair()
            #expect(
                await repaired.report.hadTornTail == false, "the report still claims a torn tail")
            #expect(await repaired.report.recordsRead == 4)
            #expect(try scratch.bytes().count == full, "the partial row survived the rewrite")
        }

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.report.isClean)
        #expect(await reader.report.recordsRead == 4)
    }

    @Test("A row with a broken CRC triggers a rewrite that drops only that row")
    func corruptRowTriggersRewrite() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        do {
            let cache = HashCache(url: scratch.url)
            await cache.load()
            for inode in UInt64(1)...4 {
                await cache.store(digest(String(inode)), for: entry(inode: inode))
            }
            _ = try await cache.persist()
        }

        var bytes = try scratch.bytes()
        let rowStart = HashCacheFormat.headerSize + HashCacheFormat.recordSize
        bytes[rowStart + 48] ^= 0xFF
        try Data(bytes).write(to: scratch.url)

        do {
            let repaired = HashCache(url: scratch.url)
            await repaired.load()
            #expect(await repaired.report.corruptRecords == 1)
            #expect(await repaired.needsRewrite)
            _ = try await repaired.compact()
            #expect(await repaired.report.recordsRead == 3)
        }

        let reader = HashCache(url: scratch.url)
        await reader.load()
        #expect(await reader.report.isClean)
        #expect(await reader.report.recordsRead == 3, "the rewrite kept the broken row")
    }

    @Test("A file this build cannot read is left alone, not clobbered")
    func unknownFormatIsNotRewritten() async throws {
        // Wrong magic can mean a *newer* build wrote it. Rewriting would cost that build its cache to save us
        // nothing: the rows are ignored either way.
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let alien = Data([UInt8]("SOMETHINGELSE".utf8) + [UInt8](repeating: 7, count: 200))
        try alien.write(to: scratch.url)

        let cache = HashCache(url: scratch.url)
        await cache.loadAndRepair()
        #expect(await cache.report.discardedFile)
        #expect(!(await cache.needsRewrite))
        #expect(try Data(contentsOf: scratch.url) == alien, "an unknown format was overwritten")
    }

    @Test("Compaction is byte-reproducible")
    func compactionIsReproducible() async throws {
        // Rows are written in key order, so a byte-diff between two compactions of the same content is
        // meaningful -- which is what makes this assertion worth having at all.
        func compacted() async throws -> [UInt8] {
            let scratch = try CacheScratch()
            defer { scratch.remove() }
            let cache = HashCache(url: scratch.url)
            await cache.load()
            for inode in [UInt64(9), 3, 7, 1] {
                await cache.store(digest("a"), for: entry(inode: inode))
            }
            _ = try await cache.compact()
            return try scratch.bytes()
        }
        #expect(try await compacted() == (try await compacted()))
    }

    @Test("A second instance degrades to read-only instead of blocking")
    func secondInstanceIsReadOnly() async throws {
        // Two windows of the app, or the app beside a future CLI sharing this cache, must not deadlock
        // over derived data. A reader that cannot write still serves every hit it has.
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let first = HashCache(url: scratch.url)
        await first.load()
        await first.store(digest("a"), for: entry())
        _ = try await first.persist()

        let second = HashCache(url: scratch.url)
        await second.load()
        #expect(await second.report.isReadOnly)
        #expect(await second.digest(for: entry()) == digest("a"))
        // Its writes are dropped rather than corrupting the file.
        await second.store(digest("b"), for: entry(inode: 99))
        #expect(try await second.persist() == 0)
    }

    @Test("Counts hits and misses")
    func countsHitsAndMisses() async throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let cache = HashCache(url: scratch.url)
        await cache.load()
        await cache.store(digest("a"), for: entry())
        _ = await cache.digest(for: entry())
        _ = await cache.digest(for: entry(inode: 2))
        _ = await cache.digest(for: FileEntry(path: "/no-identity", size: 1))
        let stats = await cache.statistics
        #expect(stats.hits == 1)
        #expect(stats.misses == 2)
        #expect(stats.live == 1)
    }

    @Test("Verification re-reads the file instead of trusting the row")
    func verificationRereadsTheFile() async throws {
        // The safety valve, and the reason it is acceptable to trust the cache at all. A corrupt-but-CRC-
        // valid row, or an inode reused inside the same mtime nanosecond, would otherwise put two
        // non-identical files in one group and the user would trash a file that is not a duplicate.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let scratch = try CacheScratch()
        defer { scratch.remove() }

        let path = try tree.write("f.bin", bytes: ScratchTree.pattern(500))
        let hasher = ContentHasher()
        let real = try hasher.fullDigest(atPath: path)
        let walked = FileEntry(
            path: path,
            size: 500,
            identity: FileIdentity(volume: 1, inode: 1),
            generation: 1,
            modifiedNanoseconds: 1
        )

        let cache = HashCache(url: scratch.url)
        await cache.load()
        await cache.store(real.digest, for: walked)
        #expect(await cache.verify(walked, against: hasher))

        // Now poison the row, as a corrupt-but-CRC-valid entry would.
        await cache.store(digest("f"), for: walked)
        #expect(!(await cache.verify(walked, against: hasher)))

        // And a file that no longer exists cannot be verified.
        try FileManager.default.removeItem(atPath: path)
        #expect(!(await cache.verify(walked, against: hasher)))
    }

    @Test("The default location is under Caches, never the shared state directory")
    func defaultLocationIsCaches() {
        // Two different kinds of data. A scan document is an interop format the CLI reads and must never
        // lose; this is derived data macOS is allowed to purge, which is the semantics wanted.
        let url = HashCache.defaultURL(caches: URL(filePath: "/Users/tester/Library/Caches"))
        #expect(
            url.path(percentEncoded: false)
                == "/Users/tester/Library/Caches/com.rogalvil.duplicate/hashes.v1"
        )
        #expect(!url.path(percentEncoded: false).contains(".local/state"))
    }
}

@Suite("DuplicateFinder with a cache")
struct CachedScanTests {
    private let instant = ScanIdentifier.Instant(
        year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 685054
    )

    /// Counts full reads, so a warm scan can be shown to perform none.
    private final class ReadCountingHasher: FileHashing, @unchecked Sendable {
        private let real = ContentHasher()
        private let lock = NSLock()
        private(set) var fullCalls = 0
        func usesPrefixStage(forSize size: Int64) -> Bool { false }
        func prefixDigest(atPath path: String, size: Int64) throws -> Digest32 {
            try real.prefixDigest(atPath: path, size: size)
        }
        func fullDigest(atPath path: String) throws -> HashResult {
            lock.withLock { fullCalls += 1 }
            return try real.fullDigest(atPath: path)
        }
    }

    @Test("A warm scan reads nothing and produces the same document")
    func warmScanReadsNothing() async throws {
        // The whole point of the cache, as a measurement. The corpus this app was built for lives on an
        // external volume, where the read is the expensive part by a wide margin.
        let tree = try WalkFixture()
        defer { tree.remove() }
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        for index in 0..<6 { try tree.file("g\(index).bin", bytes: 700) }
        try tree.file("unique.bin", bytes: 123)

        let cache = HashCache(url: scratch.url)
        await cache.load()

        let cold = ReadCountingHasher()
        let first = try await DuplicateFinder(hasher: cold).find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2, cache: cache)
        )
        #expect(cold.fullCalls == 6)
        #expect(first.cacheHits == 0)
        #expect(first.scan.groups.count == 1)
        _ = try await cache.persist()

        let warm = ReadCountingHasher()
        let second = try await DuplicateFinder(hasher: warm).find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2, cache: cache)
        )
        #expect(warm.fullCalls == 0, "a warm scan read \(warm.fullCalls) files")
        #expect(second.cacheHits == 6)
        #expect(second.scan == first.scan, "the warm scan produced a different document")
    }

    @Test("A cache reloaded from disk warms a fresh scan")
    func reloadedCacheWarmsAScan() async throws {
        let tree = try WalkFixture()
        defer { tree.remove() }
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        for index in 0..<4 { try tree.file("g\(index).bin", bytes: 800) }

        let writer = HashCache(url: scratch.url)
        await writer.load()
        let cold = ReadCountingHasher()
        let first = try await DuplicateFinder(hasher: cold).find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2, cache: writer)
        )
        _ = try await writer.persist()
        #expect(cold.fullCalls == 4)

        // A different process would see exactly this: a fresh instance reading the file.
        let reader = HashCache(url: scratch.url)
        await reader.load()
        let warm = ReadCountingHasher()
        let second = try await DuplicateFinder(hasher: warm).find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2, cache: reader)
        )
        #expect(warm.fullCalls == 0)
        #expect(second.scan == first.scan)
    }

    @Test("Touching a file's content invalidates only that file")
    func touchingOneFileInvalidatesOnlyIt() async throws {
        let tree = try WalkFixture()
        defer { tree.remove() }
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        for index in 0..<4 { try tree.file("g\(index).bin", bytes: 600) }

        let cache = HashCache(url: scratch.url)
        await cache.load()
        _ = try await DuplicateFinder().find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2, cache: cache)
        )

        // Rewrite one file with different content of the same length.
        try Data(repeating: 200, count: 600).write(to: URL(filePath: tree.root + "/g0.bin"))

        let warm = ReadCountingHasher()
        let outcome = try await DuplicateFinder(hasher: warm).find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2, cache: cache)
        )
        #expect(warm.fullCalls == 1, "expected to re-read exactly the changed file")
        #expect(outcome.cacheHits == 3)
        // And the answer is right: three identical files, the fourth now different.
        #expect(outcome.scan.groups.count == 1)
        #expect(outcome.scan.groups[0].files.count == 3)
    }

    @Test("No cache means no behaviour change")
    func noCacheMeansNoChange() async throws {
        let tree = try WalkFixture()
        defer { tree.remove() }
        for index in 0..<4 { try tree.file("g\(index).bin", bytes: 500) }
        let outcome = try await DuplicateFinder().find(
            root: tree.root,
            instant: instant,
            configuration: .init(concurrency: 2)
        )
        #expect(outcome.cacheHits == 0)
        #expect(outcome.scan.groups.count == 1)
    }
}
