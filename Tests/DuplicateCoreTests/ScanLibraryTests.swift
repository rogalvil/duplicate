import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

/// A library over a temp state directory, so the real one with its 119 scans is never read or written.
private struct LibraryScratch {
    let directory: String
    let store: ScanStore

    init() throws {
        directory = NSTemporaryDirectory() + "/duplicate-library-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        store = ScanStore(
            state: StateDirectory(
                environment: ["XDG_STATE_HOME": directory],
                homePath: "/Users/tester"
            )
        )
    }

    /// Saves a scan with `groupCount` groups of `size` bytes and two files each.
    @discardableResult
    func add(
        id: String, root: String, groupCount: Int = 1, size: Int64 = 1024
    ) throws
        -> DuplicateScan
    {
        let scan = DuplicateScan(
            scanID: id,
            root: root,
            createdAt: "2026-05-11T06:47:16.685054Z",
            groups: (0..<groupCount).map { index in
                DuplicateGroup(
                    size: size,
                    digest: digest("\(index % 10)"),
                    files: ["\(root)/\(index)/a.bin", "\(root)/\(index)/b.bin"]
                )
            }
        )
        try store.save(scan)
        return scan
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}

@Suite("ScanLibrary")
struct ScanLibraryTests {

    @Test("An empty state directory gives an empty library")
    func startsEmpty() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        let library = ScanLibrary(store: scratch.store)
        #expect(library.summaries.isEmpty)
        #expect(library.rows().isEmpty)
        #expect(library.totals.scanCount == 0)
    }

    @Test("Rows come back newest first by default")
    func sortsNewestFirst() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/a")
        try scratch.add(id: "20260511-064716-685054", root: "/b")
        try scratch.add(id: "20250101-235959-999999", root: "/c")

        let library = ScanLibrary(store: scratch.store)
        #expect(
            library.rows().map(\.scanID) == [
                "20260511-064716-685054", "20260101-000000-000000", "20250101-235959-999999",
            ]
        )
        #expect(
            library.rows(sortedBy: .oldest).map(\.scanID) == [
                "20250101-235959-999999", "20260101-000000-000000", "20260511-064716-685054",
            ]
        )
    }

    @Test("Sorting by group count puts the biggest scan first")
    func sortsByGroupCount() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/few", groupCount: 2)
        try scratch.add(id: "20260102-000000-000000", root: "/many", groupCount: 7)

        let library = ScanLibrary(store: scratch.store)
        #expect(library.rows(sortedBy: .mostGroups).map(\.root) == ["/many", "/few"])
    }

    @Test("Sorting by reclaimable bytes puts the biggest first")
    func sortsByReclaimable() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/small", size: 100)
        try scratch.add(id: "20260102-000000-000000", root: "/large", size: 9000)

        let library = ScanLibrary(store: scratch.store)
        #expect(library.rows(sortedBy: .mostReclaimable).map(\.root) == ["/large", "/small"])
    }

    /// **`Array.sort` is not stable.** A comparator that reports two rows as equal may return them in
    /// either order, so a list of scans with identical group counts would shuffle itself on every watcher
    /// fire. Asserted by sorting the same data repeatedly: ties broken on the identifier make it a total
    /// order, and a total order cannot shuffle.
    @Test("A tie is broken on the identifier, so the order never shuffles")
    func breaksTiesDeterministically() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        for index in 1...8 {
            try scratch.add(
                id: "2026010\(index)-000000-000000", root: "/root\(index)", groupCount: 3)
        }

        let library = ScanLibrary(store: scratch.store)
        let expected = (1...8).reversed().map { "2026010\($0)-000000-000000" }
        for _ in 0..<20 {
            #expect(library.rows(sortedBy: .mostGroups).map(\.scanID) == expected)
            #expect(library.rows(sortedBy: .mostReclaimable).map(\.scanID) == expected)
        }
    }

    @Test("A filter matches part of the root")
    func filtersOnRoot() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/Volumes/WD12TB/Photos")
        try scratch.add(id: "20260102-000000-000000", root: "/Users/tester/Downloads")

        let library = ScanLibrary(store: scratch.store)
        #expect(library.rows(filter: "photos").map(\.scanID) == ["20260101-000000-000000"])
        #expect(library.rows(filter: "Downloads").count == 1)
        #expect(library.rows(filter: "  ").count == 2)
        #expect(library.rows(filter: "nothing here").isEmpty)
    }

    /// The one place a path is compared as text rather than as bytes, and it is safe because the answer is
    /// only ever displayed. Somebody typing `suarez` should find `Suárez`; `PathOrder` still decides what
    /// counts as the same file.
    @Test("The filter ignores case and diacritics")
    func foldsTheFilter() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/Users/tester/Su\u{00E1}rez")

        let library = ScanLibrary(store: scratch.store)
        #expect(library.rows(filter: "suarez").count == 1)
        #expect(library.rows(filter: "SUÁREZ").count == 1)
        // And the decomposed spelling of the same name, which is the form the boot volume writes.
        #expect(library.rows(filter: "su\u{0061}\u{0301}rez").count == 1)
    }

    @Test("A filter can name a scan id")
    func filtersOnIdentifier() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/a")
        try scratch.add(id: "20260511-064716-685054", root: "/b")

        let library = ScanLibrary(store: scratch.store)
        #expect(library.rows(filter: "20260511").map(\.root) == ["/b"])
    }

    @Test("Totals add up across scans")
    func addsUpTotals() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/a", groupCount: 2, size: 1000)
        try scratch.add(id: "20260102-000000-000000", root: "/b", groupCount: 3, size: 10)

        let library = ScanLibrary(store: scratch.store)
        let totals = library.totals
        #expect(totals.scanCount == 2)
        #expect(totals.groupCount == 5)
        #expect(totals.fileCount == 10)
        // Two files per group with no storage partition: one file's worth of bytes per group.
        #expect(totals.reclaimableBytes == 2 * 1000 + 3 * 10)
        // No partition recorded, so every figure is an upper bound.
        #expect(totals.isReclaimExact == false)
    }

    @Test("Refreshing picks up a scan written after the library was built")
    func refreshesOnChange() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        var library = ScanLibrary(store: scratch.store)
        #expect(library.summaries.isEmpty)

        try scratch.add(id: "20260101-000000-000000", root: "/a")
        // `#expect` captures its operand immutably, so a mutating call has to happen first.
        let changed = library.refresh()
        #expect(changed)
        #expect(library.summaries.count == 1)
    }

    /// The watcher fires for anything in the directory, including a decisions document being re-saved,
    /// which leaves every row identical. Reporting no change lets the window skip a table reload -- and a
    /// reload drops the selection, so a spurious one is visible to the user.
    @Test("Refreshing with nothing changed reports no change")
    func reportsNoChangeWhenIdentical() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/a")
        var library = ScanLibrary(store: scratch.store)
        let changed = library.refresh()
        #expect(changed == false)
        #expect(library.summaries.count == 1)
    }

    @Test("Refreshing notices a decisions file appearing beside a scan")
    func noticesNewDecisions() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }

        try scratch.add(id: "20260101-000000-000000", root: "/a")
        var library = ScanLibrary(store: scratch.store)
        #expect(library.summaries.first?.hasDecisions == false)

        try scratch.store.save(
            DecisionsDocument(
                scanID: "20260101-000000-000000",
                createdAt: "2026-05-11T06:50:00.000001Z",
                decisions: [("1024:" + digest("0").hexString, ["/a/0/a.bin"])]
            )
        )
        let changed = library.refresh()
        #expect(changed)
        #expect(library.summaries.first?.hasDecisions == true)
    }

    /// The window opens with an empty library and fills it from a background task, because reading the real
    /// corpus takes 0.34 s and doing that on the main thread stalls the window before it draws.
    @Test("A library can start empty and be filled later")
    func startsEmptyOnRequest() throws {
        let scratch = try LibraryScratch()
        defer { scratch.remove() }
        try scratch.add(id: "20260101-000000-000000", root: "/a")

        var library = ScanLibrary(store: scratch.store, loadNow: false)
        #expect(library.summaries.isEmpty)
        #expect(library.totals.scanCount == 0)

        let adopted = library.adopt(scratch.store.summaries())
        #expect(adopted)
        #expect(library.summaries.count == 1)

        // Adopting the same list again is not a change, so a table does not get reloaded for nothing --
        // and a reload drops the selection, which the user sees.
        let again = library.adopt(scratch.store.summaries())
        #expect(again == false)
    }
}
