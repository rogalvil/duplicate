import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

@Suite("ThumbnailKey")
struct ThumbnailKeyTests {

    /// **The reason the key exists.** Eight files in a group have identical content, so they need one
    /// thumbnail. Keying on the path would send eight XPC round trips and hold eight copies of one bitmap.
    @Test("Two files with the same content and extension share a key")
    func collapsesIdenticalContent() {
        let a = ThumbnailKey(digest: digest("a"), path: "/photos/one.jpg", pixelSize: 256)
        let b = ThumbnailKey(digest: digest("a"), path: "/other/deep/two.jpg", pixelSize: 256)
        #expect(a == b)
    }

    /// **Documented, not defensive.** `QLThumbnailGenerator.Request` says the content type "is derived from
    /// the file extension", and the content type picks the thumbnail provider. So the same bytes named
    /// `report.pdf` and `report.dat` legitimately render differently.
    @Test("The extension is part of the key")
    func separatesExtensions() {
        let pdf = ThumbnailKey(digest: digest("a"), path: "/x/report.pdf", pixelSize: 256)
        let dat = ThumbnailKey(digest: digest("a"), path: "/x/report.dat", pixelSize: 256)
        #expect(pdf != dat)
    }

    @Test("The extension is compared case-insensitively")
    func foldsExtensionCase() {
        let lower = ThumbnailKey(digest: digest("a"), path: "/x/a.jpg", pixelSize: 256)
        let upper = ThumbnailKey(digest: digest("a"), path: "/x/b.JPG", pixelSize: 256)
        #expect(lower == upper)
    }

    @Test("The pixel size is part of the key")
    func separatesSizes() {
        let small = ThumbnailKey(digest: digest("a"), path: "/x/a.jpg", pixelSize: 64)
        let large = ThumbnailKey(digest: digest("a"), path: "/x/a.jpg", pixelSize: 256)
        #expect(small != large)
    }

    @Test("Different content never shares a key")
    func separatesContent() {
        let a = ThumbnailKey(digest: digest("a"), path: "/x/a.jpg", pixelSize: 256)
        let b = ThumbnailKey(digest: digest("b"), path: "/x/a.jpg", pixelSize: 256)
        #expect(a != b)
    }
}

@Suite("ThumbnailPolicy")
struct ThumbnailPolicyTests {

    @Test("A point size becomes pixels at the screen scale")
    func scalesToPixels() {
        #expect(ThumbnailPolicy.pixelSize(points: 100, scale: 2) == 224)
        #expect(ThumbnailPolicy.pixelSize(points: 100, scale: 1) == 128)
    }

    /// A pane the user drags produces a continuum of point sizes. Without rounding, every pixel of resize
    /// is a cache miss and a fresh XPC call to `quicklookd`.
    @Test("Nearby sizes round to the same bucket")
    func roundsToBuckets() {
        // 97 through 128 all land on 128. The upper end is exact rather than guessed: buckets are 32 wide,
        // so 129 starts the next one, and asserting a range that straddles a boundary would be asserting
        // something false about correct code.
        let sizes = (97...128).map { ThumbnailPolicy.pixelSize(points: Double($0), scale: 1) }
        #expect(Set(sizes) == [128])
        #expect(ThumbnailPolicy.pixelSize(points: 129, scale: 1) == 160)
    }

    @Test("Sizes are clamped at both ends")
    func clampsSizes() {
        #expect(ThumbnailPolicy.pixelSize(points: 1, scale: 1) == 32)
        #expect(ThumbnailPolicy.pixelSize(points: 4000, scale: 2) == 512)
        // A nonsense scale does not produce a nonsense size.
        #expect(ThumbnailPolicy.pixelSize(points: 100, scale: 0) == 128)
    }

    @Test("The extension is the last one, lowercased, without the dot")
    func readsExtensions() {
        #expect(ThumbnailPolicy.pathExtension(of: "/x/a.JPG") == "jpg")
        #expect(ThumbnailPolicy.pathExtension(of: "/x/a.tar.gz") == "gz")
        #expect(ThumbnailPolicy.pathExtension(of: "/x/noext") == "")
        // A leading dot is not an extension.
        #expect(ThumbnailPolicy.pathExtension(of: "/x/.DS_Store") == "")
        // A trailing dot names no extension either.
        #expect(ThumbnailPolicy.pathExtension(of: "/x/weird.") == "")
    }
}

@Suite("LRUCache")
struct LRUCacheTests {

    @Test("A stored value reads back")
    func roundTrips() {
        var cache = LRUCache<String, Int>(capacity: 4)
        cache.insert(1, for: "a")
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.count == 1)
    }

    @Test("Filling past the capacity evicts the oldest")
    func evictsOldest() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        let evicted = cache.insert(3, for: "c")
        #expect(evicted == "a")
        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == 2)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.count == 2)
    }

    /// The point of least-recently-*used* rather than first-in-first-out: a user paging back and forth
    /// through two groups must not evict the one they keep returning to.
    @Test("Reading a value protects it from eviction")
    func readingRefreshes() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        #expect(cache.value(for: "a") == 1)
        let evicted = cache.insert(3, for: "c")
        #expect(evicted == "b")
        #expect(cache.value(for: "a") == 1)
    }

    @Test("Peeking does not change the eviction order")
    func peekDoesNotRefresh() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        #expect(cache.peek("a") == 1)
        #expect(cache.insert(3, for: "c") == "a")
    }

    @Test("Replacing a key evicts nothing")
    func replacingDoesNotEvict() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        let evicted = cache.insert(99, for: "a")
        #expect(evicted == nil)
        #expect(cache.value(for: "a") == 99)
        #expect(cache.count == 2)
    }

    @Test("A capacity of zero still holds one entry")
    func refusesAUselessCapacity() {
        var cache = LRUCache<String, Int>(capacity: 0)
        cache.insert(1, for: "a")
        #expect(cache.value(for: "a") == 1)
    }

    @Test("Eviction order is reported oldest first")
    func reportsAge() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        _ = cache.value(for: "a")
        #expect(cache.keysByAge == ["b", "c", "a"])
    }

    @Test("Clearing empties it")
    func clears() {
        var cache = LRUCache<String, Int>(capacity: 3)
        cache.insert(1, for: "a")
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.keysByAge.isEmpty)
    }

    /// A thumbnail cache is asked for the same key repeatedly while a user arrows through a group. The
    /// order bookkeeping has to survive that without growing.
    @Test("Repeated reads do not grow the order list")
    func staysBounded() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        for _ in 0..<100 {
            _ = cache.value(for: "a")
            _ = cache.value(for: "b")
        }
        #expect(cache.keysByAge.count == 2)
        #expect(cache.count == 2)
    }
}
