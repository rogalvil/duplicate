import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private struct CacheScratch {
    let directory: URL
    let cache: PresenceCache

    init() throws {
        directory = URL(
            filePath: NSTemporaryDirectory() + "/duplicate-presence-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = PresenceCache(directory: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func scan(_ sizes: [Int64], scanID: String = "20260812-120000-000000") -> DuplicateScan {
    DuplicateScan(
        scanID: scanID,
        root: "/r",
        createdAt: "2026-08-12T12:00:00.000000Z",
        groups: sizes.enumerated().map { index, size in
            DuplicateGroup(
                size: size, digest: digest(String(index)),
                files: ["/r/\(index)/a", "/r/\(index)/b"]
            )
        }
    )
}

private let noon = "2026-08-12T12:00:00.000000Z"

@Suite("PresenceCache")
struct PresenceCacheTests {

    @Test("Nothing cached reads as nil")
    func startsEmpty() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        #expect(scratch.cache.load(scanID: "20260812-120000-000000") == nil)
    }

    @Test("A snapshot round-trips")
    func roundTrips() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let subject = scan([100, 200])
        let snapshot = PresenceSnapshot(
            stillDuplicateByKey: [
                subject.groups[0].key: true, subject.groups[1].key: false,
            ],
            checkedAt: noon
        )
        try scratch.cache.save(snapshot, scanID: subject.scanID)

        let loaded = try #require(scratch.cache.load(scanID: subject.scanID))
        #expect(loaded == snapshot)
        #expect(loaded.checkedAt == noon)
        #expect(loaded.checkedCount == 2)
        #expect(loaded.stillDuplicateCount == 1)
        #expect(loaded.stillDuplicate(for: subject) == [0: true, 1: false])
    }

    /// **Keyed on the group key, not the index.** An index only means something for one exact document; a
    /// group key survives a rescan of the same content, and the whole point of caching this is to still be
    /// useful later.
    @Test("A reordered scan still matches by group key")
    func survivesReordering() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let original = scan([100, 200])
        try scratch.cache.save(
            PresenceSnapshot(
                stillDuplicateByKey: [original.groups[0].key: true, original.groups[1].key: false],
                checkedAt: noon
            ),
            scanID: original.scanID
        )

        // The same two groups, the other way round -- what a rescan can produce.
        let reordered = DuplicateScan(
            scanID: original.scanID, root: original.root, createdAt: original.createdAt,
            groups: [original.groups[1], original.groups[0]]
        )
        let loaded = try #require(scratch.cache.load(scanID: original.scanID))
        #expect(loaded.stillDuplicate(for: reordered) == [0: false, 1: true])
    }

    /// A group the check never reached stays absent, because ``GroupFilter`` reads a missing entry as still a
    /// duplicate -- not yet checked is not the same as gone.
    @Test("A group the snapshot does not mention is absent, not false")
    func leavesUnknownGroupsOut() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let subject = scan([100, 200, 300])
        try scratch.cache.save(
            PresenceSnapshot(
                stillDuplicateByKey: [subject.groups[0].key: false], checkedAt: noon),
            scanID: subject.scanID
        )

        let loaded = try #require(scratch.cache.load(scanID: subject.scanID))
        let map = loaded.stillDuplicate(for: subject)
        #expect(map == [0: false])
        #expect(map[1] == nil)
        #expect(map[2] == nil)
    }

    /// A corrupt cache must not stop a review from opening. One more disk check is the whole cost.
    @Test("A corrupt file reads as nil")
    func toleratesCorruption() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        try Data("{ not json at all".utf8).write(
            to: scratch.directory.appending(path: "20260812-120000-000000.json"))
        #expect(scratch.cache.load(scanID: "20260812-120000-000000") == nil)
    }

    @Test("An empty snapshot reads as nil rather than as an answer")
    func rejectsAnEmptySnapshot() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        try scratch.cache.save(
            PresenceSnapshot(stillDuplicateByKey: [:], checkedAt: noon),
            scanID: "20260812-120000-000000"
        )
        // Nothing was checked, so there is nothing to trust -- and reporting "checked, all gone" would be
        // the worst possible reading of an empty file.
        #expect(scratch.cache.load(scanID: "20260812-120000-000000") == nil)
    }

    /// A scan id is interpolated into a path, so anything that is not one is refused before it becomes an
    /// `open`.
    @Test("A traversal identifier is refused")
    func refusesBadIdentifiers() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        #expect(throws: PresenceCacheError.invalidScanIdentifier("../../etc/passwd")) {
            try scratch.cache.save(
                PresenceSnapshot(stillDuplicateByKey: ["a": true], checkedAt: noon),
                scanID: "../../etc/passwd"
            )
        }
        #expect(scratch.cache.load(scanID: "../../etc/passwd") == nil)
    }

    @Test("Forgetting removes the file")
    func forgets() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let subject = scan([100])
        try scratch.cache.save(
            PresenceSnapshot(stillDuplicateByKey: [subject.groups[0].key: true], checkedAt: noon),
            scanID: subject.scanID
        )
        #expect(scratch.cache.forget(scanID: subject.scanID))
        #expect(scratch.cache.load(scanID: subject.scanID) == nil)
        // Forgetting twice is not an error.
        #expect(scratch.cache.forget(scanID: subject.scanID) == false)
    }

    /// Two identical checks have to produce identical bytes, or a diff of the cache means nothing.
    @Test("The file is reproducible")
    func writesReproducibly() throws {
        let scratch = try CacheScratch()
        defer { scratch.remove() }
        let subject = scan([100, 200, 300])
        let snapshot = PresenceSnapshot(
            stillDuplicateByKey: Dictionary(
                uniqueKeysWithValues: subject.groups.map { ($0.key, true) }),
            checkedAt: noon
        )
        let path = try scratch.cache.save(snapshot, scanID: subject.scanID)
        let first = try #require(FileManager.default.contents(atPath: path))
        try scratch.cache.save(snapshot, scanID: subject.scanID)
        let second = try #require(FileManager.default.contents(atPath: path))
        #expect(first == second)
        #expect(String(decoding: first, as: UTF8.self).contains("\"format_version\": 1"))
    }

    /// Derived data that macOS may purge, never the shared state directory the CLI reads.
    @Test("The default directory is under Caches")
    func defaultsToCaches() {
        let url = PresenceCache.defaultDirectory(environment: [:], home: "/Users/tester")
        #expect(
            url.path(percentEncoded: false)
                == "/Users/tester/Library/Caches/com.rogalvil.duplicate/presence"
        )
    }
}
