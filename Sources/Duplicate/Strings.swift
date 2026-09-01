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
    /// Reads the plural table for a localisation, as key to its `one`/`other` pair.
    ///
    /// **`NSLocalizedString` already consults `Localizable.stringsdict`**, so nothing at runtime needed
    /// changing to get plurals -- only the audit did, because it reads the `.strings` files directly and
    /// would otherwise call every pluralised key missing.
    static func plurals(localization: String) -> [String: (one: String, other: String)]? {
        guard
            let url = Bundle.main.url(
                forResource: "Localizable", withExtension: "stringsdict",
                subdirectory: nil, localization: localization),
            let root = NSDictionary(contentsOf: url) as? [String: [String: Any]]
        else { return nil }
        var result: [String: (one: String, other: String)] = [:]
        for (key, entry) in root {
            guard
                let variable = entry.values.compactMap({ $0 as? [String: Any] }).first,
                let one = variable["one"] as? String, let other = variable["other"] as? String
            else { continue }
            result[key] = (one, other)
        }
        return result
    }

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
