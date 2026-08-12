/// One exact-duplicate scan, as stored in `duplicate/scans/<scan_id>.json`.
///
/// Mirrors the CLI's dataclass (`src/rav/core/duplicates.py:35`) field for field, including the
/// decision to hold `createdAt` as an opaque `String`.
public struct DuplicateScan: Hashable, Sendable {
    public let scanID: String
    /// The directory that was scanned, as the document recorded it.
    public let root: String
    /// ISO-8601 with a `Z` suffix and up to six fractional digits.
    ///
    /// A `String`, not a `Date`, and that is not laziness. `ISO8601DateFormatter` cannot round-trip
    /// six fractional digits -- it handles whole seconds, or exactly three with
    /// `.withFractionalSeconds`. Parsing to a `Date` and re-emitting would silently rewrite the
    /// value and break byte-compatibility. The CLI's own dataclass stores a `str` for the same
    /// reason. Use ``createdAtInstant`` when a sortable value is needed for display.
    public let createdAt: String
    public let groups: [DuplicateGroup]

    public init(scanID: String, root: String, createdAt: String, groups: [DuplicateGroup]) {
        self.scanID = scanID
        self.root = root
        self.createdAt = createdAt
        self.groups = groups
    }

    /// Total number of files across every group.
    public var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

    /// Sum of the per-group upper bounds. See ``DuplicateGroup/redundantByteCountUpperBound``.
    public var redundantByteCountUpperBound: Int64 {
        groups.reduce(0) { $0 + $1.redundantByteCountUpperBound }
    }

    /// Whether the scan root or any member path is relative, and therefore not actionable as-is.
    ///
    /// The UI has to resolve these against a base directory the user picks before anything can be
    /// moved; a planner that acted on them would target paths under `/`.
    public var hasRelativePaths: Bool {
        !root.hasPrefix("/") || groups.contains(where: \.hasRelativePaths)
    }

    /// The identifier parsed back into calendar fields, for sorting and display only.
    ///
    /// `nil` when the identifier is malformed. Derived from ``scanID`` rather than from
    /// ``createdAt`` because the identifier's shape is fixed at exactly six fractional digits, while
    /// `created_at` omits them entirely when they are zero.
    public var createdAtInstant: ScanIdentifier.Instant? {
        guard ScanIdentifier.isValid(scanID) else { return nil }
        let digits = Array(scanID.utf8).filter { $0 != UInt8(ascii: "-") }
        func number(_ range: Range<Int>) -> Int {
            digits[range].reduce(0) { $0 * 10 + Int($1 - UInt8(ascii: "0")) }
        }
        return ScanIdentifier.Instant(
            year: number(0..<4),
            month: number(4..<6),
            day: number(6..<8),
            hour: number(8..<10),
            minute: number(10..<12),
            second: number(12..<14),
            microsecond: number(14..<20)
        )
    }
}
