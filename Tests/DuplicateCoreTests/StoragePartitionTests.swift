import Foundation
import Testing

@testable import DuplicateCore

private func entry(
    _ path: String,
    inode: UInt64,
    content: Int64?,
    volume: UInt64 = 1,
    links: Int = 1
) -> FileEntry {
    FileEntry(
        path: path,
        size: 1000,
        identity: FileIdentity(volume: volume, inode: inode),
        contentIdentifier: content,
        linkCount: links
    )
}

@Suite("StoragePartition")
struct StoragePartitionTests {
    @Test("Independent copies each count as their own storage")
    func independentCopiesCountSeparately() {
        let partition = StoragePartition.of([
            entry("/a", inode: 1, content: 1),
            entry("/b", inode: 2, content: 2),
            entry("/c", inode: 3, content: 3),
        ])
        #expect(partition.distinctCopies == 3)
        #expect(!partition.hasSharedStorage)
        #expect(partition.isExact)
        #expect(partition.reclaimableBytes(size: 1000) == 2000)
    }

    @Test("Clones share storage, so only one copy exists")
    func clonesShareStorage() {
        // Measured on APFS: a file made with clonefile keeps its own inode and shares the source's
        // content identifier. Removing it frees nothing.
        let partition = StoragePartition.of([
            entry("/original", inode: 1, content: 100),
            entry("/clone", inode: 2, content: 100),
        ])
        #expect(partition.distinctCopies == 1)
        #expect(partition.hasSharedStorage)
        #expect(partition.reclaimableBytes(size: 1000) == 0)
    }

    @Test("Hardlinks share storage")
    func hardlinksShareStorage() {
        let partition = StoragePartition.of([
            entry("/a", inode: 1, content: 100, links: 2),
            entry("/b", inode: 1, content: 100, links: 2),
        ])
        #expect(partition.distinctCopies == 1)
        #expect(partition.reclaimableBytes(size: 1000) == 0)
    }

    @Test("A mix reports only the independent copies as reclaimable")
    func mixedGroupCountsClustersNotFiles() {
        // Four files, two of them clones of each other: three distinct copies, so two are reclaimable --
        // not three, which is what counting files would say.
        let partition = StoragePartition.of([
            entry("/a", inode: 1, content: 100),
            entry("/a-clone", inode: 2, content: 100),
            entry("/b", inode: 3, content: 200),
            entry("/c", inode: 4, content: 300),
        ])
        #expect(partition.distinctCopies == 3)
        #expect(partition.reclaimableBytes(size: 1000) == 2000)
    }

    @Test("Without a content identifier the figure is an upper bound")
    func withoutContentIdentifierIsNotExact() {
        // Off APFS. Hardlinks are still caught by inode, but clones become indistinguishable from
        // independent copies, so the count can only be too high -- never too low.
        let partition = StoragePartition.of([
            entry("/a", inode: 1, content: nil),
            entry("/b", inode: 2, content: nil),
        ])
        #expect(!partition.isExact)
        #expect(partition.distinctCopies == 2)

        let linked = StoragePartition.of([
            entry("/a", inode: 1, content: nil, links: 2),
            entry("/b", inode: 1, content: nil, links: 2),
        ])
        #expect(linked.distinctCopies == 1, "an inode still catches a hardlink without APFS")
        #expect(!linked.isExact)
    }

    @Test("A file with no identity at all counts as its own storage")
    func noIdentityCountsSeparately() {
        // The conservative direction: it can overstate what is reclaimable, never understate it, so the
        // app never promises space it cannot free.
        let partition = StoragePartition.of([
            FileEntry(path: "/a", size: 1000),
            FileEntry(path: "/b", size: 1000),
        ])
        #expect(partition.distinctCopies == 2)
        #expect(!partition.isExact)
    }

    @Test("The removal set is one file per cluster, never every other file")
    func removalSetIsOnePerCluster() {
        // The CLI hands files[1:] to its move and delete paths (src/rav/core/duplicates.py:140-144). On
        // this group that would move /a-clone -- a second name for the very storage being kept -- so the
        // keeper survives, nothing is freed, and a path the user may rely on is gone.
        let partition = StoragePartition.of([
            entry("/a", inode: 1, content: 100),
            entry("/a-clone", inode: 2, content: 100),
            entry("/b", inode: 3, content: 200),
        ])
        #expect(partition.removalCandidates(keeping: "/a") == ["/b"])
        #expect(partition.removalCandidates(keeping: "/a-clone") == ["/b"])
        #expect(partition.removalCandidates(keeping: "/b") == ["/a"])
    }

    @Test("Storage siblings are reported, not offered for removal")
    func reportsSiblings() {
        let partition = StoragePartition.of([
            entry("/a", inode: 1, content: 100),
            entry("/a-clone", inode: 2, content: 100),
            entry("/b", inode: 3, content: 200),
        ])
        #expect(partition.siblings(of: "/a") == ["/a-clone"])
        #expect(partition.siblings(of: "/b") == [])
        #expect(partition.siblings(of: "/not-here") == [])
    }

