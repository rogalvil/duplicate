import Foundation
import Testing

@testable import DuplicateCore

private func key(_ inode: UInt64, size: Int64 = 100, generation: UInt64 = 7) -> HashCacheKey {
    HashCacheKey(
        volume: 1, inode: inode, size: size, mtimeNanoseconds: 1_000, generation: generation)
}

private func hashes(_ values: [UInt64]) -> [PerceptualHash] {
    values.map(PerceptualHash.init(bits:))
}

@Suite("PerceptualCacheFormat")
struct PerceptualCacheFormatTests {

    @Test("A row round-trips, image and video")
    func roundTripsBothKinds() throws {
        for entry in [
            PerceptualCacheEntry(kind: .image, hashes: hashes([0x8000_0000_0000_0000])),
            PerceptualCacheEntry(kind: .video, hashes: hashes([1, 2, 3, 4, 5, 6, 7, 8])),
        ] {
            let bytes = PerceptualCacheFormat.encode(key: key(42), entry: entry)
            #expect(bytes.count == PerceptualCacheFormat.recordSize)
            let decoded = try #require(PerceptualCacheFormat.decode(bytes))
            #expect(decoded.key == key(42))
            #expect(decoded.entry == entry)
        }
    }

    @Test("The row size is a multiple of eight")
    func staysWordAligned() {
        #expect(PerceptualCacheFormat.recordSize % 8 == 0)
        #expect(PerceptualCacheFormat.headerSize % 8 == 0)
    }

    /// **The property the whole corruption story rests on**: a flipped byte is caught, and only that row.
    @Test("A flipped byte fails the CRC")
    func detectsCorruption() {
        var bytes = PerceptualCacheFormat.encode(
            key: key(42), entry: PerceptualCacheEntry(kind: .video, hashes: hashes([9, 10])))
        bytes[50] ^= 0x01
        #expect(PerceptualCacheFormat.decode(bytes) == nil)
    }

    @Test("A row claiming no frames is treated as corrupt")
    func refusesEmptyRows() {
        var bytes = PerceptualCacheFormat.encode(
            key: key(1), entry: PerceptualCacheEntry(kind: .image, hashes: hashes([5])))
        bytes[41] = 0
        // The CRC now fails too, which is the point: there is no way to write a valid empty row.
        #expect(PerceptualCacheFormat.decode(bytes) == nil)
    }

    /// **The salt is derived from the parameters, so forgetting to bump a constant cannot serve stale numbers.**
    @Test("Changing a pipeline parameter changes the salt")
    func saltFollowsTheConfiguration() {
        let base = PerceptualCacheFormat.salt(
            imageConfiguration: ImageHasher.Configuration(),
            videoConfiguration: VideoHasher.Configuration())
        let biggerDecode = PerceptualCacheFormat.salt(
            imageConfiguration: ImageHasher.Configuration(decodeMaxPixelSize: 512),
            videoConfiguration: VideoHasher.Configuration())
        let moreFrames = PerceptualCacheFormat.salt(
            imageConfiguration: ImageHasher.Configuration(),
            videoConfiguration: VideoHasher.Configuration(frameCount: 16))
        let looserSeek = PerceptualCacheFormat.salt(
            imageConfiguration: ImageHasher.Configuration(),
            videoConfiguration: VideoHasher.Configuration(toleranceSeconds: 2))
        #expect(base != biggerDecode)
        #expect(base != moreFrames)
        #expect(base != looserSeek)
        // And it is stable for the same parameters, or every scan would rebuild the file.
        #expect(
            base
                == PerceptualCacheFormat.salt(
                    imageConfiguration: ImageHasher.Configuration(),
                    videoConfiguration: VideoHasher.Configuration()))
    }

    @Test("A header with another salt is refused")
    func refusesForeignHeaders() {
        let bytes = PerceptualCacheFormat.encodeHeader(salt: 111)
        #expect(PerceptualCacheFormat.decodeHeader(bytes, salt: 111))
        #expect(PerceptualCacheFormat.decodeHeader(bytes, salt: 222) == false)
    }
}

@Suite("PerceptualCache")
struct PerceptualCacheTests {

