import Foundation

/// Recognises the names Finder and Windows give to a copy.
///
/// The pattern is the CLI's, transliterated character for character from
/// `src/rav/core/duplicate_review.py:15-38` and fed to `NSRegularExpression` with the same two options
/// Python uses (`IGNORECASE | VERBOSE` becomes `.caseInsensitive | .allowCommentsAndWhitespace`).
/// Reusing the text rather than hand-rolling the logic is deliberate: the two tools have to agree about
/// which file looks like a copy, and a subtly different `\s` or `\d` interpretation would make them
/// disagree only on the awkward names nobody thinks to test.
///
/// **One false positive is preserved on purpose.** The last alternative, `[ _-]\d+$`, matches any name
/// ending in a separator and digits -- so `IMG_1234` scores as a copy. That is wrong for camera output,
/// which is most of a photo library, but changing it would make the app prefer a different file than the
/// CLI for the same group. The test that covers it says in its name that it is deliberate.
public enum CopyNamePattern {
    /// The CLI's pattern, with one deliberate change.
    ///
    /// **The spaces inside the character classes are written `\x20`.** Reusing the text verbatim was the
    /// plan, and it was not enough: ICU strips whitespace *inside a character class* under
    /// `allowCommentsAndWhitespace`, while Python's `VERBOSE` keeps it. So `[ _-]\d+` became `[_-]\d+` and
    /// the port disagreed with the CLI on exactly the names that end in a space and digits -- `photo 1`,
    /// `photo copy 2`. Measured against the CLI's own `_copy_score`, not guessed.
    ///
    /// Note the two engines *agree* about the space in `\( ?copy\)?`: both strip it, so the `?` ends up
    /// applying to the opening paren and a bare `copy` suffix matches. That is why `photo.copy`, `copy` and
    /// even `xcopy` all score 1 in both tools -- surprising, but shared.
    static let source = """
        (?:
            ^copia\\s+de\\s+              # "Copia de X" — macOS Spanish prefix
            | ^copy\\s+of\\s+             # "Copy of X" — macOS English prefix
        )
        |
        (?:
            [\\x20_-]?
            (
                \\(\\d+\\)                 # (1), (2) — Mac/Windows
                | \\( ?copy\\)?           # (copy), ( copy) — Windows
                | -\\s*copy              # - Copy — Windows
                | \\s+copy               # " copy" — generic
                | _copy                  # _copy — generic
                | \\s+copia              # " copia" — Spanish
                | _copia                 # _copia — Spanish
                | [\\x20_-]\\d+              # _1, -1, space+1 — generic
            )
            $
        )
        """

    private static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: source,
        options: [.caseInsensitive, .allowCommentsAndWhitespace]
    )

    /// `1` when the stem looks like a copy, `0` otherwise. Lower means more likely the original.
    ///
    /// Ports `_copy_score`. Matched against the **stem** -- the filename with its last extension removed --
    /// exactly as Python's `Path.stem` gives it.
    public static func score(stem: String) -> Int {
        guard let regex else { return 0 }
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        return regex.firstMatch(in: stem, options: [], range: range) == nil ? 0 : 1
    }

    /// `1` when the file's name looks like a copy.
    public static func score(path: String) -> Int {
        score(stem: stem(of: path))
    }

    /// The last path component with its final extension removed, matching Python's `Path.stem`.
    ///
    /// A leading dot is not an extension: the stem of `.DS_Store` is `.DS_Store`.
    static func stem(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let bytes = Array(name.utf8)
        var dot: Int?
        var index = 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: ".") { dot = index }
            index += 1
        }
        guard let dot else { return name }
        return String(decoding: bytes[..<dot], as: UTF8.self)
    }
}

/// Picks which file in a group to keep.
///
/// Ports `_best_keep_index` (`src/rav/core/duplicate_review.py:55-57`): the lexicographic minimum of
/// `(copyScore, depthScore, index)`.
///
/// **Deeper wins**, which is the surprising half. `depthScore` is the *negative* depth below the scan
/// root, so a file three folders down beats one sitting loose at the top. The reasoning is that a file
/// somebody filed away is more likely the one they meant to keep, and a copy is more likely to have been
/// dropped at the root. It is a guess, but it is the CLI's guess, and the two tools proposing different
/// survivors for the same group would be worse than either guess being wrong.
public enum KeeperHeuristic {
    /// Negative depth below `root`, or `0` when the file is not under it.
    ///
    /// Ports `_depth_score`, including the `ValueError` fallback: Python's `relative_to` raises for a path
    /// outside the root, and the CLI scores that `0`.
    public static func depthScore(path: String, root: String) -> Int {
        guard let components = PathOrder.componentCount(of: path, under: root) else { return 0 }
        return -(components - 1)
    }

    /// The index of the file to keep.
    ///
    /// Returns `0` for an empty list rather than trapping: a group with no members cannot happen, and
    /// crashing over it would be a worse answer than a harmless index.
    public static func bestIndex(files: [String], root: String) -> Int {
        guard !files.isEmpty else { return 0 }
        var best = (copy: Int.max, depth: Int.max, index: 0)
        for (index, path) in files.enumerated() {
            let candidate = (
                copy: CopyNamePattern.score(path: path),
                depth: depthScore(path: path, root: root),
                index: index
            )
            if candidate < best { best = candidate }
        }
        return best.index
    }
}
