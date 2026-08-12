import Testing

@testable import DuplicateCore

@Suite("ByteSize.parse")
struct ByteSizeParseTests {
    @Test("Parses the forms the CLI accepts")
    func parsesCLIForms() throws {
        // Binary multipliers, matching _SIZE_UNITS (src/rav/core/duplicates.py:18-24). Decimal units
        // would make "10mb" in and "10.4 MB" out disagree with each other.
        #expect(try ByteSize.parse("0") == 0)
        #expect(try ByteSize.parse("512") == 512)
        #expect(try ByteSize.parse("512b") == 512)
        #expect(try ByteSize.parse("1kb") == 1024)
        #expect(try ByteSize.parse("10mb") == 10 * 1024 * 1024)
        #expect(try ByteSize.parse("2gb") == 2 * 1024 * 1024 * 1024)
    }

    @Test("Is case-insensitive and tolerates surrounding whitespace")
    func normalisesInput() throws {
        #expect(try ByteSize.parse("10MB") == 10 * 1024 * 1024)
        #expect(try ByteSize.parse("10Mb") == 10 * 1024 * 1024)
        #expect(try ByteSize.parse("  5  ") == 5)
        #expect(try ByteSize.parse(" 1 KB ") == 1024)
    }

    @Test("Rejects what the CLI rejects")
    func rejectsInvalidInput() {
        for bad in ["", "  ", "mb", "10tb", "-1", "1.5mb", "abc", "10 mb extra", "1e3"] {
            #expect(throws: ByteSizeError.invalidExpression(bad)) {
                try ByteSize.parse(bad)
            }
        }
    }

    @Test("Refuses a threshold that overflows Int64")
    func refusesOverflow() {
        // A threshold above nine exabytes is not a typo worth guessing at, and silently wrapping it
        // would produce a negative minimum size that lets everything through.
        #expect(throws: ByteSizeError.self) { try ByteSize.parse("99999999999999999999") }
        #expect(throws: ByteSizeError.self) { try ByteSize.parse("9223372036854775807gb") }
    }
}

@Suite("ByteSize.format")
struct ByteSizeFormatTests {
    @Test("Produces the exact strings the CLI's tests pin")
    func matchesPinnedStrings() {
        // Fixed by the CLI's own tests. Drifting from them would make the same file read differently in
        // the two tools, for no reason a user could understand.
        #expect(ByteSize.format(512) == "512 B")
        #expect(ByteSize.format(1024) == "1.0 KB")
        #expect(ByteSize.format(14_540) == "14.2 KB")
        #expect(ByteSize.format(3_670_016) == "3.5 MB")
        #expect(ByteSize.format(1_288_490_189) == "1.2 GB")
    }

    @Test("Bytes below one kibibyte stay whole")
    func bytesStayWhole() {
        #expect(ByteSize.format(0) == "0 B")
        #expect(ByteSize.format(1) == "1 B")
        #expect(ByteSize.format(1023) == "1023 B")
    }

    @Test("Always shows one decimal place above bytes")
    func alwaysOneDecimal() {
        // "2 MB" and "2.0 MB" in the same column make a table impossible to scan.
        #expect(ByteSize.format(2 * 1024 * 1024) == "2.0 MB")
        #expect(ByteSize.format(1024 * 1024 * 1024) == "1.0 GB")
    }

    @Test("Uses a period regardless of locale")
    func usesPeriodRegardlessOfLocale() {
        // Built by hand rather than with String(format: "%.1f"), which honours the C locale and would
        // render "3,5 MB" for a user whose separator is a comma. The unit suffixes are the same word in
        // English and Spanish, so this string is identical in both -- dates are localised, sizes are
        // not.
        #expect(ByteSize.format(3_670_016).contains("."))
        #expect(!ByteSize.format(3_670_016).contains(","))
    }

    @Test("A negative count renders as zero rather than creatively")
    func negativeRendersAsZero() {
        // Reaching here is a caller bug. Rendering "-1 B" would put a nonsense number in front of a
        // user who cannot act on it.
        #expect(ByteSize.format(-1) == "0 B")
    }

    @Test("Round-trips a parsed threshold back to a readable string")
    func roundTripsThreshold() throws {
        // The property that makes the two functions safe to show side by side in a scan sheet.
        #expect(ByteSize.format(try ByteSize.parse("10mb")) == "10.0 MB")
        #expect(ByteSize.format(try ByteSize.parse("1kb")) == "1.0 KB")
    }

    @Test("Handles the largest representable size")
    func handlesMaximum() {
        #expect(!ByteSize.format(.max).isEmpty)
    }
}
