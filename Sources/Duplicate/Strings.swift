import Foundation

/// Localised string lookup for the app bundle.
///
/// Thin on purpose. `DuplicateCore` never produces prose -- it returns structured values such as
/// enum cases and numbers -- so this is the only place a user-visible sentence is assembled, and
/// the only place that needs a bundle.
enum Strings {
    /// Looks up `key` in the bundle's `Localizable.strings`.
    ///
    /// When the key is missing, `NSLocalizedString` returns the key itself rather than failing.
    /// That is why `--selftest --mode l10n` audits the tables: a typo here shows up as
    /// `menu.app.quit` sitting in a menu, which is easy to ship and easy to miss.
    static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, comment: "")
    }

    /// Reads one raw `.strings` table for a specific localisation.
    ///
    /// Used by the l10n selftest to compare the tables against each other. Returns `nil` when the
    /// bundle has no table for that localisation, which is itself a failure worth reporting.
    static func table(localization: String, table name: String = "Localizable") -> [String: String]?
    {
        guard
            let url = Bundle.main.url(
                forResource: name,
                withExtension: "strings",
                subdirectory: nil,
                localization: localization
            )
        else { return nil }
        return NSDictionary(contentsOf: url) as? [String: String]
    }
}
