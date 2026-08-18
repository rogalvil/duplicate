import Foundation
import Testing

@testable import DuplicateCore

private func document(_ pairs: [(String, SimilarDecision)]) -> SimilarDecisionsDocument {
    SimilarDecisionsDocument(entries: pairs.map { (key: $0.0, decision: $0.1) })
}

private struct DecisionsScratch {
    let root: String
    let state: StateDirectory
    let store: ScanStore

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-simdec-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        store = ScanStore(state: state)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Suite("SimilarDecisionsCodec")
struct SimilarDecisionsCodecTests {

    /// **A bare map, not a wrapped one.** `decisions/` carries `{scan_id, created_at, decisions}`; this file
    /// *is* the map. Verified against 17 real documents.
    @Test("The document is a bare map of pair keys")
    func writesABareMap() throws {
        let text = String(
            decoding: try JSONWriter.document(
                SimilarDecisionsCodec.encode(document([("/a||/b", .keepA)]))),
            as: UTF8.self
        )
        #expect(text == "{\n  \"/a||/b\": \"keep_a\"\n}\n")
        #expect(!text.contains("scan_id"))
        #expect(!text.contains("decisions"))
    }

    @Test("A document round-trips, with all four decisions")
    func roundTripsEveryDecision() throws {
        let subject = document([
            ("/a||/b", .keepA), ("/c||/d", .keepB), ("/e||/f", .keepBoth), ("/g||/h", .keepNone),
        ])
        let encoded = try JSONWriter.document(SimilarDecisionsCodec.encode(subject))
        let decoded = try SimilarDecisionsCodec.decode(JSONReader.parse(encoded))
        #expect(decoded == subject)
        #expect(try JSONWriter.document(SimilarDecisionsCodec.encode(decoded)) == encoded)
    }

    /// **The order is the file's, not a dictionary's.** Re-encoding a real document has to produce the same
    /// bytes, and 943 shuffled lines would fail a comparison over content that is identical.
    @Test("Key order survives a round-trip")
    func preservesKeyOrder() throws {
        let subject = document([
            ("/z||/y", .keepA), ("/a||/b", .keepB), ("/m||/n", .keepBoth),
        ])
        let encoded = try JSONWriter.document(SimilarDecisionsCodec.encode(subject))
        let decoded = try SimilarDecisionsCodec.decode(JSONReader.parse(encoded))
        #expect(decoded.entries.map(\.key) == ["/z||/y", "/a||/b", "/m||/n"])
        // And a dictionary view is still available for lookups, which is what a review needs.
        #expect(decoded.byKey["/a||/b"] == .keepB)
    }

    /// **Refused, not skipped.** Dropping an unrecognised decision would silently turn a reviewed pair back into
    /// an unreviewed one, and the next apply would leave both files in place while the window said it was decided.
    @Test("An unknown decision is refused by name")
    func refusesUnknownDecisions() {
        let value = JSONValue.object([
            JSONMember(key: "/a||/b", value: .string("keep_a")),
            JSONMember(key: "/c||/d", value: .string("keep_the_prettier_one")),
        ])
        #expect(
            throws: ScanDecodingError.unknownDecision("keep_the_prettier_one", key: "/c||/d")
        ) {
            try SimilarDecisionsCodec.decode(value)
        }
    }