    @Test("Clusters and their members come back in byte order")
    func outputIsOrdered() {
        // So the partition can be serialised into a document without depending on hash-table iteration
        // order, and so two scans of the same tree produce the same bytes.
        let entries = [
            entry("/z", inode: 3, content: 300),
            entry("/a", inode: 1, content: 100),
            entry("/m", inode: 2, content: 100),
        ]
        let first = StoragePartition.of(entries)
        let second = StoragePartition.of(entries.reversed())
        #expect(first == second)
        #expect(first.clusters.map(\.first) == ["/a", "/z"])
        #expect(first.clusters[0] == ["/a", "/m"])
    }

    @Test("A single file has nothing to reclaim")
    func singleFileReclaimsNothing() {
        let partition = StoragePartition.of([entry("/only", inode: 1, content: 1)])
        #expect(partition.distinctCopies == 1)
        #expect(partition.reclaimableBytes(size: 5000) == 0)
    }
}

@Suite("Storage partition on real files")
struct RealStoragePartitionTests {
    /// Whether the scratch volume can clone, which is what makes the distinction observable.
    private func requireCloning(_ path: String) throws {
        let supports =
            (try? URL(filePath: path).resourceValues(forKeys: [.volumeSupportsFileCloningKey])
                .volumeSupportsFileCloning) ?? false
        try #require(
            supports, "this volume does not support cloning, so the distinction is untestable")
    }

    @Test("Tells a real clone from a really independent copy")
    func distinguishesRealCloneFromIndependentCopy() throws {
        // The assertion the whole design rests on, against the real syscalls.
        //
        // Note what an "independent copy" has to be: the bytes written afresh. `FileManager.copyItem` and
        // `cp` both go through clonefile on APFS, so a copy made the obvious way **is a clone** -- which
        // is why this matters at all, and which is what an earlier version of this test got wrong.
        let tree = try ScratchTree()
        defer { tree.remove() }
        try requireCloning(tree.root)

        let payload = ScratchTree.pattern(4096)
        let source = try tree.write("source.bin", bytes: payload)
        _ = try tree.write("independent.bin", bytes: payload)
        let clone = tree.root + "/clone.bin"
        let rc = source.withCString { s in clone.withCString { c in clonefile(s, c, 0) } }
        try #require(rc == 0, "clonefile failed with errno \(errno)")
        let copied = tree.root + "/copied.bin"
        try FileManager.default.copyItem(atPath: source, toPath: copied)
        let hardlink = tree.root + "/hardlink.bin"
        try FileManager.default.linkItem(atPath: source, toPath: hardlink)

        let walk = try FileManagerWalker().walk(
            root: tree.root,
            policy: ScanPolicy(),
            exclusions: .init()
        )
        #expect(walk.entries.count == 5)
        let partition = StoragePartition.of(walk.entries)
        #expect(partition.isExact, "the volume reported no content identifiers")

        // source, clone, copied and hardlink all share one storage; independent.bin has its own.
        #expect(partition.distinctCopies == 2, "clusters: \(partition.clusters)")
        #expect(partition.reclaimableBytes(size: 4096) == 4096)

        let cluster = try #require(
            partition.clusters.first { cluster in cluster.contains { $0.hasSuffix("/source.bin") } }
        )
        #expect(cluster.count == 4)
        #expect(cluster.contains { $0.hasSuffix("/clone.bin") })
        #expect(cluster.contains { $0.hasSuffix("/copied.bin") })
        #expect(cluster.contains { $0.hasSuffix("/hardlink.bin") })
        #expect(!cluster.contains { $0.hasSuffix("/independent.bin") })
    }

    @Test("A scan reports the honest figure, not the file count")
    func scanReportsHonestFigure() async throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        try requireCloning(tree.root)

        let payload = ScratchTree.pattern(2048)
        let source = try tree.write("a.bin", bytes: payload)
        _ = try tree.write("b.bin", bytes: payload)
        let clone = tree.root + "/a-clone.bin"
        try #require(source.withCString { s in clone.withCString { c in clonefile(s, c, 0) } } == 0)

        let outcome = try await DuplicateFinder().find(
            root: tree.root,
            instant: ScanIdentifier.Instant(
                year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 1
            ),
            configuration: .init(concurrency: 2)
        )
        let group = try #require(outcome.scan.groups.first)
        #expect(group.files.count == 3)
        // Counting files would claim two copies are recoverable. Two of the three share storage, so only
        // one is -- and claiming otherwise is a number `df` can falsify.
        #expect(group.redundantByteCountUpperBound == 4096)
        #expect(group.reclaimableBytes == 2048)
        #expect(group.hasSharedStorage)
        #expect(group.isReclaimExact)
        #expect(outcome.scan.reclaimableBytes == 2048)
        #expect(outcome.scan.groupsWithSharedStorage.count == 1)

        // And the removal set never contains a second name for the storage being kept.
        let keeper = try #require(group.files.first { $0.hasSuffix("/a.bin") })
        let removals = group.removalCandidates(keeping: keeper)
        #expect(removals.count == 1)
        #expect(removals[0].hasSuffix("/b.bin"))
        #expect(group.storageSiblings(of: keeper).count == 1)
    }

    @Test("A hardlink is never offered for removal alongside its keeper")
    func hardlinkIsNeverOfferedWithItsKeeper() async throws {
        // The concrete harm the CLI's files[1:] does: trash a second name for the kept inode, free
        // nothing, and lose a path the user may still rely on.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let source = try tree.write("keep.bin", bytes: ScratchTree.pattern(1500))
        try FileManager.default.linkItem(atPath: source, toPath: tree.root + "/second-name.bin")
        _ = try tree.write("real-duplicate.bin", bytes: ScratchTree.pattern(1500))

        let outcome = try await DuplicateFinder().find(
            root: tree.root,
            instant: ScanIdentifier.Instant(
                year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 2
            ),
            configuration: .init(concurrency: 1)
        )
        let group = try #require(outcome.scan.groups.first)
        #expect(group.files.count == 3)
        let removals = group.removalCandidates(keeping: source)
        #expect(removals.count == 1)
        #expect(removals[0].hasSuffix("/real-duplicate.bin"))
        #expect(!removals.contains { $0.hasSuffix("/second-name.bin") })
    }
}

