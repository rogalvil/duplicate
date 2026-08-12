/// Compares a localisation table against the base table.
///
/// Pure logic over two dictionaries, so it is testable without a bundle. Reading the actual
/// `.strings` files out of `Bundle.main` belongs to the executable; deciding whether the result is
/// acceptable belongs here.
///
/// A missing key does not crash and does not look broken from the outside: `NSLocalizedString`
/// falls back to returning the key itself, so the UI quietly displays `menu.app.quit` where a menu
/// item should be. That is the failure this type exists to catch before it ships.
public struct StringTableAudit: Sendable, Equatable {
    /// Keys present in the base table and absent from the translation. These render as raw keys.
    public let missing: [String]
    /// Keys present only in the translation. Dead weight, and usually a rename left half-done.
    public let orphaned: [String]
    /// Keys whose value is byte-identical in both tables.
    ///
    /// Informational, never a failure: proper nouns, symbols and some short labels legitimately
    /// match across English and Spanish. Worth surfacing because a long run of them usually means
    /// someone copied the base table and stopped there.
    public let identical: [String]

    /// Whether the two tables cover exactly the same keys.
    public var isClean: Bool { missing.isEmpty && orphaned.isEmpty }

    public init(missing: [String], orphaned: [String], identical: [String]) {
        self.missing = missing
        self.orphaned = orphaned
        self.identical = identical
    }

    /// Audits `translation` against `base`. Results are sorted so output is reproducible.
    public static func audit(
        base: [String: String],
        translation: [String: String]
    ) -> StringTableAudit {
        let baseKeys = Set(base.keys)
        let translationKeys = Set(translation.keys)
        return StringTableAudit(
            missing: baseKeys.subtracting(translationKeys).sorted(),
            orphaned: translationKeys.subtracting(baseKeys).sorted(),
            identical: baseKeys.intersection(translationKeys)
                .filter { base[$0] == translation[$0] }
                .sorted()
        )
    }
}
