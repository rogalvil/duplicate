import Foundation
import Testing

@testable import DuplicateCore

@Suite("RealPath")
struct RealPathTests {
    @Test("Resolves a symlinked prefix that Foundation refuses to resolve")
    func resolvesWhereFoundationWillNot() throws {
        // The reason this type exists. Both Foundation APIs special-case /private: they strip a leading
        // /private and will not add one, so neither turns /var/folders/... into /private/var/folders/...
        // Comparing against a Foundation-"resolved" prefix would never match, and the walker's prefix
        // rewrite would silently do nothing.
        let temporary = RealPath.trimmingTrailingSlashes(NSTemporaryDirectory())
        let resolved = try #require(RealPath.resolve(temporary))

        #expect(resolved != temporary, "this Mac's temp directory is not behind a symlink")
        #expect(resolved.hasPrefix("/private/var"))
        #expect(
            URL(filePath: temporary).resolvingSymlinksInPath().path(percentEncoded: false)
                == temporary)
        #expect((temporary as NSString).resolvingSymlinksInPath == temporary)
    }

    @Test("Returns nil for a path that does not exist")
    func returnsNilForMissingPath() {
        // realpath requires every component to exist. Falling back to the input would leave a caller
        // unable to tell "resolved" from "does not exist", and it would then compare against a prefix
        // that never matches.
        #expect(RealPath.resolve("/nonexistent-\(UUID().uuidString)/deeper") == nil)
    }

    @Test("resolveOrSelf falls back to the trimmed input")
    func resolveOrSelfFallsBack() {
        let missing = "/nonexistent-\(UUID().uuidString)/"
        #expect(RealPath.resolveOrSelf(missing) == String(missing.dropLast()))
    }

    @Test("Trims trailing slashes but never the root itself")
    func trimsTrailingSlashes() {
        #expect(RealPath.trimmingTrailingSlashes("/a/b/") == "/a/b")
        #expect(RealPath.trimmingTrailingSlashes("/a/b//") == "/a/b")
        #expect(RealPath.trimmingTrailingSlashes("/a/b") == "/a/b")
        #expect(RealPath.trimmingTrailingSlashes("/") == "/")
    }

    @Test("Restores the requested prefix, and leaves an unrelated path alone")
    func restoresRequestedPrefix() {
        // The rewrite the walker applies to every entry.
        #expect(
            FileManagerWalker.restoringRequestedPrefix(
                "/private/var/x/sub/f.txt",
                resolvedRoot: "/private/var/x",
                requestedRoot: "/var/x"
            ) == "/var/x/sub/f.txt"
        )
        // Already identical: nothing to do.
        #expect(
            FileManagerWalker.restoringRequestedPrefix(
                "/Users/x/f.txt",
                resolvedRoot: "/Users/x",
                requestedRoot: "/Users/x"
            ) == "/Users/x/f.txt"
        )
        // Does not start with the resolved prefix: returned untouched rather than mangled. Should not
        // happen, and silently rewriting it would be worse than reporting it as it came.
        #expect(
            FileManagerWalker.restoringRequestedPrefix(
                "/elsewhere/f.txt",
                resolvedRoot: "/private/var/x",
                requestedRoot: "/var/x"
            ) == "/elsewhere/f.txt"
        )
    }
}
