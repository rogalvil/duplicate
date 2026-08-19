import Foundation

/// What one walk found, and what it could not see.
public struct WalkResult: Sendable {
    /// Every accepted file, in enumeration order.
    public let entries: [FileEntry]
    /// Directories the walk could not read, most often because macOS protects them.
    ///
    /// Reported, not swallowed. A scan of `$HOME` without Full Disk Access reads most of it and gets
    /// `EPERM` on `~/Library/Mail`, `Messages`, `Safari` and the Photos library. "No duplicates found"
    /// after skipping forty directories is a different answer from "no duplicates found", and the only
    /// honest UI is one that says which it was.
    public let inaccessiblePaths: [String]
    /// How many entries each rule dropped.
    public let skipped: [SkipReason: Int]
    /// How many directory entries were visited, accepted or not.
    public let visitedCount: Int

    public init(
        entries: [FileEntry],
        inaccessiblePaths: [String] = [],
        skipped: [SkipReason: Int] = [:],
        visitedCount: Int = 0
    ) {
        self.entries = entries
        self.inaccessiblePaths = inaccessiblePaths
        self.skipped = skipped
        self.visitedCount = visitedCount
    }

    /// Total dropped, across every reason.
    public var skippedCount: Int { skipped.values.reduce(0, +) }
}

/// Walks a directory tree. Injected so downstream stages can be driven by a fake.
///
/// The protocol exists for the stages *after* the walk, not to mock the walk away: the real walker is
/// covered by tests that build real trees in a temporary directory, because its rules are exactly the
/// part that has to match a filesystem's behaviour.
public protocol DirectoryEnumerating: Sendable {
    func walk(root: String, policy: ScanPolicy, exclusions: ExclusionSet) throws -> WalkResult
}

