import Foundation

/// Byte-wise ordering and equality for filesystem paths.
///
/// This exists because Swift's `String` comparison is the wrong tool for paths, in two ways that
/// both fail silently and both matter for compatibility with the `rav duplicate` CLI.
///
/// **Ordering.** The CLI stores the files of a group as `tuple(sorted(duplicate_paths))`
/// (`src/rav/core/duplicates.py:92`), sorting `pathlib.Path` objects. `PurePath.__lt__` compares
/// the path string, and Python compares strings by Unicode code point. Swift's `<` on `String`
/// compares under canonical equivalence, which is *not* code-point order. Since UTF-8 byte order
/// is code-point order, comparing the raw bytes reproduces Python exactly.
///
/// **Equality.** Swift considers the precomposed "á" (U+00E1) equal to the decomposed "á"
/// (U+0061 U+0301); Python does not. APFS preserves whatever bytes each writer used, and both
/// forms occur inside a single real scan file in this user's state directory. Using `String` as a
/// dictionary key would collapse two paths the CLI treats as distinct, and lose one of their
/// review decisions. A case-sensitive APFS volume compounds it: `Foo.jpg` and `foo.jpg` are two
/// files there and one file on the boot volume.
///
/// The rule that follows, and that every caller must honour: the canonical identity of a path is
/// the raw UTF-8 byte sequence the walker produced. Never normalise it, never round-trip it
/// through `standardizedFileURL`, never resolve its symlinks.
public enum PathOrder {
    /// Compares two paths by their UTF-8 bytes.
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        compare(bytes: lhs.utf8, rhs.utf8)
    }

    /// Whether `lhs` sorts before `rhs`. Suitable as a `sort(by:)` predicate.
    public static func lessThan(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// Whether two paths are the same sequence of bytes.
    ///
    /// Use this instead of `==` wherever a path decides which file gets moved to the Trash.
    public static func equal(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    /// Compares any two byte sequences lexicographically.
    ///
    /// Generic over the sequence so the same comparator serves both `String.UTF8View` and the
    /// slices of the byte arena the scanner will use for its paths.
    public static func compare<L: Sequence<UInt8>, R: Sequence<UInt8>>(
        bytes lhs: L,
        _ rhs: R
    ) -> ComparisonResult {
        var left = lhs.makeIterator()
        var right = rhs.makeIterator()
        while true {
            let leftByte = left.next()
            let rightByte = right.next()
            switch (leftByte, rightByte) {
            case (nil, nil):
                return .orderedSame
            case (nil, .some):
                return .orderedAscending
            case (.some, nil):
                return .orderedDescending
            case (.some(let leftValue), .some(let rightValue)):
                if leftValue != rightValue {
                    return leftValue < rightValue ? .orderedAscending : .orderedDescending
                }
            }
        }
    }

    /// Sorts paths the way the CLI does.
    public static func sorted(_ paths: [String]) -> [String] {
        paths.sorted(by: lessThan)
    }

    /// The number of path components `path` has below `root`, or `nil` when it is not under it.
    ///
    /// Byte-wise on purpose, and it requires a separator at the boundary so that `/a/bc` is not
    /// treated as living under `/a/b`. That off-by-one is a one-line mistake that silently
    /// changes which file the keeper heuristic prefers.
    public static func componentCount(of path: String, under root: String) -> Int? {
        var rootBytes = Array(root.utf8)
        while rootBytes.count > 1, rootBytes.last == UInt8(ascii: "/") {
            rootBytes.removeLast()
        }
        let pathBytes = Array(path.utf8)
        guard pathBytes.count > rootBytes.count else { return nil }
        guard Array(pathBytes[..<rootBytes.count]) == rootBytes else { return nil }
        guard pathBytes[rootBytes.count] == UInt8(ascii: "/") else { return nil }

        var components = 0
        var index = rootBytes.count
        var inComponent = false
        while index < pathBytes.count {
            if pathBytes[index] == UInt8(ascii: "/") {
                inComponent = false
            } else if !inComponent {
                inComponent = true
                components += 1
            }
            index += 1
        }
        return components
    }
}
