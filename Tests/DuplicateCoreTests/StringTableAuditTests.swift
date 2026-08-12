import Testing

@testable import DuplicateCore

@Suite("StringTableAudit")
struct StringTableAuditTests {
    @Test("Reports nothing when both tables cover the same keys")
    func cleanWhenKeysMatch() {
        let audit = StringTableAudit.audit(
            base: ["a": "Quit", "b": "Scans"],
            translation: ["a": "Salir", "b": "Escaneos"]
        )
        #expect(audit.isClean)
        #expect(audit.missing.isEmpty)
        #expect(audit.orphaned.isEmpty)
        #expect(audit.identical.isEmpty)
    }

    @Test("Names the keys missing from the translation")
    func namesMissingKeys() {
        // A missing key does not crash: NSLocalizedString returns the key itself, so the UI shows
        // "menu.app.quit" where a menu item belongs. Naming it here is the only thing standing
        // between that and a release.
        let audit = StringTableAudit.audit(
            base: ["menu.app.quit": "Quit", "window.title": "Scans"],
            translation: ["window.title": "Escaneos"]
        )
        #expect(!audit.isClean)
        #expect(audit.missing == ["menu.app.quit"])
    }

    @Test("Names keys that exist only in the translation")
    func namesOrphanedKeys() {
        let audit = StringTableAudit.audit(
            base: ["a": "Quit"],
            translation: ["a": "Salir", "removed.key": "Viejo"]
        )
        #expect(!audit.isClean)
        #expect(audit.orphaned == ["removed.key"])
    }

    @Test("Flags identical values without failing the audit")
    func flagsIdenticalValuesOnly() {
        // Some values legitimately match across English and Spanish. This is a signal, not a
        // verdict: a long run of them usually means the base table was copied and left alone.
        let audit = StringTableAudit.audit(
            base: ["a": "Quit", "ok": "OK"],
            translation: ["a": "Salir", "ok": "OK"]
        )
        #expect(audit.isClean)
        #expect(audit.identical == ["ok"])
    }

    @Test("Sorts every result so output is reproducible")
    func sortsResults() {
        let audit = StringTableAudit.audit(
            base: ["z": "1", "a": "2", "m": "3"],
            translation: [:]
        )
        #expect(audit.missing == ["a", "m", "z"])
    }

    @Test("Two empty tables are clean")
    func emptyTablesAreClean() {
        let audit = StringTableAudit.audit(base: [:], translation: [:])
        #expect(audit.isClean)
    }
}
