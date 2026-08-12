import Foundation

/// Fully resolves a path through `realpath(3)`.
///
/// Foundation's two candidates both refuse the case that matters here. `URL.resolvingSymlinksInPath()`
/// and `NSString.resolvingSymlinksInPath` special-case `/private`: they strip a leading `/private` and
/// will not add one, so neither turns `/var/folders/...` into `/private/var/folders/...`. Verified on
/// this SDK -- both return the input unchanged, while `realpath(3)` returns the resolved form.
///
/// That gap is not academic. `FileManager.enumerator` resolves the root it is given, so a walk of
/// `/var/x` yields paths under `/private/var/x`. Recognising the resolved prefix is the only way to
/// swap it back for the one the caller asked for, and comparing against a Foundation-"resolved" prefix
/// would never match.
public enum RealPath {
    /// The fully resolved path, or `nil` when the path does not exist.
    ///
    /// `realpath` requires every component to exist, which is why this returns an optional rather than
    /// falling back to the input: a caller that cannot tell "resolved" from "does not exist" would
    /// compare against a prefix that never matches and silently stop rewriting anything.
    public static func resolve(_ path: String) -> String? {
        path.withCString { pointer in
            guard let resolved = realpath(pointer, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// The resolved path, falling back to the input with trailing slashes trimmed.
    public static func resolveOrSelf(_ path: String) -> String {
        resolve(path) ?? trimmingTrailingSlashes(path)
    }

    public static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}
