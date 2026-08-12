import Foundation
import Testing

@testable import DuplicateCore

/// Fixtures live next to this file and are located through `#filePath` rather than a SwiftPM
/// resource bundle. They are only read by tests, never shipped, and `Bundle.module` would add a
/// resource declaration to the package for no gain.
private func fixtureURL(_ name: String) -> URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)
        .appending(path: name, directoryHint: .notDirectory)
}

private let fixtureNames = [
    "scan-empty.json",
    "scan-groups.json",
    "folder-scan.json",
    "decisions-wrapped.json",
    "similar-decisions-bare.json",
    "escapes.json",
]

@Suite("JSON interop with the rav CLI")
struct JSONInteropTests {
    @Test("Re-encoding a file Python wrote reproduces it byte for byte", arguments: fixtureNames)
    func roundTripsPythonOutput(name: String) throws {
        // The whole compatibility claim, as a measurement. Every fixture was produced by
        // `json.dumps(obj, indent=2) + "\n"` -- the exact call the CLI's save_scan makes -- so a
        // byte-identical re-encode means the two tools write interchangeable files. A failure here
        // is a diff, not a discussion.
        let original = try Data(contentsOf: fixtureURL(name))
        let reencoded = try JSONWriter.document(JSONReader.parse(original))
        if reencoded != original {
            let expected = String(decoding: original, as: UTF8.self)
            let actual = String(decoding: reencoded, as: UTF8.self)
            let offset = zip(original, reencoded).enumerated().first {
                $0.element.0 != $0.element.1
            }?
            .offset
            Issue.record(
                """
                \(name) did not round-trip.
                first difference at byte \(offset.map(String.init) ?? "end of the shorter document")
                expected \(original.count) bytes, produced \(reencoded.count)
                --- expected ---
                \(expected)
                --- produced ---
                \(actual)
                """
            )
        }
    }

    @Test("Keeps both Unicode normalisation forms distinct through a round trip")
    func keepsNormalisationFormsDistinct() throws {
        // Python wrote one path with a precomposed a-acute and one with the decomposed form. Both
        // occur inside a single real scan file. If the parser or the writer normalised either one,
        // two paths the CLI treats as different would become one -- and a group would lose a file.
        let parsed = try JSONReader.parse(try Data(contentsOf: fixtureURL("scan-groups.json")))
        let files = try #require(parsed["groups"]?[0]?["files"]?.arrayValue)
        let first = try #require(files[0].stringValue)
        let second = try #require(files[1].stringValue)
        #expect(first == second, "Swift String equality treats these as the same path")
        #expect(!PathOrder.equal(first, second), "their bytes must still differ")
        #expect(first.utf8.count != second.utf8.count)
    }

    @Test("Preserves key order rather than sorting")
    func preservesKeyOrder() throws {
        let parsed = try JSONReader.parse(try Data(contentsOf: fixtureURL("scan-empty.json")))
        let keys = try #require(parsed.objectValue).map(\.key)
        #expect(keys == ["scan_id", "root", "created_at", "groups"])
    }

    @Test("Keeps a whole float from collapsing to an integer")
    func keepsWholeFloat() throws {
        // A similarity of exactly 1 is written 1.0 by Python and 1 by JSONEncoder. This is the only
        // place a float appears in the shared format, and it appears there often: two identical
        // folders score exactly 1.0.
        let parsed = try JSONReader.parse(try Data(contentsOf: fixtureURL("folder-scan.json")))
        let similarity = try #require(parsed["pairs"]?[0]?["similarity"])
        #expect(similarity == .double(1.0))
        #expect(try JSONWriter.encode(similarity) == "1.0")
        // And an integer must not gain one.
        #expect(try JSONWriter.encode(.int(1)) == "1")
    }

