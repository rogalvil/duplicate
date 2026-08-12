import Testing

@testable import DuplicateCore

@Suite("SizeBuckets")
struct SizeBucketsTests {
    private func entry(_ path: String, _ size: Int64) -> FileEntry {
        FileEntry(path: path, size: size)
    }

    @Test("A bucket of one is never hashed")
    func singletonBucketsAreDropped() {
        // Most of the reason a scan is fast at all. If singletons reached the hasher, a scan of a photo
        // library would read every byte on the disk instead of a small fraction of it.
        let entries = [entry("/a", 10), entry("/b", 20), entry("/c", 30)]
        #expect(SizeBuckets.candidates(in: entries).isEmpty)
        #expect(SizeBuckets.candidateCount(in: entries) == 0)
    }

    @Test("Groups files that share a size")
    func groupsBySize() {
        let entries = [
            entry("/a", 10), entry("/b", 20), entry("/c", 10), entry("/d", 20), entry("/e", 30),
        ]
        let runs = SizeBuckets.candidates(in: entries)
        #expect(runs.count == 2)
        #expect(runs.map { $0.count } == [2, 2])
        #expect(SizeBuckets.candidateCount(in: entries) == 4)
    }

    @Test("Largest sizes come first")
    func largestFirst() {
        // A scan cancelled halfway has then already covered the groups that matter most: recovering a
        // gigabyte beats recovering a kilobyte, and the user who stops the scan still gets the useful
        // half.
        let entries = [
            entry("/small1", 10), entry("/small2", 10),
            entry("/big1", 1_000_000), entry("/big2", 1_000_000),
            entry("/mid1", 5000), entry("/mid2", 5000),
        ]
        #expect(SizeBuckets.candidates(in: entries).map { $0[0].size } == [1_000_000, 5000, 10])
    }

    @Test("Within a bucket, paths are in byte order")
    func bytewiseOrderWithinBucket() {
        // Handed to the grouping stage so it never has to sort again -- and so the order cannot depend
        // on which task finished first.
        let entries = [
            entry("/x/b.txt", 10), entry("/x/A.txt", 10), entry("/x/a.txt", 10),
        ]
        let bucket = SizeBuckets.candidates(in: entries)[0]
        #expect(bucket.map(\.path) == ["/x/A.txt", "/x/a.txt", "/x/b.txt"])
    }

    @Test("Orders the two Unicode forms the way Python does")
    func ordersUnicodeFormsLikePython() {
        // NFD puts a plain 'a' where NFC puts U+00E1, and 0x61 < 0xC3, so the decomposed form comes
        // first. Swift's String < would disagree, and the scan file would then list a group's files in
        // a different order than the CLI does.
        let decomposed = "/x/Sua\u{0301}rez"
        let precomposed = "/x/Su\u{00E1}rez"
        let bucket = SizeBuckets.candidates(
            in: [entry(precomposed, 10), entry(decomposed, 10)]
        )[0]
        #expect(bucket.map(\.path) == [decomposed, precomposed])
    }

    @Test("Excludes files below the minimum size")
    func honoursMinimumSize() {
        // The CLI defaults to 1, which excludes zero-byte files. A real disk has hundreds of them, all
        // trivially identical, and not one is worth a decision.
        let entries = [entry("/a", 0), entry("/b", 0), entry("/c", 5), entry("/d", 5)]
        #expect(SizeBuckets.candidates(in: entries).count == 1)
        #expect(SizeBuckets.candidates(in: entries)[0].map(\.size) == [5, 5])

        // Explicitly asking for zero includes them.
        #expect(SizeBuckets.candidates(in: entries, minimumSize: 0).count == 2)

        // A larger threshold drops the small bucket entirely.
        #expect(SizeBuckets.candidates(in: entries, minimumSize: 6).isEmpty)
    }

    @Test("Handles an empty input")
    func handlesEmptyInput() {
        #expect(SizeBuckets.candidates(in: []).isEmpty)
        #expect(SizeBuckets.candidateCount(in: []) == 0)
    }

