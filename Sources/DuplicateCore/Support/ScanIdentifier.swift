/// Validation for the scan identifiers shared with the `rav duplicate` CLI.
///
/// The CLI builds them with `datetime.now(UTC).strftime("%Y%m%d-%H%M%S-%f")`
/// (`src/rav/core/duplicates.py:99-103`), which always yields exactly `8-6-6` digits: a
/// zero-padded date, a zero-padded time, and six digits of microseconds. A real one looks like
/// `20260511-112539-973098`.
///
/// Generation lives in a later change; this file exists now because ``StateDirectory`` interpolates
/// an identifier into a filesystem path, and an identifier read off disk is untrusted input.
public enum ScanIdentifier {
    /// Number of characters in a well-formed identifier: `20260511-112539-973098`.
    public static let length = 22

    /// Whether `value` is a well-formed identifier.
    ///
    /// Deliberately strict rather than permissive. The only caller interpolates the result into a
    /// path, so anything containing `/`, `.` or `..` has to be rejected -- and the cheapest way to
    /// guarantee that is to accept nothing but digits and two hyphens in fixed positions.
    public static func isValid(_ value: String) -> Bool {
        let characters = Array(value.utf8)
        guard characters.count == length else { return false }
        for (index, byte) in characters.enumerated() {
            let expectsHyphen = index == 8 || index == 15
            if expectsHyphen {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return false }
            }
        }
        return true
    }
}
