import Testing

@testable import DuplicateCore

@Suite("ScanIdentifier.isValid")
struct ScanIdentifierTests {
    @Test("Accepts an identifier the CLI actually wrote")
    func acceptsRealIdentifier() {
        // Copied from a filename in ~/.local/state/rav/duplicate/similar-scans/.
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
