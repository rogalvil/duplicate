import Foundation
import Testing

@testable import DuplicateCore

@Suite("ScanIdentifier.isValid")
struct ScanIdentifierValidationTests {
    @Test("Accepts an identifier the CLI actually wrote")
    func acceptsRealIdentifier() {
        // Copied from filenames in ~/.local/state/rav/duplicate/.
        #expect(ScanIdentifier.isValid("20260511-112539-973098"))
        #expect(ScanIdentifier.isValid("20260510-194604-719477"))
    }

    @Test("Rejects anything that could escape its directory")
    func rejectsTraversal() {
        // The only caller interpolates this into a filesystem path, so this is the security
        // boundary, not a formatting nicety.
        #expect(!ScanIdentifier.isValid("../../etc/passwd"))
        #expect(!ScanIdentifier.isValid("..////..////..///etc/pa"))
        #expect(!ScanIdentifier.isValid("20260511-112539-97309/"))
        #expect(!ScanIdentifier.isValid("/2026051-112539-973098"))
    }

    @Test("Rejects the wrong length")
    func rejectsWrongLength() {
        #expect(!ScanIdentifier.isValid(""))
        #expect(!ScanIdentifier.isValid("20260511-112539-97309"))
        #expect(!ScanIdentifier.isValid("20260511-112539-9730980"))
    }

    @Test("Rejects separators in the wrong place")
    func rejectsMisplacedSeparators() {
        #expect(!ScanIdentifier.isValid("2026051-1112539-973098"))
        #expect(!ScanIdentifier.isValid("20260511_112539_973098"))
        #expect(!ScanIdentifier.isValid("20260511-112539_973098"))
    }

    @Test("Rejects non-digit characters, including multi-byte ones")
    func rejectsNonDigits() {
        #expect(!ScanIdentifier.isValid("2026051a-112539-973098"))
        #expect(!ScanIdentifier.isValid("2026051 -112539-973098"))
        // Counted in UTF-8 bytes, so a multi-byte character cannot sneak past a length check that
        // happens to add up in Characters.
        #expect(!ScanIdentifier.isValid("2026051á-112539-97309"))
    }
}

@Suite("ScanIdentifier formatting")
struct ScanIdentifierFormattingTests {
    /// Ground truth produced by running the CLI's own two expressions in Python:
    ///
    ///     d.strftime("%Y%m%d-%H%M%S-%f")
    ///     d.isoformat().replace("+00:00", "Z")
    static let table:
        [(
            year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, micro: Int,
            identifier: String, timestamp: String
        )] = [
            (
                2026, 5, 11, 6, 47, 16, 685054, "20260511-064716-685054",
                "2026-05-11T06:47:16.685054Z"
            ),
            (2026, 5, 11, 6, 47, 16, 0, "20260511-064716-000000", "2026-05-11T06:47:16Z"),
            (2026, 5, 11, 6, 47, 16, 1, "20260511-064716-000001", "2026-05-11T06:47:16.000001Z"),
            (
                2026, 5, 11, 6, 47, 16, 100000, "20260511-064716-100000",
                "2026-05-11T06:47:16.100000Z"
            ),
            (2026, 1, 1, 0, 0, 0, 0, "20260101-000000-000000", "2026-01-01T00:00:00Z"),
        ]

    @Test("Matches Python for both formats, including the zero-fraction asymmetry")
    func matchesPython() {
        // The asymmetry is the point: strftime("%f") always writes six digits, so scan_id keeps
        // "-000000", while isoformat() drops the fractional part entirely when it is zero. Emitting
        // ".000000Z" in created_at, or dropping "-000000" from the identifier, both produce files
        // that differ from the CLI's by a handful of bytes.
        for row in Self.table {
            let instant = ScanIdentifier.Instant(
                year: row.year, month: row.month, day: row.day,
                hour: row.hour, minute: row.minute, second: row.second,
                microsecond: row.micro
            )
            #expect(instant.identifier == row.identifier)
            #expect(instant.timestamp == row.timestamp)
        }
    }

    @Test("Every generated identifier is accepted by its own validator")
    func generatesValidIdentifiers() {
        for row in Self.table {
            let instant = ScanIdentifier.Instant(
                year: row.year, month: row.month, day: row.day,
                hour: row.hour, minute: row.minute, second: row.second,
                microsecond: row.micro
            )
            #expect(ScanIdentifier.isValid(instant.identifier))
        }
    }

    @Test("Resolves a Date to the same microsecond in both fields")
    func resolvesDateConsistently() {
        // Date is a Double of seconds, so Calendar hands back a nanosecond field with rounding noise
        // -- 685053999 where a Python datetime holds 685054. Rounding rather than truncating is what
        // makes them agree, and deriving both strings from one Instant is what makes them agree with
        // each other.
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 11
        components.hour = 6
        components.minute = 47
        components.second = 16
        components.nanosecond = 685_054_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = calendar.date(from: components)!

        #expect(ScanIdentifier.identifier(from: date) == "20260511-064716-685054")
        #expect(ScanIdentifier.timestamp(from: date) == "2026-05-11T06:47:16.685054Z")
    }