@Suite("Storage partition through the document")
struct StoragePartitionCodecTests {
    private func fixtureData(_ name: String) throws -> Data {
        try Data(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Fixtures", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .notDirectory)
        )
    }

    @Test("A document without a partition still round-trips byte for byte")
    func cliDocumentStillRoundTrips() throws {
        // The property the interop selftests assert against 226 real files. Emitting the new key
        // unconditionally would break every one of them.
        for name in ["scan-empty.json", "scan-groups.json"] {
            let original = try fixtureData(name)
            let scan = try DuplicateScanCodec.decode(JSONReader.parse(original))
            #expect(scan.groups.allSatisfy { $0.storage == nil })
            #expect(try JSONWriter.document(DuplicateScanCodec.encode(scan)) == original)
        }
    }

    @Test("A partition survives a save and reload")
    func partitionRoundTrips() throws {
        let group = DuplicateGroup(
            size: 1000,
            digest: Digest32(hexString: String(repeating: "a", count: 64))!,
            files: ["/a", "/a-clone", "/b"],
            storage: StoragePartition(clusters: [["/a", "/a-clone"], ["/b"]], isExact: true)
        )
        let scan = DuplicateScan(
            scanID: "20260511-064716-000001",
            root: "/x",
            createdAt: "2026-05-11T06:47:16.000001Z",
            groups: [group]
        )
        let data = try JSONWriter.document(DuplicateScanCodec.encode(scan))
        let reloaded = try DuplicateScanCodec.decode(JSONReader.parse(data))
        #expect(reloaded == scan)
        #expect(reloaded.groups[0].reclaimableBytes == 1000)
        #expect(reloaded.groups[0].isReclaimExact)
        #expect(try JSONWriter.document(DuplicateScanCodec.encode(reloaded)) == data)
    }

    @Test("A malformed partition is treated as unknown, not as no sharing")
    func malformedPartitionIsUnknown() throws {
        // "Unknown" and "no sharing" are different answers, and acting on the wrong one would move files
        // the partition never described.
        let valid = String(repeating: "b", count: 64)
        func decode(_ storageJSON: String) throws -> DuplicateGroup {
            try DuplicateScanCodec.decode(
                group: JSONReader.parse(
                    """
                    {"size": 1, "sha256": "\(valid)", "files": ["/a", "/b"], "rav_app": \(storageJSON)}
                    """
                ),
                at: 0
            )
        }
        // Cluster members do not cover the group's files.
        #expect(try decode(#"{"storage_clusters": [["/a"]]}"#).storage == nil)
        // Not an array of arrays.
        #expect(try decode(#"{"storage_clusters": ["/a"]}"#).storage == nil)
        // An empty cluster.
        #expect(try decode(#"{"storage_clusters": [[], ["/a", "/b"]]}"#).storage == nil)
        // No key at all.
        #expect(try decode(#"{"other": 1}"#).storage == nil)
        // Valid, but without the exactness flag: assumed inexact rather than exact.
        let inexact = try decode(#"{"storage_clusters": [["/a"], ["/b"]]}"#)
        #expect(inexact.storage != nil)
        #expect(inexact.isReclaimExact == false)
    }

    @Test("An unknown partition falls back to the upper bound")
    func unknownPartitionFallsBackToUpperBound() {
        // Which is what every CLI-written document does, and the UI has to label it as a bound.
        let group = DuplicateGroup(
            size: 500,
            digest: Digest32(hexString: String(repeating: "c", count: 64))!,
            files: ["/a", "/b", "/c"]
        )
        #expect(group.reclaimableBytes == 1000)
        #expect(!group.isReclaimExact)
        #expect(!group.hasSharedStorage)
        // With no partition, every other file is a removal candidate -- the CLI's behaviour, which is the
        // only honest thing to do when the sharing is unknown.
        #expect(group.removalCandidates(keeping: "/a") == ["/b", "/c"])
    }
}
