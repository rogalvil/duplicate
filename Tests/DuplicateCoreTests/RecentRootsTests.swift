import Foundation
import Testing

@testable import DuplicateCore

private struct RootsScratch {
    let directory: String
    let store: RecentRootsStore

    init() throws {
        directory = NSTemporaryDirectory() + "/duplicate-roots-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        store = RecentRootsStore(url: URL(filePath: directory + "/recent-roots.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}

@Suite("RecentRootsStore")
struct RecentRootsTests {

    @Test("Nothing remembered yet reads as empty")
    func startsEmpty() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }
        #expect(scratch.store.load().isEmpty)
        #expect(scratch.store.available().isEmpty)
    }

    @Test("A remembered root reads back")
    func remembers() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }

        scratch.store.remember("/Volumes/Externo/Fotos", at: "2026-08-12T12:00:00.000000Z")
        let roots = scratch.store.load()
        #expect(roots.count == 1)
        #expect(roots[0].path == "/Volumes/Externo/Fotos")
        #expect(roots[0].lastUsed == "2026-08-12T12:00:00.000000Z")
    }

    @Test("The most recent comes first")
    func ordersByRecency() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }

        scratch.store.remember("/a", at: "2026-08-12T12:00:00.000000Z")
        scratch.store.remember("/b", at: "2026-08-12T12:01:00.000000Z")
        scratch.store.remember("/c", at: "2026-08-12T12:02:00.000000Z")
        #expect(scratch.store.load().map(\.path) == ["/c", "/b", "/a"])
    }

    @Test("Scanning the same folder again moves it to the front without duplicating it")
    func deduplicates() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }

        scratch.store.remember("/a", at: "2026-08-12T12:00:00.000000Z")
        scratch.store.remember("/b", at: "2026-08-12T12:01:00.000000Z")
        scratch.store.remember("/a", at: "2026-08-12T12:02:00.000000Z")

        let roots = scratch.store.load()
        #expect(roots.map(\.path) == ["/a", "/b"])
        #expect(roots[0].lastUsed == "2026-08-12T12:02:00.000000Z")
    }

    /// **Compared by bytes, like every other path comparison here.** `String ==` folds the precomposed and
    /// decomposed spellings of the same accented name together, and the two really do coexist on this
    /// machine's volumes -- so folding them would drop whichever entry the user did not pick.
    @Test("Two spellings of the same accented name are two entries")
    func comparesByBytes() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }
        let precomposed = "/Users/t/Su\u{00E1}rez"
        let decomposed = "/Users/t/Su\u{0061}\u{0301}rez"
        // Swift itself calls these equal, which is exactly the trap.
        #expect(precomposed == decomposed)

        scratch.store.remember(precomposed, at: "2026-08-12T12:00:00.000000Z")
        scratch.store.remember(decomposed, at: "2026-08-12T12:01:00.000000Z")
        #expect(scratch.store.load().count == 2)
    }

    @Test("The list is capped")
    func capsTheList() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }

        for index in 0..<(RecentRootsStore.capacity + 5) {
            scratch.store.remember("/root\(index)", at: "2026-08-12T12:00:0\(index % 10).000000Z")
        }
        let roots = scratch.store.load()
        #expect(roots.count == RecentRootsStore.capacity)
        // The oldest fell off, not the newest.
        #expect(roots.first?.path == "/root\(RecentRootsStore.capacity + 4)")
        #expect(roots.contains { $0.path == "/root0" } == false)
    }

    /// An unmounted external drive is the common case here, and it is not an error: the entry stays in the
    /// file so it comes back when the drive does. Offering it as scannable is what would be wrong.
    @Test("A folder that is not there is remembered but not offered")
    func hidesMissingRoots() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }
        let real = scratch.directory + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)

        scratch.store.remember(real, at: "2026-08-12T12:00:00.000000Z")
        scratch.store.remember("/Volumes/GoneDrive/Photos", at: "2026-08-12T12:01:00.000000Z")

        #expect(scratch.store.load().count == 2)
        #expect(scratch.store.available().map(\.path) == [real])
    }

    /// A file is not a folder, so it is not offered either.
    @Test("A path that became a file is not offered")
    func hidesNonDirectories() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }
        let path = scratch.directory + "/was-a-folder"
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))

        scratch.store.remember(path, at: "2026-08-12T12:00:00.000000Z")
        #expect(scratch.store.available().isEmpty)
    }

    @Test("Forgetting removes one entry and leaves the rest")
    func forgets() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }

        scratch.store.remember("/a", at: "2026-08-12T12:00:00.000000Z")
        scratch.store.remember("/b", at: "2026-08-12T12:01:00.000000Z")
        #expect(scratch.store.forget("/a").map(\.path) == ["/b"])
        #expect(scratch.store.load().map(\.path) == ["/b"])
    }

    /// A convenience list must never be the reason a scan window fails to open.
    @Test("A corrupt file reads as empty rather than throwing")
    func toleratesCorruption() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }
        try Data("{ this is not json".utf8)
            .write(to: URL(filePath: scratch.directory + "/recent-roots.json"))

        #expect(scratch.store.load().isEmpty)
        // And it recovers: remembering overwrites the mess.
        scratch.store.remember("/a", at: "2026-08-12T12:00:00.000000Z")
        #expect(scratch.store.load().map(\.path) == ["/a"])
    }

    @Test("The file is written in the project's own JSON shape")
    func writesReadableJSON() throws {
        let scratch = try RootsScratch()
        defer { scratch.remove() }
        scratch.store.remember("/a", at: "2026-08-12T12:00:00.000000Z")

        let data = try #require(
            FileManager.default.contents(atPath: scratch.directory + "/recent-roots.json"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"format_version\": 1"))
        #expect(text.hasSuffix("\n"))
    }

    /// The default location is Application Support and not Caches: a list of folders the user chose cannot
    /// be rebuilt, and macOS may purge Caches whenever it likes.
    @Test("The default path is under Application Support")
    func defaultsToApplicationSupport() {
        let url = RecentRootsStore.defaultURL(environment: [:], home: "/Users/tester")
        #expect(
            url.path(percentEncoded: false)
                == "/Users/tester/Library/Application Support/com.rogalvil.duplicate/recent-roots.json"
        )
    }
}
