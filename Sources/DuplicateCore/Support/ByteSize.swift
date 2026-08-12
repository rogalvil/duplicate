/// Parses and renders byte counts the way the `rav duplicate` CLI does.
///
/// Both directions are pinned to fixed output rather than delegated to Foundation. `ByteCountFormatter`
/// is locale-sensitive, which makes UI widths unpredictable and tests unstable, and it uses decimal
/// units where the CLI uses binary ones -- so "10mb" in and "10.4 MB" out would disagree with itself.
///
/// The rendered strings are fixed by the CLI's own tests: `512 B`, `1.0 KB`, `14.2 KB`, `3.5 MB`,
/// `1.2 GB`. They stay identical in English and Spanish: the unit suffixes are the same word in both,
/// and a decimal separator that changes with the user's locale would make the two tools disagree about
/// the same file. Dates are localised; these are not.
public enum ByteSize {
    /// Binary multipliers, matching `_SIZE_UNITS` (`src/rav/core/duplicates.py:18-24`).
    static let multipliers: [(suffix: String, factor: Int64)] = [
        ("b", 1),
        ("kb", 1 << 10),
        ("mb", 1 << 20),
        ("gb", 1 << 30),
    ]

    /// Parses an expression like `10mb`, `512`, `2 GB`.
    ///
    /// Ports `parse_size` (`src/rav/core/duplicates.py:221-234`): a run of digits, then an optional
    /// unit, case-insensitive, surrounding whitespace trimmed. A bare number is bytes.
    ///
    /// - Throws: ``ByteSizeError/invalidExpression`` on anything else. The CLI raises
    ///   `ValueError("tamano invalido: ...")` and exits 2; this throws so the presentation layer can
    ///   localise the message.
    public static func parse(_ expression: String) throws -> Int64 {
        let trimmed = expression.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else {
            throw ByteSizeError.invalidExpression(expression)
        }

        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else {
            throw ByteSizeError.invalidExpression(expression)
        }
        let unit = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)

        guard let amount = Int64(digits) else {
            // Overflows Int64. A threshold larger than 9 exabytes is not a typo worth guessing at.
            throw ByteSizeError.invalidExpression(expression)
        }
        let factor: Int64
        if unit.isEmpty {
            factor = 1
        } else if let match = multipliers.first(where: { $0.suffix == unit }) {
            factor = match.factor
        } else {
            throw ByteSizeError.invalidExpression(expression)
        }

        let (product, overflow) = amount.multipliedReportingOverflow(by: factor)
        guard !overflow else {
            throw ByteSizeError.invalidExpression(expression)
        }
        return product
    }

    /// Renders a byte count as the CLI renders it.
    ///
    /// Bytes are whole and unsuffixed by a decimal; everything above is one decimal place. Ports
    /// `human_size` and matches its test-locked strings exactly.
    public static func format(_ bytes: Int64) -> String {
        // Negative input is a caller bug, not a value to render creatively.
        let magnitude = bytes < 0 ? 0 : bytes
        if magnitude < 1 << 10 {
            return "\(magnitude) B"
        }
        let units: [(threshold: Int64, suffix: String)] = [
            (1 << 30, "GB"),
            (1 << 20, "MB"),
            (1 << 10, "KB"),
        ]
        for unit in units where magnitude >= unit.threshold {
            let scaled = Double(magnitude) / Double(unit.threshold)
            return "\(rounded(scaled)) \(unit.suffix)"
        }
        return "\(magnitude) B"
    }

    /// One decimal place, always shown, with no locale in sight.
    ///
    /// Built by hand instead of `String(format: "%.1f")`, which honours the C locale and would render
    /// `3,5 MB` on a system where the decimal separator is a comma. That is exactly the instability the
    /// project's working agreement bans.
    private static func rounded(_ value: Double) -> String {
        let tenths = Int64((value * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}

public enum ByteSizeError: Error, Equatable, Sendable {
    case invalidExpression(String)
}
