import Foundation

/// The build identity the About panel shows.
///
/// Takes raw strings rather than reading `Bundle` itself, so the parsing and formatting can be tested
/// without a bundle, and so a missing or malformed value has one obvious place to be handled. Every
/// field is optional on purpose: a build from a tarball has no git metadata, and a hand-edited
/// `Info.plist` can contain anything.
///
/// **This type produces values, never prose.** No "Versión 0.1.0" here: with two languages, a Spanish
/// sentence inside `DuplicateCore` is a sentence that cannot be translated. The executable owns the
/// wording; this owns what is true.
public struct AboutInfo: Equatable, Sendable {
    /// Marketing version, from `CFBundleShortVersionString`.
    public let version: String?
    /// Monotonic build number, from `CFBundleVersion`.
    ///
    /// The Makefile sets it to `git rev-list --count HEAD`, so it increases with every commit and never
    /// resets. Using the marketing version for both -- which the reference app does -- means two
    /// different builds of 0.1.0 are indistinguishable to Launch Services, to crash reports, and to a
    /// user reading a bug report.
    public let buildNumber: String?
    /// Build timestamp, as stamped by `date +%Y-%m-%dT%H:%M:%S%z`.
    public let buildDate: String?
    /// Short git hash, with a trailing `+` when the tree had uncommitted changes.
    public let commit: String?

    public init(version: String?, buildNumber: String?, buildDate: String?, commit: String?) {
        self.version = version
        self.buildNumber = buildNumber
        self.buildDate = buildDate
        self.commit = commit
    }

    /// Reads the four keys out of an `Info.plist` dictionary.
    ///
    /// Takes the dictionary rather than a `Bundle` so it stays testable, and because the keys are the
    /// contract with the Makefile -- see the `__PLACEHOLDER__` note on ``hasUnsubstitutedPlaceholder``.
    public init(infoDictionary: [String: Any]) {
        self.init(
            version: infoDictionary["CFBundleShortVersionString"] as? String,
            buildNumber: infoDictionary["CFBundleVersion"] as? String,
            buildDate: infoDictionary["DUPBuildDate"] as? String,
            commit: infoDictionary["DUPGitCommit"] as? String
        )
    }

    // MARK: - Resolved values

    /// The version, or `nil` when it is absent or an unsubstituted placeholder.
    public var resolvedVersion: String? { Self.clean(version) }

    /// The build number, or `nil`.
    public var resolvedBuildNumber: String? { Self.clean(buildNumber) }

    /// The commit, or `nil`.
    public var resolvedCommit: String? { Self.clean(commit) }

    /// The build timestamp rendered as `2026-08-12 08:31`, or the raw value when it will not parse.
    ///
    /// Falls back to the raw string rather than hiding it: an unexpected format is still more
    /// informative than "unknown", and it makes a stamping bug visible instead of invisible.
    ///
    /// The rendering is locale-independent -- fixed digits, no month names -- so it reads the same in
    /// English and Spanish and cannot change width with the user's region. The label around it *is*
    /// localised; this is the value inside it.
    public var displayBuildDate: String? {
        guard let raw = Self.clean(buildDate) else { return nil }
        return Self.formatted(raw) ?? raw
    }

    /// Whether the tree had uncommitted changes when this was built.
    ///
    /// Worth surfacing in the panel. A dirty build corresponds to no commit at all, so a bug reported
    /// against it cannot be reproduced from the repository alone -- and the person reporting it has no
    /// way to know that unless the app says so.
    public var isDirtyBuild: Bool {
        Self.clean(commit)?.hasSuffix("+") ?? false
    }

    /// Whether any value still looks like a `__PLACEHOLDER__` the Makefile failed to substitute.
    ///
    /// The whole reason placeholders use that shape. An unsubstituted `CFBundleIdentifier` would orphan
    /// every TCC grant the app had been given, and the failure would show up as "macOS keeps asking for
    /// permission" rather than as anything pointing at the build.
    public var hasUnsubstitutedPlaceholder: Bool {
        [version, buildNumber, buildDate, commit].contains { Self.isPlaceholder($0) }
    }

    /// Whether every field resolved to something.
    public var isComplete: Bool {
        resolvedVersion != nil && resolvedBuildNumber != nil && displayBuildDate != nil
            && resolvedCommit != nil
    }

    // MARK: - Helpers

    /// Treats empty, whitespace-only and `__`-prefixed values as absent.
    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            !trimmed.hasPrefix("__")
        else { return nil }
        return trimmed
    }

    private static func isPlaceholder(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("__") ?? false
    }

    /// Parses `2026-08-12T08:31:29-0600` and renders `2026-08-12 08:31`, in the build's own offset.
    ///
    /// Parsed by hand rather than with a `DateFormatter`. Two reasons, both from the project's working
    /// agreement: a formatter is locale-sensitive, and `ISO8601DateFormatter` will not accept the
    /// `-0600` offset without a colon that `date +%z` does not emit. Rendering in the offset the build
    /// recorded, rather than converting to the reader's zone, keeps the string identical to what the
    /// build machine saw.
    static func formatted(_ raw: String) -> String? {
        let bytes = Array(raw.utf8)
        // yyyy-MM-ddTHH:mm:ss is the first 19 characters; anything shorter is not this format.
        guard bytes.count >= 19 else { return nil }
        func digits(_ range: Range<Int>) -> String? {
            let slice = bytes[range]
            guard slice.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) else {
                return nil
            }
            return String(decoding: slice, as: UTF8.self)
        }
        guard
            let year = digits(0..<4),
            bytes[4] == UInt8(ascii: "-"),
            let month = digits(5..<7),
            bytes[7] == UInt8(ascii: "-"),
            let day = digits(8..<10),
            bytes[10] == UInt8(ascii: "T"),
            let hour = digits(11..<13),
            bytes[13] == UInt8(ascii: ":"),
            let minute = digits(14..<16),
            bytes[16] == UInt8(ascii: ":"),
            digits(17..<19) != nil
        else { return nil }
        return "\(year)-\(month)-\(day) \(hour):\(minute)"
    }
}