    private func scratch() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory() + "/duplicate-pcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "phashes.v1")
    }

    private func entry(_ path: String, inode: UInt64, size: Int64 = 100) -> FileEntry {
        FileEntry(
            path: path, size: size,
            identity: FileIdentity(volume: 1, inode: inode),
            generation: 7, modifiedNanoseconds: 1_000
        )
    }

    @Test("A stored entry survives a reload")
    func persistsAndReloads() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let writer = PerceptualCache(url: url)
        await writer.load()
        await writer.store(hashes([0x1234]), for: entry("/a.jpg", inode: 1), kind: .image)
        await writer.store(hashes([1, 2, 3, 4]), for: entry("/b.mp4", inode: 2), kind: .video)
        #expect(try await writer.persist() == 2)

        let reader = PerceptualCache(url: url)
        await reader.load()
        #expect(await reader.report.recordsRead == 2)
        #expect(
            await reader.hashes(for: entry("/a.jpg", inode: 1), kind: .image) == hashes([0x1234]))
        #expect(
            await reader.hashes(for: entry("/b.mp4", inode: 2), kind: .video)
                == hashes([1, 2, 3, 4]))
    }

    /// A file whose size or generation moved is a different file to the cache.
    @Test("A changed file misses")
    func invalidatesOnChange() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = PerceptualCache(url: url)
        await cache.load()
        await cache.store(hashes([7]), for: entry("/a.jpg", inode: 1), kind: .image)

        #expect(await cache.hashes(for: entry("/a.jpg", inode: 1, size: 200), kind: .image) == nil)
        var moved = entry("/a.jpg", inode: 1)
        moved = FileEntry(
            path: moved.path, size: moved.size, identity: moved.identity,
            generation: 8, modifiedNanoseconds: moved.modifiedNanoseconds)
        #expect(await cache.hashes(for: moved, kind: .image) == nil)
    }

    /// **The kind is checked, not assumed.** An inode reused by a file of the other kind would otherwise be
    /// served eight frames as if it were one image.
    @Test("An entry of the other kind does not answer")
    func separatesKinds() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = PerceptualCache(url: url)
        await cache.load()
        await cache.store(hashes([1, 2, 3]), for: entry("/a.mp4", inode: 1), kind: .video)
        #expect(await cache.hashes(for: entry("/a.mp4", inode: 1), kind: .image) == nil)
        #expect(await cache.hashes(for: entry("/a.mp4", inode: 1), kind: .video)?.count == 3)
    }

    /// A file with no inode cannot be recognised again, and inventing a key from its path would serve a stale
    /// hash after a rename.
    @Test("A file with no identity is not cached")
    func refusesFilesWithoutIdentity() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = PerceptualCache(url: url)
        await cache.load()
        let anonymous = FileEntry(
            path: "/a.jpg", size: 100, identity: nil, generation: 7, modifiedNanoseconds: 1_000)
        await cache.store(hashes([1]), for: anonymous, kind: .image)
        #expect(await cache.count == 0)
        #expect(try await cache.persist() == 0)
    }

    @Test("A warm store writes nothing")
    func skipsUnchangedRows() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = PerceptualCache(url: url)
        await cache.load()
        await cache.store(hashes([5]), for: entry("/a.jpg", inode: 1), kind: .image)
        #expect(try await cache.persist() == 1)
        // The same value again is not a new row.
        await cache.store(hashes([5]), for: entry("/a.jpg", inode: 1), kind: .image)
        #expect(try await cache.persist() == 0)
    }

    /// A crash mid-append leaves a partial row. Everything before it has to survive.
    @Test("A torn tail costs its own row and nothing else")
    func survivesATornTail() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = PerceptualCache(url: url)
        await writer.load()
        for index in 1...3 {
            await writer.store(
                hashes([UInt64(index)]), for: entry("/\(index).jpg", inode: UInt64(index)),
                kind: .image)
        }
        _ = try await writer.persist()

        var data = try Data(contentsOf: url)
        data.removeLast(20)
        try data.write(to: url)

        let reader = PerceptualCache(url: url)
        await reader.load()
        #expect(await reader.report.hadTornTail)
        #expect(await reader.report.recordsRead == 2)
    }

    /// **A pipeline change discards the file rather than serving numbers that mean something else.**
    @Test("A cache written by another pipeline is discarded whole")
    func discardsForeignPipelines() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = PerceptualCache(url: url)
        await writer.load()
        await writer.store(hashes([9]), for: entry("/a.jpg", inode: 1), kind: .image)
        _ = try await writer.persist()

        let other = PerceptualCache(
            url: url, imageConfiguration: ImageHasher.Configuration(decodeMaxPixelSize: 512))
        await other.load()
        #expect(await other.report.discardedFile)
        #expect(await other.count == 0)
        #expect(await other.hashes(for: entry("/a.jpg", inode: 1), kind: .image) == nil)

        // And it can then write its own file over the old one, rather than appending under a stale header.
        await other.store(hashes([11]), for: entry("/a.jpg", inode: 1), kind: .image)
        _ = try await other.persist()
        let reread = PerceptualCache(
            url: url, imageConfiguration: ImageHasher.Configuration(decodeMaxPixelSize: 512))
        await reread.load()
        #expect(await reread.hashes(for: entry("/a.jpg", inode: 1), kind: .image) == hashes([11]))
    }

    @Test("A missing file is an empty cache, not an error")
    func toleratesAMissingFile() async throws {
        let cache = PerceptualCache(
            url: URL(filePath: NSTemporaryDirectory() + "/nope-\(UUID().uuidString)/phashes.v1"))
        await cache.load()
        #expect(await cache.count == 0)
        #expect(await cache.report == PerceptualCache.LoadReport())
    }
}
