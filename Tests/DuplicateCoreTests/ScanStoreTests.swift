import Foundation
import Testing

@testable import DuplicateCore

/// A store rooted in a temp dir. Every test in this file uses one, so none of them can see -- let alone
/// write to -- the real `~/.local/state/rav/duplicate`, which holds 119 scans this user cares about.
private struct StoreScratch {
    let directory: String
    let store: ScanStore
    let state: StateDirectory

    init() throws {
        directory = NSTemporaryDirectory() + "/duplicate-store-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        state = StateDirectory(
            environment: ["XDG_STATE_HOME": directory],
            homePath: "/Users/tester"
        )
        store = ScanStore(state: state)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private func scan(
    id: String = "20260511-064716-685054",
    root: String = "/root",
    groups: [DuplicateGroup]? = nil
) -> DuplicateScan {
    DuplicateScan(
        scanID: id,
        root: root,
        createdAt: "2026-05-11T06:47:16.685054Z",
        groups: groups
            ?? [
                DuplicateGroup(
                    size: 2048, digest: digest("a"), files: ["/root/a.bin", "/root/sub/a.bin"]),
                DuplicateGroup(
                    size: 1024, digest: digest("b"), files: ["/root/b.bin", "/root/sub/b.bin"]),
            ]
    )
}

@Suite("ScanStore")
struct ScanStoreTests {

    @Test("A saved scan reads back equal")
    func roundTripsAScan() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        let original = scan()
        let path = try scratch.store.save(original)
        #expect(path.hasSuffix("/scans/20260511-064716-685054.json"))

        let reloaded = try scratch.store.loadScan(id: original.scanID)
        #expect(reloaded == original)
    }

