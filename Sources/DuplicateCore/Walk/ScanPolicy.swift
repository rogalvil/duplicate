/// Why the walk did not keep something.
///
/// Counted and reported rather than silently dropped. A scan that says "no duplicates" after skipping
/// forty protected directories is not the same answer as a scan that looked everywhere, and the user
/// has to be able to tell them apart.
public enum SkipReason: String, CaseIterable, Sendable, Hashable {
    /// A build or tooling directory: `.git`, `node_modules`, and friends.
    case ignoredDirectory
    /// Hidden, and hidden things are excluded by default.
    case hidden
    /// A well-known noise filename such as `.DS_Store`.
    case noise
    /// A symbolic link. Never followed and never hashed: it has no content of its own.
    case symbolicLink
    /// A bundle such as `.app` or `.photoslibrary`.
    case package
    /// Below the minimum size.
    case tooSmall
    /// Not a regular file: a socket, a fifo, a device node.
    case notRegularFile
    /// Inside a Trash or quarantine root.
    case excludedRoot
    /// On a different volume, and the walk does not cross mount points.
    case otherVolume
}

/// What to do with a bundle directory.
public enum PackageHandling: Sendable {
    /// Treat it as an ordinary directory and walk into it, which is what the CLI does.
    case descend
    /// Skip the whole bundle.
    case skipEntirely
}

/// The knobs that decide what a walk keeps.
///
/// Separated from the enumerator so the decisions can be tested without a filesystem, and so the two
/// enumerator implementations cannot drift in their skip rules.
public struct ScanPolicy: Sendable {
    /// Directories dropped wherever they appear.
    ///
    /// Seeded from `DEFAULT_IGNORE_DIRS` (`src/rav/core/duplicates.py:17`) plus the macOS metadata
    /// stores, which are large, uninteresting, and full of byte-identical files.
    public var ignoredDirectoryNames: Set<String>

    /// Filenames dropped even when hidden files are included.
    ///
    /// `.DS_Store` is the reason this exists. Finder writes one per folder, they are frequently
    /// byte-identical, and a scan of a home directory can turn up a single group with four hundred
    /// members -- which buries every real finding under it. `Icon\r` is Finder's custom-icon file and
    /// `._*` are AppleDouble sidecars written onto non-APFS volumes.
    public var noiseFileNames: Set<String>

    /// Whether to descend into directories whose name starts with a dot.
    public var includesHiddenDirectories: Bool

    /// Whether to keep files whose name starts with a dot.
    ///
    /// **A divergence from the CLI, on purpose.** `iter_files` has no hidden-file filter at all
    /// (`src/rav/core/duplicates.py:193-205`), so the CLI reports the `.DS_Store` groups described
    /// above. Turning this on restores the CLI's behaviour exactly.
    public var includesHiddenFiles: Bool

    /// Smallest file worth considering. The CLI's default of 1 excludes zero-byte files.
    public var minimumSize: Int64

    /// What to do with `.app`, `.photoslibrary`, `.fcpbundle` and the like.
    ///
    /// **A divergence from the CLI, on purpose.** Python descends into everything. For a tool that
    /// moves files to the Trash that is a safety defect rather than fidelity: a `.photoslibrary`
    /// holds thousands of internally-referenced derivatives that produce enormous spurious groups,
    /// and pulling one file out of a bundle corrupts it silently.
    public var packageHandling: PackageHandling

    /// Whether to walk past a mount point.
    ///
    /// **A divergence from the CLI, on purpose.** `os.walk` crosses mount points. Descending into a
    /// mounted Time Machine volume, a network share, or a `.sparsebundle` that happens to sit under
    /// the scan root is a catastrophe for a duplicate finder, so this is opt-in.
    public var crossesMountPoints: Bool

    public static let defaultIgnoredDirectories: Set<String> = [
        // From the CLI.
        ".git", ".venv", "__pycache__", "node_modules",
        // macOS metadata stores: large, uninteresting, and full of identical files.
        ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
        ".MobileBackups", "Backups.backupdb",
    ]

    public static let defaultNoiseFiles: Set<String> = [
        ".DS_Store", "Thumbs.db", "desktop.ini", ".localized", "Icon\r",
    ]

    public init(
        ignoredDirectoryNames: Set<String> = ScanPolicy.defaultIgnoredDirectories,
        noiseFileNames: Set<String> = ScanPolicy.defaultNoiseFiles,
        includesHiddenDirectories: Bool = false,
        includesHiddenFiles: Bool = false,
        minimumSize: Int64 = 1,
        packageHandling: PackageHandling = .skipEntirely,
        crossesMountPoints: Bool = false
    ) {
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.noiseFileNames = noiseFileNames
        self.includesHiddenDirectories = includesHiddenDirectories
        self.includesHiddenFiles = includesHiddenFiles
        self.minimumSize = minimumSize
        self.packageHandling = packageHandling
        self.crossesMountPoints = crossesMountPoints
    }

    /// The policy that reproduces `rav duplicate`'s behaviour, divergences and all.
    ///
    /// Exists so the two tools can be compared on the same tree without arguing about which
    /// difference came from which change.
    public static let cliCompatible = ScanPolicy(
        ignoredDirectoryNames: [".git", ".venv", "__pycache__", "node_modules"],
        noiseFileNames: [],
        includesHiddenDirectories: true,
        includesHiddenFiles: true,
        minimumSize: 1,
        packageHandling: .descend,
        crossesMountPoints: true
    )
}