    @Test("Recognises the bare map shape of similar-decisions")
    func readsBareDecisionMap() throws {
        // similar-decisions files have no wrapper object at all, unlike decisions and
        // folder-decisions. One type cannot honestly represent both, which is why there are two
        // stores rather than one with a flag.
        let parsed = try JSONReader.parse(
            try Data(contentsOf: fixtureURL("similar-decisions-bare.json"))
        )
        let members = try #require(parsed.objectValue)
        #expect(members.count == 2)
        #expect(parsed["/Volumes/Disk/a.mp4||/Volumes/Disk/b.mp4"] == .string("keep_a"))
        #expect(parsed["scan_id"] == nil)
    }
}

@Suite("JSONWriter")
struct JSONWriterTests {
    @Test("Escapes exactly the characters Python escapes")
    func escapesLikePython() throws {
        // Ground truth taken from json.dumps on each input. The four a hand-written encoder most
        // often gets wrong: '/' must stay literal; DEL must be escaped even though it is ASCII;
        // control characters use the short forms where they exist; and an astral scalar becomes a
        // UTF-16 surrogate pair, not \U0001f600.
        //
        // The expected column is raw-string source, so a backslash-u sequence there is literal
        // text rather than a Swift escape: it is exactly the bytes json.dumps wrote.
        let cases: [(String, String)] = [
            ("\"", #""\"""#),
            ("\\", #""\\""#),
            ("/", #""/""#),
            ("\n", #""\n""#),
            ("\r", #""\r""#),
            ("\t", #""\t""#),
            ("\u{08}", #""\b""#),
            ("\u{0C}", #""\f""#),
            ("\u{01}", #""\u0001""#),
            ("\u{1F}", #""\u001f""#),
            ("\u{7F}", #""\u007f""#),
            ("\u{A0}", #""\u00a0""#),
            ("\u{E9}", #""\u00e9""#),
            ("e\u{0301}", #""e\u0301""#),
            ("\u{4E2D}", #""\u4e2d""#),
            ("\u{1F600}", #""\ud83d\ude00""#),
            ("\u{1F1F2}\u{1F1FD}", #""\ud83c\uddf2\ud83c\uddfd""#),
            ("", #""""#),
        ]
        for (input, expected) in cases {
            #expect(
                try JSONWriter.encode(.string(input)) == expected,
                "input \(input.debugDescription)"
            )
        }
    }

    @Test("Writes empty containers inline")
    func writesEmptyContainersInline() throws {
        #expect(try JSONWriter.encode(.array([])) == "[]")
        #expect(try JSONWriter.encode(.object([])) == "{}")
        #expect(
            try JSONWriter.encode(.object(["groups": .array([])]))
                == "{\n  \"groups\": []\n}"
        )
    }

    @Test("Indents two spaces per level")
    func indentsTwoSpaces() throws {
        let value = JSONValue.object([
            "a": .array([.int(1), .object(["b": .string("c")])])
        ])
        #expect(
            try JSONWriter.encode(value) == """
                {
                  "a": [
                    1,
                    {
                      "b": "c"
                    }
                  ]
                }
                """
        )
    }

    @Test("Appends the trailing newline the CLI's save_scan adds")
    func appendsTrailingNewline() throws {
        let data = try JSONWriter.document(.object([]))
        #expect(data == Data("{}\n".utf8))
        #expect(data.last == UInt8(ascii: "\n"))
    }

    @Test("Refuses a non-finite double instead of writing invalid JSON")
    func refusesNonFinite() {
        // Python would write NaN, which no JSON parser but Python's accepts. A non-finite
        // similarity is an upstream bug, and producing a file only one tool can read would hide it.
        // Matched by type, not by value: the synthesised Equatable on the error compares its Double
        // payload, and NaN is never equal to itself, so an exact-value expectation fails with the
        // baffling "expected .nonFiniteNumber(nan) but .nonFiniteNumber(nan) was thrown instead".
        #expect(throws: JSONWriterError.self) { try JSONWriter.encode(.double(.nan)) }
        #expect(throws: JSONWriterError.nonFiniteNumber(Double.infinity)) {
            try JSONWriter.encode(.double(.infinity))
        }
        #expect(throws: JSONWriterError.nonFiniteNumber(-Double.infinity)) {
            try JSONWriter.encode(.double(-.infinity))
        }
    }

    @Test("Matches Python's repr for exponent forms")
    func matchesPythonFloatRepr() throws {
        // Verified against Python: repr(1e-05) is '1e-05' and repr(1e16) is '1e+16'. Swift's
        // Double.description agrees on both, so no special casing is needed -- but it is asserted
        // here because the plan had this listed as a residual gap, and it is not one.
        #expect(try JSONWriter.encode(.double(1e-05)) == "1e-05")
        #expect(try JSONWriter.encode(.double(1e16)) == "1e+16")
        #expect(try JSONWriter.encode(.double(0.3333333333333333)) == "0.3333333333333333")
        #expect(try JSONWriter.encode(.double(0.0)) == "0.0")
    }
}

@Suite("JSONReader")
struct JSONReaderTests {
    @Test("Distinguishes an integer literal from a float literal")
    func distinguishesNumberLiterals() throws {
        // json.loads makes the same distinction, and it has to survive so a re-encode is
        // byte-identical: 1 must not come back as 1.0.
        #expect(try JSONReader.parse("1") == .int(1))
        #expect(try JSONReader.parse("1.0") == .double(1.0))
        #expect(try JSONReader.parse("-0") == .int(0))
        #expect(try JSONReader.parse("1e3") == .double(1000.0))
        #expect(try JSONReader.parse("9223372036854775807") == .int(Int64.max))
    }

    @Test("Decodes every escape form, including split surrogate pairs")
    func decodesEscapes() throws {
        #expect(try JSONReader.parse(#""😀""#) == .string("\u{1F600}"))
        #expect(try JSONReader.parse(#""é""#) == .string("\u{E9}"))
        #expect(try JSONReader.parse(#""é""#) == .string("e\u{0301}"))
        #expect(try JSONReader.parse(#""\/""#) == .string("/"))
        #expect(try JSONReader.parse(#""\b\f\n\r\t""#) == .string("\u{08}\u{0C}\n\r\t"))
    }

    @Test("Rejects malformed input instead of guessing")
    func rejectsMalformedInput() {
        #expect(throws: (any Error).self) { try JSONReader.parse("") }
        #expect(throws: (any Error).self) { try JSONReader.parse("{") }
        #expect(throws: (any Error).self) { try JSONReader.parse("{\"a\": 1,}") }
        #expect(throws: (any Error).self) { try JSONReader.parse("[1, 2") }
        #expect(throws: (any Error).self) { try JSONReader.parse("{a: 1}") }
        #expect(throws: (any Error).self) { try JSONReader.parse("{} {}") }
        #expect(throws: (any Error).self) { try JSONReader.parse(#""\ud83d""#) }
        #expect(throws: (any Error).self) { try JSONReader.parse(#""\q""#) }
        #expect(throws: (any Error).self) { try JSONReader.parse("nul") }
        // NaN and Infinity are valid to Python's json.loads and rejected here on purpose.
        #expect(throws: (any Error).self) { try JSONReader.parse("NaN") }
    }

    @Test("Rejects an unescaped control character in a string")
    func rejectsRawControlCharacter() {
        #expect(throws: JSONReaderError.unescapedControlCharacter(offset: 1)) {
            try JSONReader.parse("\"\u{01}\"")
        }
    }

    @Test("Reports the byte offset of the first problem")
    func reportsOffset() {
        #expect(throws: JSONReaderError.expectedKey(offset: 1)) {
            try JSONReader.parse("{1: 2}")
        }
    }

    @Test("Ignores whitespace between tokens")
    func ignoresWhitespace() throws {
        #expect(try JSONReader.parse("  {\n\t\"a\" :\r 1 }  ") == .object(["a": .int(1)]))
    }
}