    /// The bytes on disk are the shared format, not "whatever our encoder happened to emit". If this ever
    /// diverges the CLI stops being able to read what the app wrote, so it is asserted on the file rather
    /// than on the decoded value.
    @Test("The file on disk is the CLI's byte-for-byte format")
    func writesTheSharedFormat() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        let subject = scan()
        let path = try scratch.store.save(subject)
        let written = try #require(FileManager.default.contents(atPath: path))
        let expected = try JSONWriter.document(DuplicateScanCodec.encode(subject))
        #expect(written == expected)
    }

    /// `Data.write(options: .atomic)` renames a temp file into place, which is the improvement over the
    /// CLI's `Path.write_text`. What a test can actually check is that no temp file is left behind and the
    /// slot holds exactly one document -- an atomic write that leaked its staging file would still be
    /// atomic but would litter the shared directory the CLI lists.
    @Test("Saving twice leaves one file and no debris")
    func overwritesInPlace() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        try scratch.store.save(scan())
        try scratch.store.save(
            scan(groups: [
                DuplicateGroup(size: 8, digest: digest("c"), files: ["/root/c", "/root/d"])
            ]))

        let names = try FileManager.default.contentsOfDirectory(
            atPath: scratch.state.path(for: .scans))
        #expect(names == ["20260511-064716-685054.json"])
        #expect(try scratch.store.loadScan(id: "20260511-064716-685054").groups.count == 1)
    }

    @Test("Loading a scan that was never saved throws notFound")
    func reportsAMissingScan() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        #expect(throws: StoreError.notFound(kind: .scans, id: "20260511-064716-685054")) {
            try scratch.store.loadScan(id: "20260511-064716-685054")
        }
    }

    /// A scan id read off disk is interpolated into a path, so a traversal attempt has to be refused
    /// before it becomes an open. `StateDirectory.filePath` owns the check; this asserts the store does
    /// not route around it.
    @Test("A scan id with path separators is refused")
    func refusesATraversalIdentifier() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        #expect(throws: (any Error).self) {
            try scratch.store.loadScan(id: "../../../etc/passwd")
        }
    }

    @Test("A saved decisions document reads back equal")
    func roundTripsDecisions() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        let document = DecisionsDocument(
            scanID: "20260511-064716-685054",
            createdAt: "2026-05-11T06:50:00.000001Z",
            decisions: [
                ("2048:" + digest("a").hexString, ["/root/a.bin"]),
                ("1024:" + digest("b").hexString, []),
            ]
        )
        let path = try scratch.store.save(document)
        #expect(path.hasSuffix("/decisions/20260511-064716-685054.json"))
        #expect(try scratch.store.loadDecisions(scanID: document.scanID) == document)
    }

    /// The shape a review needs at startup: no file and an empty file both mean "start fresh". Surfacing
    /// a missing-file error here would make every first review of a scan look like a failure.
    @Test("Prior decisions are empty when there is no document")
    func toleratesMissingDecisions() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        #expect(scratch.store.priorDecisions(scanID: "20260511-064716-685054").isEmpty)
    }

    @Test("Prior decisions come back keyed by group")
    func rehydratesPriorDecisions() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        let key = "2048:" + digest("a").hexString
        try scratch.store.save(
            DecisionsDocument(
                scanID: "20260511-064716-685054",
                createdAt: "2026-05-11T06:50:00.000001Z",
                decisions: [(key, ["/root/a.bin"])]
            )
        )
        #expect(
            scratch.store.priorDecisions(scanID: "20260511-064716-685054") == [key: ["/root/a.bin"]]
        )
    }

    /// Descending on the identifier is chronological because the format is `%Y%m%d-%H%M%S-%f`. Asserted
    /// with identifiers whose order differs from their insertion order, so a store that just returned
    /// `contentsOfDirectory` unsorted would fail.
    @Test("Identifiers come back newest first")
    func listsIdentifiersNewestFirst() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        for id in ["20260101-000000-000000", "20260511-064716-685054", "20250101-235959-999999"] {
            try scratch.store.save(scan(id: id))
        }
        #expect(
            scratch.store.identifiers(in: .scans) == [
                "20260511-064716-685054", "20260101-000000-000000", "20250101-235959-999999",
            ]
        )
    }

    /// A slot the CLI never created is normal on this machine -- `folder-decisions/` does not exist in
    /// the real state directory. Listing it is empty, not an error.
    @Test("Listing a slot that does not exist is empty")
    func toleratesAMissingSlot() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        #expect(scratch.store.identifiers(in: .folderDecisions).isEmpty)
    }

    /// Anything that is not a valid identifier is ignored rather than guessed at: a stray file in the
    /// shared directory must not become a scan id that later gets interpolated into a path.
    @Test("Files that are not scans are ignored")
    func ignoresForeignFiles() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        let scans = try scratch.state.create(.scans)
        for name in ["notes.txt", "README", "20260511-064716.json", "../escape.json"] {
            FileManager.default.createFile(atPath: scans + "/" + name, contents: Data("x".utf8))
        }
        try scratch.store.save(scan())
        #expect(scratch.store.identifiers(in: .scans) == ["20260511-064716-685054"])
    }

    @Test("A summary carries the counts a list needs")
    func summarisesAScan() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        try scratch.store.save(scan())
        let summary = try #require(scratch.store.summaries().first)
        #expect(summary.scanID == "20260511-064716-685054")
        #expect(summary.root == "/root")
        #expect(summary.groupCount == 2)
        #expect(summary.fileCount == 4)
        // No storage partition on these groups, so the figure is an upper bound.
        #expect(summary.reclaimableBytes == 3072)
        #expect(summary.isReclaimExact == false)
        #expect(summary.hasDecisions == false)
        #expect(summary.hasRelativePaths == false)
    }

    @Test("A summary reports whether decisions exist beside the scan")
    func summaryNoticesDecisions() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        try scratch.store.save(scan())
        try scratch.store.save(
            DecisionsDocument(
                scanID: "20260511-064716-685054",
                createdAt: "2026-05-11T06:50:00.000001Z",
                decisions: [("2048:" + digest("a").hexString, ["/root/a.bin"])]
            )
        )
        #expect(try #require(scratch.store.summaries().first).hasDecisions)
    }

    /// One unreadable document must not hide every other scan the user has. The list is the only way into
    /// the app's own data, so failing it closed would strand a working corpus behind one bad file.
    @Test("A corrupt scan is skipped, not fatal")
    func skipsACorruptScan() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        try scratch.store.save(scan(id: "20260511-064716-685054"))
        let scans = try scratch.state.create(.scans)
        FileManager.default.createFile(
            atPath: scans + "/20260101-000000-000000.json",
            contents: Data("{\"scan_id\": \"20260101-000000-000000\", \"grou".utf8)
        )

        let summaries = scratch.store.summaries()
        #expect(summaries.map(\.scanID) == ["20260511-064716-685054"])
        // Still listed as an identifier -- the file is there. Only the summary is missing.
        #expect(scratch.store.identifiers(in: .scans).count == 2)
    }

    /// A scan written by the CLI with a relative root records relative paths, which cannot be trashed as
    /// they stand. The flag exists so the UI refuses to act rather than resolving them against whatever
    /// its own working directory happens to be -- which, launched by Launch Services, is `/`.
    @Test("A summary flags relative paths")
    func summaryFlagsRelativePaths() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }

        try scratch.store.save(
            scan(
                root: "sub",
                groups: [DuplicateGroup(size: 8, digest: digest("a"), files: ["sub/a", "sub/b"])]
            )
        )
        #expect(try #require(scratch.store.summaries().first).hasRelativePaths)
    }

    /// **Both files, because a decisions file without its scan is unreadable.** It is keyed by group digests
    /// that only the scan explains, so leaving it behind would leave a file nothing can interpret and
    /// nothing will ever clean up.
    @Test("Deleting a scan removes its decisions too")
    func deletesBoth() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }
        try scratch.store.save(scan())
        try scratch.store.save(
            DecisionsDocument(
                scanID: "20260511-064716-685054",
                createdAt: "2026-05-11T06:50:00.000001Z",
                decisions: [("2048:" + digest("a").hexString, ["/root/a.bin"])]
            )
        )
        #expect(scratch.store.summaries().first?.hasDecisions == true)

        #expect(try scratch.store.delete(id: "20260511-064716-685054"))
        #expect(scratch.store.identifiers(in: .scans).isEmpty)
        #expect(scratch.store.identifiers(in: .decisions).isEmpty)
    }

    @Test("Deleting a scan that is not there is not an error")
    func deleteIsIdempotent() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }
        #expect(try scratch.store.delete(id: "20260511-064716-685054") == false)
    }

    /// Deleting one scan must not take its neighbours with it.
    @Test("Deleting one scan leaves the others alone")
    func deletesOnlyOne() throws {
        let scratch = try StoreScratch()
        defer { scratch.remove() }
        try scratch.store.save(scan(id: "20260101-000000-000000"))
        try scratch.store.save(scan(id: "20260511-064716-685054"))

        #expect(try scratch.store.delete(id: "20260101-000000-000000"))
        #expect(scratch.store.identifiers(in: .scans) == ["20260511-064716-685054"])
    }
}