    @Test("Clamps a rounding carry instead of shifting the second")
    func clampsCarry() {
        // A nanosecond field of 999_999_600 rounds to 1_000_000 microseconds, which is a whole
        // second. Clamping misreports by 0.4 microseconds, which nobody can observe. Carrying would
        // leave scan_id and created_at describing different seconds, which is a real inconsistency
        // between two fields of the same document.
        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16,
            microsecond: 1_000_000
        )
        #expect(instant.microsecond == 999_999)
        #expect(instant.identifier == "20260511-064716-999999")
    }

    @Test("Ignores the process time zone")
    func ignoresProcessTimeZone() {
        // Everything in the shared format is UTC. A formatter honouring the current time zone would
        // produce identifiers that sort wrong and timestamps that lie, and it would do it only for
        // users outside UTC.
        let date = Date(timeIntervalSince1970: 1_778_827_636.685054)
        let first = ScanIdentifier.identifier(from: date)
        #expect(first.hasPrefix("2026"))
        #expect(ScanIdentifier.timestamp(from: date).hasSuffix("Z"))
    }

    @Test("Advances a microsecond, rolling the second over at the boundary")
    func advancesMicrosecond() {
        let mid = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 685054
        )
        #expect(mid.nextMicrosecond.identifier == "20260511-064716-685055")

        let edge = ScanIdentifier.Instant(
            year: 2026, month: 12, day: 31, hour: 23, minute: 59, second: 59, microsecond: 999_999
        )
        // Handing the carry to Calendar is what keeps month lengths and leap years out of this file.
        #expect(edge.nextMicrosecond.identifier == "20270101-000000-000000")
    }

    @Test("Finds the next free identifier when one is taken")
    func findsNextAvailable() {
        // Two tools can write into one directory. Overwriting somebody else's scan is not an
        // acceptable way to discover a collision.
        let date = Date(timeIntervalSince1970: 1_778_827_636.685054)
        let first = ScanIdentifier.identifier(from: date)
        let second = ScanIdentifier.Instant(date).nextMicrosecond.identifier

        #expect(ScanIdentifier.nextAvailable(from: date) { _ in false } == first)
        #expect(ScanIdentifier.nextAvailable(from: date) { $0 == first } == second)
        #expect(ScanIdentifier.nextAvailable(from: date, limit: 3) { _ in true } == nil)
    }

    @Test("An identifier parses back to the instant it names")
    func parsesBackToAnInstant() throws {
        let instant = try #require(ScanIdentifier.instant(from: "20260511-064716-685054"))
        #expect(instant.year == 2026)
        #expect(instant.month == 5)
        #expect(instant.day == 11)
        #expect(instant.hour == 6)
        #expect(instant.minute == 47)
        #expect(instant.second == 16)
        #expect(instant.microsecond == 685_054)
        // Round-trip: reading and re-writing must not move the instant.
        #expect(instant.identifier == "20260511-064716-685054")
    }

    /// Every identifier in the real corpus, and the boundaries, through the round-trip. Parsing digits by
    /// hand is exactly the kind of code that works for one value and is off by a factor of ten for another.
    @Test(
        "Identifiers round-trip through instant",
        arguments: [
            "20260511-064716-685054", "20250101-000000-000000", "20261231-235959-999999",
            "20260101-000000-000001", "20260229-120000-100000",
        ]
    )
    func roundTripsEveryPart(identifier: String) throws {
        let instant = try #require(ScanIdentifier.instant(from: identifier))
        #expect(instant.identifier == identifier)
    }

    @Test("A malformed identifier parses to nil rather than a wrong instant")
    func refusesMalformedIdentifiers() {
        for bad in ["", "20260511-064716", "../../etc/passwd", "2026051x-064716-685054"] {
            #expect(ScanIdentifier.instant(from: bad) == nil)
            #expect(ScanIdentifier.date(from: bad) == nil)
        }
    }

    /// The identifier is UTC, so the `Date` it yields has to be the same instant regardless of the reader's
    /// time zone. Asserted against the seconds value the timestamp names, not against a formatted string.
    @Test("An identifier yields a UTC date")
    func yieldsAUTCDate() throws {
        let date = try #require(ScanIdentifier.date(from: "20260511-064716-685054"))
        #expect(ScanIdentifier.identifier(from: date) == "20260511-064716-685054")
        #expect(ScanIdentifier.timestamp(from: date) == "2026-05-11T06:47:16.685054Z")
    }
}