/// The `FileManager.enumerator` implementation.
///
/// **And the only one, because the measurement said so.** The plan held open a hand-written `AttrListWalker` --
/// roughly 400 lines of `getattrlistbulk` and pointer arithmetic -- to be written *if* Foundation turned out to
/// be paying per-file `stat` calls the way the CLI does. Counted with `fs_usage` over a real 3,421-file tree:
///
/// | | per file |
/// |---|---|
/// | `getattrlistbulk` | 0.085 (292 calls, ~11.7 entries each) |
/// | the whole `stat` family | **0.12** |
/// | the CLI in Python, for comparison | 3-4 |
///
/// The rule the plan wrote for this was "if the ratio is under 1.2, `FoundationWalker` stays". It is 0.12, ten
/// times under. So the rewrite is rejected on evidence, and this comment exists so nobody reopens it on a hunch.
public struct FileManagerWalker: DirectoryEnumerating, Sendable {
    /// The keys fetched in one batch per entry.
    ///
    /// Prefetched values are cached on each `URL` the enumerator hands back, so reading them costs no
    /// syscall. The CLI pays three to four stat-family calls per file instead: an `lstat` from
    /// `is_symlink()` and a `stat` from `is_file()` (`src/rav/core/duplicates.py:203`), another `stat`
    /// from `.stat()` (`:65`), and an `lstat` per directory in `_filter_dirnames` (`:198`).
    ///
    /// Volume *traits* are deliberately absent from this list. They resolve through `statfs` and disk
    /// arbitration rather than the directory batch, so asking for them per entry is a classic
    /// self-inflicted slowdown. `volumeIdentifier` is the exception and is cheap: it comes from the
    /// same attribute fetch.
    public static let entryKeys: [URLResourceKey] = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .isPackageKey,
        .nameKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .fileIdentifierKey,
        .volumeIdentifierKey,
        .linkCountKey,
        .fileContentIdentifierKey,
        .generationIdentifierKey,
    ]

    public init() {}

    public func walk(
        root: String,
        policy: ScanPolicy,
        exclusions: ExclusionSet = ExclusionSet()
    ) throws -> WalkResult {
        // Checked before enumerating, because `enumerator(at:)` returns a perfectly good enumerator for
        // a path that does not exist and reports the problem only through the error handler -- which
        // would make a typo'd root look like an empty one.
        switch AccessProbe.probe(path: root) {
        case .readable, .empty: break
        case .missing, .notADirectory, .denied: throw WalkError.rootNotEnumerable(root)
        }

        let filter = WalkFilter(policy: policy, exclusions: exclusions)
        // Trailing slashes are dropped so the prefix arithmetic below joins cleanly.
        let requestedRoot = Self.trimmingTrailingSlashes(root)
        let rootURL = URL(filePath: requestedRoot)

        // `FileManager.enumerator` resolves symbolic links in the root, so a scan of `/var/x` yields
        // paths under `/private/var/x`. Python's `os.walk` does not: it string-joins the root it was
        // given. Recording the resolved form would be a real interop break, not a cosmetic one -- the
        // CLI matches the kept paths in a decisions file back to a group **by string equality**
        // (`src/rav/core/duplicate_review.py:76-83`), so a review done in the app would silently fail to
        // apply in the CLI for any root containing a symlinked component: `/tmp`, `/etc`, `/var`.
        //
        // So the resolved prefix is swapped back for the requested one on every entry. It has to come
        // from `realpath(3)`: Foundation's `resolvingSymlinksInPath` special-cases `/private` and
        // returns `/var/...` unchanged, so comparing against it would never match and the rewrite would
        // silently do nothing. See ``RealPath``.
        let resolvedRoot = RealPath.resolveOrSelf(requestedRoot)

        // The root's own volume, so a mount point crossed further down can be recognised.
        let rootVolume = OpaqueIdentifier.fold(
            try? rootURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        )

        var inaccessible: [String] = []
        var skipped: [SkipReason: Int] = [:]
        var entries: [FileEntry] = []
        var visited = 0
        // Guards against a directory reached twice: the `/` and `/System/Volumes/Data` firmlink pair,
        // and any residual symlink following. The same key the hardlink partition needs later.
        var seenDirectories: Set<FileIdentity> = []

        guard
            let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: Self.entryKeys,
                options: [],
                errorHandler: { url, _ in
                    // **Installing a handler at all is what matters here, not what it returns.**
                    //
                    // Foundation documents `false` as stopping the enumeration. Measured on this SDK it
                    // does not: an EACCES on a subdirectory yields the same file list whether the
                    // handler returns `true` or `false`, and the same list again with no handler at all.
                    // `true` is kept because it is the documented contract, costs nothing, and is what a
                    // future OS would honour -- not because it was observed to change anything.
                    //
                    // What the handler does buy is the only thing the app can report. With
                    // `errorHandler: nil` the walk returns the identical files and the caller learns
                    // *nothing*: no count, no path, no signal. "No duplicates found" would then be
                    // indistinguishable from "could not look inside 47 protected directories", and the
                    // user would have no way to tell which answer they got.
                    inaccessible.append(url.path(percentEncoded: false))
                    return true
                }
            )
        else {
            throw WalkError.rootNotEnumerable(root)
        }

        while let url = enumerator.nextObject() as? URL {
            visited += 1
            let path = Self.restoringRequestedPrefix(
                url.path(percentEncoded: false),
                resolvedRoot: resolvedRoot,
                requestedRoot: requestedRoot
            )
            // Cheap and correct: these come from the prefetched batch on this specific URL instance.
            // Never reuse a URL across reads -- URL caches resource values, so a second read of the
            // same instance returns what the first one saw.
            guard let values = try? url.resourceValues(forKeys: Set(Self.entryKeys)) else {
                inaccessible.append(path)
                continue
            }

            let volume = OpaqueIdentifier.fold(values.volumeIdentifier)
            let identity = zip1(volume, values.fileIdentifier).map(FileIdentity.init)
            let candidate = WalkCandidate(
                name: values.name ?? url.lastPathComponent,
                isDirectory: values.isDirectory ?? false,
                isSymbolicLink: values.isSymbolicLink ?? false,
                isRegularFile: values.isRegularFile ?? false,
                isPackage: values.isPackage ?? false,
                isHidden: false,
                size: values.fileSize.map(Int64.init),
                identity: identity,
                isOnForeignVolume: rootVolume != nil && volume != nil && rootVolume != volume
            )

            if candidate.isDirectory, !candidate.isSymbolicLink {
                if let identity, !seenDirectories.insert(identity).inserted {
                    enumerator.skipDescendants()
                    continue
                }
                if let reason = filter.reasonToPrune(candidate) {
                    skipped[reason, default: 0] += 1
                    enumerator.skipDescendants()
                }
                continue
            }

            if let reason = filter.reasonToSkip(candidate) {
                skipped[reason, default: 0] += 1
                continue
            }

            entries.append(
                FileEntry(
                    path: path,
                    size: candidate.size ?? 0,
                    identity: identity,
                    contentIdentifier: values.fileContentIdentifier,
                    linkCount: values.linkCount,
                    generation: OpaqueIdentifier.fold(values.generationIdentifier),
                    modifiedNanoseconds: values.contentModificationDate.map {
                        Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded())
                    }
                )
            )
        }

        return WalkResult(
            entries: entries,
            inaccessiblePaths: inaccessible,
            skipped: skipped,
            visitedCount: visited
        )
    }

    /// Combines two optionals, or `nil` if either is missing.
    private func zip1<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    /// Rewrites a resolved path so it reads under the root the caller asked for.
    ///
    /// A path that does not start with the resolved prefix is returned untouched. That should not
    /// happen, and silently mangling it would be worse than reporting it as it came.
    static func restoringRequestedPrefix(
        _ path: String,
        resolvedRoot: String,
        requestedRoot: String
    ) -> String {
        guard resolvedRoot != requestedRoot else { return path }
        guard path.hasPrefix(resolvedRoot) else { return path }
        return requestedRoot + path.dropFirst(resolvedRoot.count)
    }

    static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }
}

public enum WalkError: Error, Equatable, Sendable {
    /// The root could not be enumerated at all: it does not exist, or is not a directory.
    case rootNotEnumerable(String)
}