    @Test("A non-string value is refused by key")
    func refusesNonStrings() {
        let value = JSONValue.object([JSONMember(key: "/a||/b", value: .int(1))])
        #expect(throws: ScanDecodingError.notAString(field: "/a||/b")) {
            try SimilarDecisionsCodec.decode(value)
        }
    }

    @Test("Anything that is not an object is refused")
    func refusesNonObjects() {
        #expect(throws: ScanDecodingError.notAnObject(field: "<root>")) {
            try SimilarDecisionsCodec.decode(.array([]))
        }
    }

    @Test("An empty document is valid and writes an inline object")
    func handlesAnEmptyDocument() throws {
        let encoded = try JSONWriter.document(SimilarDecisionsCodec.encode(document([])))
        #expect(String(decoding: encoded, as: UTF8.self) == "{}\n")
        #expect(try SimilarDecisionsCodec.decode(JSONReader.parse(encoded)).count == 0)
    }

    @Test("The tally counts each decision")
    func countsDecisions() {
        let subject = document([
            ("/a||/b", .keepA), ("/c||/d", .keepA), ("/e||/f", .keepNone),
        ])
        #expect(subject.count == 3)
        #expect(subject.count(of: .keepA) == 2)
        #expect(subject.count(of: .keepNone) == 1)
        #expect(subject.count(of: .keepBoth) == 0)
    }

    /// The separator is not escaped, so a path containing it produces a key with three halves. Measured: none of
    /// the 943 real keys is ambiguous, and this reports the case rather than hiding it.
    @Test("A key that cannot be split is reported")
    func reportsAmbiguousKeys() {
        let subject = document([
            ("/a||/b", .keepA), ("/we||ird||/b", .keepB),
        ])
        #expect(subject.ambiguousKeys == ["/we||ird||/b"])
    }
}

@Suite("ScanStore similar decisions")
struct SimilarDecisionsStoreTests {

    @Test("Decisions save under the scan id and read back")
    func savesAndLoads() throws {
        let scratch = try DecisionsScratch()
        defer { scratch.remove() }
        let subject = document([("/a||/b", .keepA), ("/c||/d", .keepBoth)])

        let path = try scratch.store.save(subject, scanID: "20260818-120000-000000")
        #expect(path.hasSuffix("similar-decisions/20260818-120000-000000.json"))
        let reloaded = try scratch.store.loadSimilarDecisions(scanID: "20260818-120000-000000")
        #expect(reloaded == subject)
    }

    @Test("A scan with no review reads as an empty map, not an error")
    func toleratesNoReview() {
        let scratch = try! DecisionsScratch()
        defer { scratch.remove() }
        #expect(scratch.store.priorSimilarDecisions(scanID: "20260818-120000-000000").isEmpty)
        #expect(scratch.store.hasSimilarDecisions(scanID: "20260818-120000-000000") == false)
    }

    @Test("A saved review is visible to the summary")
    func badgesTheSummary() async throws {
        let scratch = try DecisionsScratch()
        defer { scratch.remove() }
        let scan = SimilarScan(
            scanID: "20260818-120000-000000", root: "/r", createdAt: "t",
            imageThreshold: 5, videoThreshold: 0.7,
            pairs: [SimilarPair(fileA: "/a", fileB: "/b", similarity: 1.0, mediaKind: .image)]
        )
        _ = try scratch.store.save(scan)
        var summary = try #require(scratch.store.similarSummaries().first)
        #expect(summary.hasDecisions == false)

        _ = try scratch.store.save(document([("/a||/b", .keepA)]), scanID: scan.scanID)
        summary = try #require(scratch.store.similarSummaries().first)
        #expect(summary.hasDecisions)
    }

    @Test("A traversal id is refused rather than written outside the directory")
    func refusesTraversal() throws {
        let scratch = try DecisionsScratch()
        defer { scratch.remove() }
        #expect(throws: (any Error).self) {
            try scratch.store.save(document([]), scanID: "../../etc/passwd")
        }
    }

    /// Written atomically, so a crash mid-save cannot leave a half-written map where a review used to be.
    @Test("Saving twice replaces rather than appends")
    func replacesOnSave() throws {
        let scratch = try DecisionsScratch()
        defer { scratch.remove() }
        _ = try scratch.store.save(
            document([("/a||/b", .keepA), ("/c||/d", .keepB)]), scanID: "20260818-120000-000000")
        _ = try scratch.store.save(
            document([("/a||/b", .keepBoth)]), scanID: "20260818-120000-000000")
        let reloaded = try scratch.store.loadSimilarDecisions(scanID: "20260818-120000-000000")
        #expect(reloaded.count == 1)
        #expect(reloaded.byKey["/a||/b"] == .keepBoth)
    }
}
