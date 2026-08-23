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
        // Each instance in its own scope. Two live instances over one file is a lock loser, not another
        // pipeline: a real second pipeline is a different build in a different process, holding its own lock.
        do {
            let writer = PerceptualCache(url: url)
            await writer.load()
            await writer.store(hashes([9]), for: entry("/a.jpg", inode: 1), kind: .image)
            _ = try await writer.persist()
        }

        do {
            let other = PerceptualCache(
                url: url, imageConfiguration: ImageHasher.Configuration(decodeMaxPixelSize: 512))
            await other.load()
            #expect(await other.report.discardedFile)
            #expect(await other.count == 0)
            #expect(await other.hashes(for: entry("/a.jpg", inode: 1), kind: .image) == nil)

            // And it can then write its own file over the old one, rather than appending under a stale header.
            await other.store(hashes([11]), for: entry("/a.jpg", inode: 1), kind: .image)
            _ = try await other.persist()
        }

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

    @Test("A torn tail triggers a rewrite that drops it and keeps the rest")
    func tornTailIsRepaired() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // Each instance in its own scope: the lock lives as long as the object, so two live instances over one
        // file is the case the lock exists to make read-only.
        var full = 0
        do {
            let writer = PerceptualCache(url: url)
            await writer.load()
            for inode in UInt64(1)...4 {
                await writer.store(
                    hashes([UInt64(inode)]), for: entry("/\(inode).jpg", inode: inode), kind: .image
                )
            }
            _ = try await writer.persist()
            full = try Data(contentsOf: url).count
        }

        var bytes = try Data(contentsOf: url)
        bytes.append(Data(repeating: 0xAB, count: 50))
        try bytes.write(to: url)

        do {
            let repaired = PerceptualCache(url: url)
            await repaired.loadAndRepair()
            #expect(await repaired.count == 4)
            #expect(await repaired.report.hadTornTail == false)
            #expect(try Data(contentsOf: url).count == full, "the partial row survived")
        }

        let reader = PerceptualCache(url: url)
        await reader.load()
        #expect(await reader.report.recordsRead == 4)
        #expect(await reader.report.hadTornTail == false)
    }

    @Test("A second instance is read-only and appends nothing")
    func lockDegradesToReadOnly() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let holder = PerceptualCache(url: url)
        await holder.load()
        await holder.store(hashes([0x99]), for: entry("/a.jpg", inode: 1), kind: .image)
        _ = try await holder.persist()
        let sizeBefore = try Data(contentsOf: url).count

        // Two windows scanning at once. The loser must serve every hit it has and write nothing: two writers
        // appending 112-byte rows to one file interleave them, and a CRC can say a row is broken without being
        // able to say which two writers made it.
        let loser = PerceptualCache(url: url)
        await loser.load()
        #expect(await loser.report.isReadOnly)
        #expect(await loser.hashes(for: entry("/a.jpg", inode: 1), kind: .image) == hashes([0x99]))
        await loser.store(hashes([0x11]), for: entry("/b.jpg", inode: 2), kind: .image)
        #expect(try await loser.persist() == 0)
        #expect(try Data(contentsOf: url).count == sizeBefore, "a read-only instance wrote")
        #expect(!(await loser.needsRewrite), "a read-only instance offered to rewrite the file")
    }

    @Test("A salt that no longer matches is not a rewrite trigger")
    func saltMismatchIsNotARewrite() async throws {
        // The pipeline changed, so every number in the file means something else -- but a different build can
        // still use it, and `persist` already rewrites the whole file under the new header when it writes.
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let writer = PerceptualCache(url: url)
            await writer.load()
            await writer.store(hashes([0x1]), for: entry("/a.jpg", inode: 1), kind: .image)
            _ = try await writer.persist()
        }
        let original = try Data(contentsOf: url)

        let other = PerceptualCache(
            url: url,
            imageConfiguration: ImageHasher.Configuration(decodeMaxPixelSize: 512)
        )
        await other.loadAndRepair()
        #expect(await other.report.discardedFile)
        #expect(!(await other.needsRewrite))
        #expect(
            try Data(contentsOf: url) == original, "a file another build can read was overwritten")
    }

    /// **Measured at zero waste on the real file and built for the bound anyway.** All 3,396 rows of this user's
    /// perceptual cache describe files that still exist: a photo library churns far slower than the temporary
    /// trees that had made the digest cache 55.8% dead weight. What stays true is that the file grows a row per
    /// `(file, version)` seen and reclaims none.
    @Test("A row whose file was deleted is dropped, and a live one is kept")
    func prunesDeadRows() async throws {
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let tree = url.deletingLastPathComponent().path + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)

        let survivor = tree + "/keep.jpg"
        let doomed = tree + "/go.jpg"
        try Data("a picture".utf8).write(to: URL(filePath: survivor))
        try Data("another".utf8).write(to: URL(filePath: doomed))
        let walk = try FileManagerWalker().walk(
            root: tree, policy: ScanPolicy(), exclusions: ExclusionSet())
        let survivorEntry = try #require(walk.entries.first { $0.path.hasSuffix("keep.jpg") })
        let doomedEntry = try #require(walk.entries.first { $0.path.hasSuffix("go.jpg") })

        do {
            let cache = PerceptualCache(url: url, pruneFloor: 1)
            await cache.load()
            await cache.store(hashes([0x11]), for: survivorEntry, kind: .image)
            await cache.store(hashes([0x22]), for: doomedEntry, kind: .image)
            _ = try await cache.persist()
        }
        try FileManager.default.removeItem(atPath: doomed)

        // Through `loadAndRepair`, which is what the scan session calls.
        do {
            let cache = PerceptualCache(url: url, pruneFloor: 1)
            await cache.loadAndRepair()
            let kept = await cache.count
            #expect(kept == 1, "the prune kept \(kept) rows")
            #expect(
                await cache.hashes(for: survivorEntry, kind: .image) == hashes([0x11]),
                "the live row was dropped")
        }

        let reader = PerceptualCache(url: url, pruneFloor: 1)
        await reader.load()
        #expect(await reader.report.recordsRead == 1)
        #expect(await reader.hashes(for: survivorEntry, kind: .image) == hashes([0x11]))
        // And the marker stops the next load from paying for the lookups again.
        #expect(!(await reader.needsPruning), "the prune marker did not survive the rewrite")
    }

    @Test("A row on a volume that is not mounted is never dropped")
    func keepsRowsFromUnmountedVolumes() async throws {
        // The hazard that makes the naive rule wrong: this user's corpus lives on an external disk, and a
        // perceptual scan of it costs 177 seconds to rebuild.
        let url = try scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ghost = FileEntry(
            path: "/Volumes/NotMounted/clip.mp4",
            size: 4096,
            identity: FileIdentity(volume: 0xFEED_FACE_FEED_FACE, inode: 424_242),
            generation: 3,
            modifiedNanoseconds: 1_700_000_000_000_000_000
        )
        do {
            let cache = PerceptualCache(url: url, pruneFloor: 1)
            await cache.load()
            await cache.store(hashes([1, 2, 3, 4]), for: ghost, kind: .video)
            _ = try await cache.persist()
        }

        let cache = PerceptualCache(url: url, pruneFloor: 1)
        await cache.load()
        #expect(try await cache.prune() == 0, "a row on an unmounted volume was dropped")
        #expect(await cache.hashes(for: ghost, kind: .video) == hashes([1, 2, 3, 4]))
    }
}