    @Test("Handles a bucket with many members")
    func handlesLargeBucket() {
        // The .DS_Store shape: one size, hundreds of files. The run scan must not be quadratic and must
        // not lose anyone.
        let entries = (0..<500).map { entry("/x/\($0)", 4096) }
        let runs = SizeBuckets.candidates(in: entries)
        #expect(runs.count == 1)
        #expect(runs[0].count == 500)
    }
}

@Suite("GroupBuilder")
struct GroupBuilderTests {
    private func digest(_ seed: String) -> Digest32 {
        Digest32(hexString: String(repeating: seed, count: 64))!
    }

    private func hashed(
        _ path: String, _ size: Int64, _ seed: String
    ) -> (
        entry: FileEntry, digest: Digest32
    ) {
        (FileEntry(path: path, size: size), digest(seed))
    }

    @Test("Emits only groups with more than one member")
    func dropsUniqueDigests() {
        let input = [
            hashed("/a", 10, "1"), hashed("/b", 10, "2"), hashed("/c", 10, "1"),
        ]
        let groups = GroupBuilder.groups(from: input)
        #expect(groups.count == 1)
        #expect(groups[0].files == ["/a", "/c"])
    }

    @Test("Orders groups by descending size, then ascending digest")
    func ordersGroups() {
        // The CLI's key=(-size, digest) (src/rav/core/duplicates.py:94). Comparing Digest32 values
        // gives the same order as comparing their hex strings, so 20,000 groups sort without
        // allocating a single string.
        let input = [
            hashed("/s1", 10, "f"), hashed("/s2", 10, "f"),
            hashed("/b1", 900, "b"), hashed("/b2", 900, "b"),
            hashed("/b3", 900, "a"), hashed("/b4", 900, "a"),
        ]
        let groups = GroupBuilder.groups(from: input)
        #expect(groups.map(\.size) == [900, 900, 10])
        #expect(groups[0].digest < groups[1].digest)
        #expect(groups[0].files == ["/b3", "/b4"])
    }

    @Test("Orders files within a group by byte, whatever order they arrived in")
    func ordersFilesWithinGroup() {
        // Concurrent hashing finishes in an arbitrary order. The document must not show it.
        let input = [
            hashed("/x/b.txt", 10, "1"),
            hashed("/x/A.txt", 10, "1"),
            hashed("/x/a.txt", 10, "1"),
            hashed("/x/a/b.txt", 10, "1"),
        ]
        #expect(
            GroupBuilder.groups(from: input)[0].files
                == ["/x/A.txt", "/x/a.txt", "/x/a/b.txt", "/x/b.txt"]
        )
    }

    @Test("Reversing the input does not change the output")
    func outputIsIndependentOfInputOrder() {
        // The property that matters for reproducibility: two runs that hash in different orders must
        // produce byte-identical documents.
        let input = [
            hashed("/a", 10, "1"), hashed("/b", 10, "1"),
            hashed("/c", 20, "2"), hashed("/d", 20, "2"),
        ]
        #expect(GroupBuilder.groups(from: input) == GroupBuilder.groups(from: input.reversed()))
    }

    @Test("Does not merge equal digests of different sizes")
    func keepsSizesApart() {
        // Cannot happen with real SHA-256, but grouping on digest alone would be wrong on principle,
        // and the group's size field would then be a guess.
        let input = [
            hashed("/a", 10, "1"), hashed("/b", 10, "1"),
            hashed("/c", 20, "1"), hashed("/d", 20, "1"),
        ]
        let groups = GroupBuilder.groups(from: input)
        #expect(groups.count == 2)
        #expect(groups.map(\.size) == [20, 10])
    }

    @Test("Assembles a scan whose identifier and timestamp agree")
    func assemblesScan() {
        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 685054
        )
        let scan = GroupBuilder.scan(root: "/x", instant: instant, groups: [])
        #expect(scan.scanID == "20260511-064716-685054")
        #expect(scan.createdAt == "2026-05-11T06:47:16.685054Z")
        #expect(scan.createdAtInstant?.timestamp == scan.createdAt)
    }

    @Test("Handles an empty input")
    func handlesEmptyInput() {
        #expect(GroupBuilder.groups(from: []).isEmpty)
    }
}
