import Foundation

/// Where a volume keeps its Trash. Injected so tests never touch the real one.
public protocol TrashRootResolving: Sendable {
    /// Every Trash directory that could hold items removed from `path`.
    func trashRoots(forItemAt path: String) -> [String]
}

/// The real answer, from Foundation and from the filesystem layout.
public struct SystemTrashRootResolver: TrashRootResolving, Sendable {
    private let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func trashRoots(forItemAt path: String) -> [String] {
        var roots: [String] = []
        let url = URL(filePath: path)
        // One API covers both cases: for a boot-volume path this yields ~/.Trash, and for another
        // volume it yields <volume>/.Trashes/<uid>.
        if let resolved = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: url,
            create: false
        ) {
            roots.append(resolved.path(percentEncoded: false))
        }
        // The parent too: other users' subdirectories live under <volume>/.Trashes, and a scan running
        // as one user still enumerates the directory.
        if let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume {
            roots.append(volume.path(percentEncoded: false) + "/.Trashes")
        }
        roots.append(home + "/.Trash")
        // The CLI's three quarantine directories all live under ~/.Trash, so excluding it covers every
        // one of them at once (`src/rav/commands/duplicate.py:115,457,700`).
        return roots
    }
}

/// A fixed set, for tests and for the selftest. Never reads the real Trash.
public struct FixedTrashRootResolver: TrashRootResolving, Sendable {
    public let roots: [String]

    public init(_ roots: [String]) {
        self.roots = roots
    }

    public func trashRoots(forItemAt path: String) -> [String] { roots }
}

/// Directories the walk must never enter, identified by inode rather than by path.
///
/// **Why identity and not a path prefix.** Three cases, and a string comparison fails all three:
///
/// 1. `~/.Trash` is itself a symlink to somewhere else. The walk never follows symlinks, so the
///    symlink is skipped for free -- but the *target* would be walked if it fell under the scan root.
///    Resolving to `(volume, inode)` prunes it under any path that reaches it.
/// 2. The same directory reached through a firmlink, which is how `/` and `/System/Volumes/Data`
///    both name the boot volume's contents.
/// 3. A relocated Trash on an external volume, whose path bears no resemblance to `~/.Trash`.
///
/// The lookup happens **once per directory**, at the moment the walk decides whether to descend --
/// never once per file. For 800,000 files in 40,000 directories that is 40,000 hash lookups on data
/// the enumerator already fetched.
///
/// `namesAtVolumeRoot` is the fallback for the case where identity cannot be read at all: a
/// `<volume>/.Trashes` that the current user has no permission to stat. Still one comparison per
/// directory, not per file.
public struct ExclusionSet: Sendable {
    public let identities: Set<FileIdentity>
    public let namesAtVolumeRoot: Set<String>
    /// The paths that were resolved, kept for diagnostics and for the selftest's reporting.
    public let resolvedPaths: [String]

    public static let defaultVolumeRootNames: Set<String> = [
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
    ]

    public init(
        identities: Set<FileIdentity> = [],
        namesAtVolumeRoot: Set<String> = ExclusionSet.defaultVolumeRootNames,
        resolvedPaths: [String] = []
    ) {
        self.identities = identities
        self.namesAtVolumeRoot = namesAtVolumeRoot
        self.resolvedPaths = resolvedPaths
    }

    /// Resolves a list of directory paths to identities.
    ///
    /// Paths that do not exist are dropped silently: a machine with no external volume mounted has no
    /// `<volume>/.Trashes`, and that is not a failure.
    ///
    /// Each path is resolved through its symlinks *before* its identity is read, which is what makes
    /// case 1 above work.
    public static func resolving(
        _ paths: [String],
        namesAtVolumeRoot: Set<String> = ExclusionSet.defaultVolumeRootNames
    ) -> ExclusionSet {
        var identities: Set<FileIdentity> = []
        var resolved: [String] = []
        for path in paths {
            // realpath(3), not Foundation: `resolvingSymlinksInPath` special-cases `/private` and would
            // leave `/var/...` untouched. See ``RealPath``.
            guard let target = RealPath.resolve(path) else { continue }
            guard
                let values = try? URL(filePath: target).resourceValues(
                    forKeys: [.volumeIdentifierKey, .fileIdentifierKey]
                ),
                let volume = OpaqueIdentifier.fold(values.volumeIdentifier),
                let inode = values.fileIdentifier
            else { continue }
            identities.insert(FileIdentity(volume: volume, inode: inode))
            resolved.append(target)
        }
        return ExclusionSet(
            identities: identities,
            namesAtVolumeRoot: namesAtVolumeRoot,
            resolvedPaths: resolved
        )
    }

    /// Everything to exclude for a scan of `root`: the Trash roots plus any configured quarantine.
    public static func forScan(
        of root: String,
        resolver: some TrashRootResolving,
        quarantineRoots: [String] = []
    ) -> ExclusionSet {
        resolving(resolver.trashRoots(forItemAt: root) + quarantineRoots)
    }

    /// Whether a directory with this identity is excluded. An unknown identity is not excluded.
    public func excludes(_ identity: FileIdentity?) -> Bool {
        guard let identity else { return false }
        return identities.contains(identity)
    }

    /// Whether a name is one of the volume-root stores that must be skipped even unstattable.
    public func excludesNameAtVolumeRoot(_ name: String) -> Bool {
        namesAtVolumeRoot.contains(name)
    }
}
