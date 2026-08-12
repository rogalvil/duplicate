import Foundation

/// Builds and validates the scan identifiers and timestamps shared with the `rav duplicate` CLI.
///
/// The CLI derives both from one `datetime.now(UTC)` (`src/rav/core/duplicates.py:99-103`):
///
///     scan_id    = now.strftime("%Y%m%d-%H%M%S-%f")
///     created_at = now.isoformat().replace("+00:00", "Z")
///
/// Those two formats disagree about a zero fraction, and that asymmetry is easy to miss:
///
/// | microseconds | `scan_id` | `created_at` |
/// |---|---|---|
/// | 685054 | `20260511-064716-685054` | `2026-05-11T06:47:16.685054Z` |
/// | 100000 | `20260511-064716-100000` | `2026-05-11T06:47:16.100000Z` |
/// | 0 | `20260511-064716-000000` | `2026-05-11T06:47:16Z` |
///
/// `strftime("%f")` always writes six digits; `isoformat()` omits the fractional part entirely when
/// it is zero, and never trims trailing zeros when it is not. Both are verified by test.
///
/// No `DateFormatter` anywhere, for two reasons. Formatters are locale-sensitive, which the project's
/// working agreement bans for anything whose output has to be stable. And more decisively: **no
/// Foundation formatter can emit six fractional digits.** `ISO8601DateFormatter` supports whole
/// seconds or, with `.withFractionalSeconds`, exactly three.
public enum ScanIdentifier {
    /// Number of characters in a well-formed identifier: `20260511-112539-973098`.
    public static let length = 22

    /// Whether `value` is a well-formed identifier.
    ///
    /// Deliberately strict rather than permissive. ``StateDirectory`` interpolates the result into a
    /// filesystem path, so anything containing `/`, `.` or `..` has to be rejected -- and the
    /// cheapest way to guarantee that is to accept nothing but digits and two hyphens in fixed
    /// positions.
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

    /// The UTC calendar fields of one instant, resolved once so the identifier and the timestamp
    /// cannot disagree about which microsecond they describe.
    public struct Instant: Sendable, Equatable {
        public let year: Int
        public let month: Int
        public let day: Int
        public let hour: Int
        public let minute: Int
        public let second: Int
        /// 0...999_999.
        public let microsecond: Int

        /// Resolves `date` in UTC on the Gregorian calendar.
        ///
        /// `Date` is a `Double` of seconds, so the nanosecond field arrives with rounding noise --
        /// 685053999 where a Python `datetime` would hold 685054. Rounding rather than truncating is
        /// what makes the two agree.
        public init(_ date: Date) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            let parts = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .nanosecond],
                from: date
            )
            year = parts.year ?? 0
            month = parts.month ?? 1
            day = parts.day ?? 1
            hour = parts.hour ?? 0
            minute = parts.minute ?? 0
            second = parts.second ?? 0
            // Clamped rather than carried into the second. A misreported microsecond is invisible;
            // a carry that leaves scan_id and created_at describing different seconds is a real
            // inconsistency between two fields of the same document.
            microsecond = min(999_999, Int((Double(parts.nanosecond ?? 0) / 1000).rounded()))
        }

        public init(
            year: Int,
            month: Int,
            day: Int,
            hour: Int,
            minute: Int,
            second: Int,
            microsecond: Int
        ) {
            self.year = year
            self.month = month
            self.day = day
            self.hour = hour
            self.minute = minute
            self.second = second
            self.microsecond = min(999_999, max(0, microsecond))
        }

        /// The identifier form: `%Y%m%d-%H%M%S-%f`, always six fractional digits.
        public var identifier: String {
            "\(pad(year, 4))\(pad(month, 2))\(pad(day, 2))"
                + "-\(pad(hour, 2))\(pad(minute, 2))\(pad(second, 2))"
                + "-\(pad(microsecond, 6))"
        }

        /// The `created_at` form: ISO-8601 with `Z`, and no fractional part when it is zero.
        public var timestamp: String {
            let base =
                "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
                + "T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))"
            return microsecond == 0 ? base + "Z" : base + ".\(pad(microsecond, 6))Z"
        }

        /// The same instant one microsecond later, rolling the second over when needed.
        public var nextMicrosecond: Instant {
            guard microsecond < 999_999 else {
                // Handing the carry back to Calendar keeps month lengths, leap years and leap
                // seconds out of this file.
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
                let components = DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute, second: second
                )
                guard let date = calendar.date(from: components) else { return self }
                return Instant(date.addingTimeInterval(1))
            }
            return Instant(
                year: year, month: month, day: day,
                hour: hour, minute: minute, second: second,
                microsecond: microsecond + 1
            )
        }

        private func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            guard digits.count < width else { return digits }
            return String(repeating: "0", count: width - digits.count) + digits
        }
    }

    /// The identifier for one instant.
    public static func identifier(from date: Date) -> String {
        Instant(date).identifier
    }

    /// The `created_at` value for one instant.
    public static func timestamp(from date: Date) -> String {
        Instant(date).timestamp
    }

    /// The first identifier at or after `date` that `isTaken` says is free.
    ///
    /// Two tools writing into one directory can collide. At microsecond precision that is
    /// implausible, but the CLI and the app can both be running, and overwriting somebody else's
    /// scan is not an acceptable way to find out. `isTaken` is injected so the search is testable
    /// without a filesystem.
    ///
    /// - Parameter limit: how many microseconds to try before giving up. The default is generous
    ///   enough that exhausting it means something is wrong other than a collision.
    public static func nextAvailable(
        from date: Date,
        limit: Int = 1000,
        isTaken: (String) -> Bool
    ) -> String? {
        var instant = Instant(date)
        for _ in 0..<limit {
            let candidate = instant.identifier
            if !isTaken(candidate) { return candidate }
            instant = instant.nextMicrosecond
        }
        return nil
    }
}
