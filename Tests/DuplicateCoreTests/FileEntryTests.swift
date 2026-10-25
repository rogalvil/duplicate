import Testing

@testable import DuplicateCore

@Suite("FileEntry")
struct FileEntryTests {

    /// **The point of the layout** (#161): a scan holds several lists of every file at once, so each byte here is
    /// paid hundreds of thousands of times over. Five optionals at 16 bytes each made it 112.
    @Test("An entry is 72 bytes")
    func isCompact() {
        #expect(MemoryLayout<FileEntry>.stride == 72)
    }

    @Test("Every optional field reads back what was given")
    func roundTripsEveryField() {
        let full = FileEntry(
            path: "/x/a.bin", size: 10,
            identity: FileIdentity(volume: .max, inode: 42),
            contentIdentifier: -7, linkCount: 3, generation: .max, modifiedNanoseconds: .min)
        #expect(full.identity == FileIdentity(volume: .max, inode: 42))
        #expect(full.contentIdentifier == -7)
        #expect(full.linkCount == 3)
        #expect(full.generation == .max)
        #expect(full.modifiedNanoseconds == .min)

        let bare = FileEntry(path: "/x/a.bin", size: 10)
        #expect(bare.identity == nil)
        #expect(bare.contentIdentifier == nil)
        #expect(bare.linkCount == nil)
        #expect(bare.generation == nil)
        #expect(bare.modifiedNanoseconds == nil)
    }

    /// An absent value is stored as zero, so the mask is what keeps "unknown" apart from "zero" -- the difference
    /// the hardlink partition and the cache key both depend on.
    @Test("Absent is not the same as zero")
    func absentIsNotZero() {
        let bare = FileEntry(path: "/x/a.bin", size: 10)
        let zeros = FileEntry(
            path: "/x/a.bin", size: 10, identity: FileIdentity(volume: 0, inode: 0),
            contentIdentifier: 0, linkCount: 0, generation: 0, modifiedNanoseconds: 0)
        #expect(bare != zeros)
        #expect(zeros.identity == FileIdentity(volume: 0, inode: 0))
        #expect(zeros.linkCount == 0)
        #expect(Set([bare, zeros]).count == 2)
        #expect(bare == FileEntry(path: "/x/a.bin", size: 10))
    }

    @Test("A different size keeps every identity field")
    func withSizeKeepsIdentity() {
        let entry = FileEntry(
            path: "/x/a.bin", size: 10, identity: FileIdentity(volume: 1, inode: 2),
            contentIdentifier: 3, linkCount: 1, generation: 4, modifiedNanoseconds: 5)
        let resized = entry.withSize(11)
        #expect(resized.size == 11)
        #expect(resized.identity == entry.identity)
        #expect(resized.contentIdentifier == 3)
        #expect(resized.linkCount == 1)
        #expect(resized.generation == 4)
        #expect(resized.modifiedNanoseconds == 5)
    }
}
