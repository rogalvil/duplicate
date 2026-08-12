/// Finds a free name when a destination is already taken.
///
/// Ports `unique_destination` (`src/rav/core/duplicates.py:172-186`): a counter starting at 2, inserted
/// before the extension, so `photo.jpg` becomes `photo-2.jpg` and then `photo-3.jpg`.
///
/// **The `.tar.gz` quirk is preserved deliberately.** Python's `Path.stem` and `Path.suffix` see only the
/// last dot, so `archive.tar.gz` becomes `archive.tar-2.gz` rather than `archive-2.tar.gz`. Producing a
/// different name than the CLI would, for the same collision, would make a quarantine directory that the
/// two tools disagree about. There is a test whose name says this is on purpose.
public enum CollisionResolver {
    /// The first free name at or after `path`.
    ///
    /// - Parameters:
    ///   - path: the preferred destination.
    ///   - limit: how many suffixes to try before giving up. Exhausting it means something other than a
    ///     collision is wrong -- a directory full of `-2` through `-1000` is not a case worth silently
    ///     working around.
    ///   - exists: whether a path is taken. Injected so the search is testable without a filesystem, and
    ///     so the time-of-check-to-time-of-use window is visible at the call site rather than hidden
    ///     inside this function.
    public static func uniqueDestination(
        for path: String,
        limit: Int = 1000,
        exists: (String) -> Bool
    ) -> String? {
        guard exists(path) else { return path }
        let (stem, suffix) = split(path)
        for counter in 2...max(2, limit) {
            let candidate = "\(stem)-\(counter)\(suffix)"
            if !exists(candidate) { return candidate }
        }
        return nil
    }

    /// Splits a path into everything before the final extension, and the extension itself.
    ///
    /// A leading dot is not an extension: `.DS_Store` has no suffix, and treating it as one would turn a
    /// collision into `-2.DS_Store` with an empty stem.
    static func split(_ path: String) -> (stem: String, suffix: String) {
        let bytes = Array(path.utf8)
        guard let lastSlash = bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1 as Int? else {
            return (path, "")
        }
        let nameStart = lastSlash + 1
        guard nameStart < bytes.count else { return (path, "") }
        // Search only within the last component, and never at its first byte.
        var dot: Int?
        var index = nameStart + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: ".") { dot = index }
            index += 1
        }
        guard let dot else { return (path, "") }
        return (
            String(decoding: bytes[..<dot], as: UTF8.self),
            String(decoding: bytes[dot...], as: UTF8.self)
        )
    }
}
