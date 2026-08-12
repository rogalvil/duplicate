import Testing

@testable import DuplicateCore

@Suite("JSONValue accessors")
struct JSONValueTests {
    static let document = JSONValue.object([
        "scan_id": .string("20260511-112539-973098"),
        "threshold": .double(0.9),
        "count": .int(3),
        "whole": .double(1.0),
        "flag": .bool(true),
        "nothing": .null,
        "pairs": .array([.string("a"), .int(2)]),
        "empty": .object([]),
    ])

    @Test("Object literals keep the order they were written in")
    func keepsLiteralOrder() throws {
        // KeyValuePairs, not Dictionary. A Dictionary literal would reorder these, and key order is
        // part of the format shared with the CLI.
        let keys = try #require(Self.document.objectValue).map(\.key)
        #expect(
            keys == [
                "scan_id", "threshold", "count", "whole", "flag", "nothing", "pairs", "empty",
            ]
        )
    }

    @Test("Subscripts reach members and elements, and report absence")
    func subscriptsResolve() {
        #expect(Self.document["scan_id"] == .string("20260511-112539-973098"))
        #expect(Self.document["absent"] == nil)
        #expect(Self.document["pairs"]?[0] == .string("a"))
        #expect(Self.document["pairs"]?[9] == nil)
        // A key subscript on a non-object, and an index subscript on a non-array, are nil rather
        // than a trap: a malformed scan file should surface as a decoding error upstream.
        #expect(JSONValue.string("x")["k"] == nil)
        #expect(JSONValue.string("x")[0] == nil)
        #expect(Self.document[0] == nil)
    }

    @Test("First match wins on a duplicate key")
    func firstDuplicateWins() {
        // Malformed input can carry duplicate keys. json.loads keeps the last one; this keeps the
        // first. Documented rather than silently different: the CLI never writes duplicates, so the
        // only way to see one is a hand-edited file, and either choice is arbitrary.
        let value = JSONValue.object([
            JSONMember(key: "a", value: .int(1)),
            JSONMember(key: "a", value: .int(2)),
        ])
        #expect(value["a"] == .int(1))
    }

    @Test("An integer accessor refuses a float literal")
    func intAccessorRefusesFloat() {
        // A size written as 1.0 means the file was not written by the CLI. Coercing it would hide
        // that, and a size is never fractional.
        #expect(Self.document["count"]?.intValue == 3)
        #expect(Self.document["whole"]?.intValue == nil)
        #expect(Self.document["scan_id"]?.intValue == nil)
    }

    @Test("A double accessor accepts either numeric literal")
    func doubleAccessorAcceptsBoth() {
        // A threshold of 1 and a threshold of 1.0 mean the same thing, so this one does convert.
        #expect(Self.document["threshold"]?.doubleValue == 0.9)
        #expect(Self.document["count"]?.doubleValue == 3.0)
        #expect(Self.document["flag"]?.doubleValue == nil)
    }

    @Test("Typed accessors return nil for the wrong case")
    func typedAccessorsAreStrict() {
        #expect(Self.document["scan_id"]?.stringValue == "20260511-112539-973098")
        #expect(Self.document["count"]?.stringValue == nil)
        #expect(Self.document["pairs"]?.arrayValue?.count == 2)
        #expect(Self.document["count"]?.arrayValue == nil)
        #expect(Self.document["empty"]?.objectValue?.isEmpty == true)
        #expect(Self.document["pairs"]?.objectValue == nil)
    }
}
