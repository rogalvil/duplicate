import Foundation
import Testing

@testable import DuplicateCore

private func fixture(_ name: String) throws -> Data {
    try Data(
        contentsOf: URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .notDirectory)
    )
}

@Suite("DuplicateScanCodec")
struct DuplicateScanCodecTests {
    @Test(
        "Round-trips a CLI scan through the typed model, byte for byte",
        arguments: [
            "scan-empty.json", "scan-groups.json",
        ])
    func roundTripsThroughTypedModel(name: String) throws {
        // The JSON interop tests prove JSONValue survives a round trip. This proves the *typed*
        // path does: decode into DuplicateScan, encode back, and the bytes still match. That is the
        // path production actually takes, and it is where a wrong key name or a reordered field
        // would show up.
        let original = try fixture(name)
        let scan = try DuplicateScanCodec.decode(JSONReader.parse(original))
        let reencoded = try JSONWriter.document(DuplicateScanCodec.encode(scan))
        #expect(reencoded == original, "\(name) did not survive the typed round trip")
    }

    @Test("Reads the fields the CLI writes")
    func readsFields() throws {
        let scan = try DuplicateScanCodec.decode(JSONReader.parse(try fixture("scan-groups.json")))
        #expect(scan.scanID == "20260511-064716-685054")
        #expect(scan.root == "/Volumes/Disk/Tmp")
        #expect(scan.createdAt == "2026-05-11T06:47:16.685054Z")
        #expect(scan.groups.count == 2)
        #expect(scan.groups[0].size == 496_243_319)
        #expect(
            scan.groups[0].digest.hexString
                == "e562f2d3dcdff32ae80ad07fbda639183b3311f7bf252f9c7506a6760b9f9046"
        )
        #expect(scan.groups[0].files.count == 2)
        #expect(scan.fileCount == 8)
    }

    @Test("Builds the decision key the CLI uses")
    func buildsDecisionKey() throws {
        // Keyed on content, not on paths, which is what lets a review survive a rescan.
        let scan = try DuplicateScanCodec.decode(JSONReader.parse(try fixture("scan-groups.json")))
        #expect(
            scan.groups[0].key
                == "496243319:e562f2d3dcdff32ae80ad07fbda639183b3311f7bf252f9c7506a6760b9f9046"
        )
        // And it matches a key in the decisions fixture, which was written independently.
        let decisions = try JSONReader.parse(try fixture("decisions-wrapped.json"))
        #expect(decisions["decisions"]?[scan.groups[0].key] != nil)
    }

    @Test("Keeps both Unicode normalisation forms as separate members")
    func keepsNormalisationFormsSeparate() throws {
        // Two paths that Python treats as distinct must stay distinct after decoding. Collapsing
        // them would drop a file from the group -- and a file dropped from a group is a file that
        // never gets reviewed.
        let scan = try DuplicateScanCodec.decode(JSONReader.parse(try fixture("scan-groups.json")))
        let files = scan.groups[0].files
        #expect(files.count == 2)
        #expect(!PathOrder.equal(files[0], files[1]))
    }

    @Test("Reports the upper bound on redundant bytes, not a promise")
    func reportsUpperBound() throws {
        let scan = try DuplicateScanCodec.decode(JSONReader.parse(try fixture("scan-groups.json")))
        // Group 0: two files of 496_243_319 bytes -> one is redundant.
        #expect(scan.groups[0].redundantByteCountUpperBound == 496_243_319)
        // Group 1: six zero-byte files -> nothing to recover, whatever the count.
        #expect(scan.groups[1].redundantByteCountUpperBound == 0)
        #expect(scan.redundantByteCountUpperBound == 496_243_319)
    }

    @Test("A single-member group has nothing redundant")
    func singleMemberGroupIsFree() {
        let digest = Digest32(hexString: String(repeating: "a", count: 64))!
        let group = DuplicateGroup(size: 1024, digest: digest, files: ["/a"])
        #expect(group.redundantByteCountUpperBound == 0)
    }

    @Test("Flags a scan that stored relative paths")
    func flagsRelativePaths() throws {
        // `rav duplicate scan .` stores the string it was given. Those paths cannot be acted on:
        // Launch Services starts the app with / as its working directory, so a planner would target
        // the wrong files entirely.
        let absolute = try DuplicateScanCodec.decode(
            JSONReader.parse(try fixture("scan-groups.json"))
        )
        #expect(!absolute.hasRelativePaths)

        let digest = Digest32(hexString: String(repeating: "b", count: 64))!
        let relative = DuplicateScan(
            scanID: "20260511-064716-685054",
            root: ".",
            createdAt: "2026-05-11T06:47:16.685054Z",
            groups: [DuplicateGroup(size: 1, digest: digest, files: ["a.txt", "b.txt"])]
        )
        #expect(relative.hasRelativePaths)
    }

    @Test("Recovers calendar fields from the identifier")
    func recoversInstant() throws {
        // Derived from scan_id, not created_at, because the identifier always carries six fractional
        // digits while created_at omits them when they are zero.
        let scan = try DuplicateScanCodec.decode(JSONReader.parse(try fixture("scan-groups.json")))
        let instant = try #require(scan.createdAtInstant)
        #expect(instant.year == 2026)
        #expect(instant.month == 5)
        #expect(instant.day == 11)
        #expect(instant.hour == 6)
        #expect(instant.minute == 47)
        #expect(instant.second == 16)
        #expect(instant.microsecond == 685054)
        #expect(instant.timestamp == scan.createdAt)
    }

    @Test("Ignores keys it does not know")
    func ignoresUnknownKeys() throws {
        // The CLI's load_scan reads only the keys it knows, which is what lets the app add namespaced
        // keys of its own. Decoding has to return the favour, or a file the CLI enriched would stop
        // opening here.
        let enriched = try JSONReader.parse(
            """
            {
              "scan_id": "20260511-064716-685054",
              "root": "/x",
              "created_at": "2026-05-11T06:47:16.685054Z",
              "groups": [
                {
                  "size": 1,
                  "sha256": "\(String(repeating: "c", count: 64))",
                  "files": ["/x/a"],
                  "shared_storage": [["/x/a"]]
                }
              ],
              "rav_app": {"partial": true}
            }
            """
        )
        let scan = try DuplicateScanCodec.decode(enriched)
        #expect(scan.groups.count == 1)
        #expect(scan.groups[0].files == ["/x/a"])
    }

    @Test("Names the field when a document is malformed")
    func namesMalformedField() throws {
        // "malformed JSON" is not a diagnosis for a file another tool wrote.
        let base = """
            {"scan_id": "20260511-064716-685054", "root": "/x",
             "created_at": "2026-05-11T06:47:16.685054Z", "groups": []}
            """
        #expect(throws: Never.self) { try DuplicateScanCodec.decode(JSONReader.parse(base)) }

        #expect(throws: ScanDecodingError.missingField("groups")) {
            try DuplicateScanCodec.decode(
                JSONReader.parse(
                    """
                    {"scan_id": "20260511-064716-685054", "root": "/x",
                     "created_at": "2026-05-11T06:47:16.685054Z"}
                    """
                )
            )
        }
        #expect(throws: ScanDecodingError.malformedScanIdentifier("nope")) {
            try DuplicateScanCodec.decode(
                JSONReader.parse(
                    #"{"scan_id": "nope", "root": "/x", "created_at": "", "groups": []}"#)
            )
        }
        #expect(throws: ScanDecodingError.notAnObject(field: "<root>")) {
            try DuplicateScanCodec.decode(JSONReader.parse("[]"))
        }
    }

    @Test("Rejects a group the CLI could never have written")
    func rejectsImpossibleGroup() {
        func decodeGroup(_ text: String) throws -> DuplicateGroup {
            try DuplicateScanCodec.decode(group: JSONReader.parse(text), at: 0)
        }
        let valid = String(repeating: "d", count: 64)

        // A digest that is not 64 hex characters means the file was not produced by hashlib, and
        // treating it as content identity would group unrelated files together.
        #expect(throws: ScanDecodingError.malformedDigest("abc", index: 0)) {
            try decodeGroup(#"{"size": 1, "sha256": "abc", "files": ["/a"]}"#)
        }
        #expect(throws: ScanDecodingError.negativeSize(-1, index: 0)) {
            try decodeGroup(#"{"size": -1, "sha256": "\#(valid)", "files": ["/a"]}"#)
        }
        #expect(throws: ScanDecodingError.emptyPath(index: 0, position: 1)) {
            try decodeGroup(#"{"size": 1, "sha256": "\#(valid)", "files": ["/a", ""]}"#)
        }
        #expect(throws: ScanDecodingError.notAString(field: "groups[0].files[0]")) {
            try decodeGroup(#"{"size": 1, "sha256": "\#(valid)", "files": [1]}"#)
        }
        // A size written as a float means it did not come from the CLI, and a size is never
        // fractional.
        #expect(throws: ScanDecodingError.missingField("groups[0].size")) {
            try decodeGroup(#"{"size": 1.0, "sha256": "\#(valid)", "files": ["/a"]}"#)
        }
    }

    @Test("Encodes a scan built in memory in the CLI's key order")
    func encodesInKeyOrder() throws {
        let digest = Digest32(hexString: String(repeating: "e", count: 64))!
        let scan = DuplicateScan(
            scanID: "20260511-064716-000000",
            root: "/x",
            createdAt: "2026-05-11T06:47:16Z",
            groups: [DuplicateGroup(size: 7, digest: digest, files: ["/x/a", "/x/b"])]
        )
        let keys = try #require(DuplicateScanCodec.encode(scan).objectValue).map(\.key)
        #expect(keys == ["scan_id", "root", "created_at", "groups"])
        let groupKeys = try #require(
            DuplicateScanCodec.encode(group: scan.groups[0]).objectValue
        ).map(\.key)
        #expect(groupKeys == ["size", "sha256", "files"])
    }
}
