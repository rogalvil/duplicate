/// What the walk saw about one directory entry, with nothing filesystem-shaped attached.
///
/// The enumerator fills this in from prefetched resource values; the decision functions below read
/// only this. That split is what makes the skip rules testable without building a tree, and what
/// keeps two enumerator implementations from drifting apart in their behaviour.
public struct WalkCandidate: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let isRegularFile: Bool
    public let isPackage: Bool
    public let isHidden: Bool
    public let size: Int64?
    /// Volume and inode, when the volume reports them.
    public let identity: FileIdentity?
    /// Whether this entry sits on a different volume than the scan root.
    public let isOnForeignVolume: Bool

    public init(
        name: String,
        isDirectory: Bool = false,
        isSymbolicLink: Bool = false,
        isRegularFile: Bool = false,
        isPackage: Bool = false,
        isHidden: Bool = false,
        size: Int64? = nil,
        identity: FileIdentity? = nil,
        isOnForeignVolume: Bool = false
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isRegularFile = isRegularFile
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.identity = identity
        self.isOnForeignVolume = isOnForeignVolume
    }
}

/// The skip rules, as pure functions.
public struct WalkFilter: Sendable {
    public let policy: ScanPolicy
    public let exclusions: ExclusionSet

    public init(policy: ScanPolicy, exclusions: ExclusionSet = ExclusionSet()) {
        self.policy = policy
        self.exclusions = exclusions
    }

    /// Why this directory should not be descended into, or `nil` to descend.
    ///
    /// Ordered so the cheapest and most decisive checks come first, and so the reported reason is the
    /// most informative one: a `.git` inside the Trash reports as an excluded root, not as an ignored
    /// directory, because that is the fact the user needs.
    public func reasonToPrune(_ candidate: WalkCandidate) -> SkipReason? {
        // Identity first: it is one Set lookup on data already fetched, and it catches a Trash
        // reached through a symlink or a firmlink that no path comparison would recognise.
        if exclusions.excludes(candidate.identity) { return .excludedRoot }
        if exclusions.excludesNameAtVolumeRoot(candidate.name) { return .excludedRoot }
        // A symlinked directory is never followed. Matching followlinks=False, and also the only
        // defence against a cycle that would otherwise never terminate.
        if candidate.isSymbolicLink { return .symbolicLink }
        if candidate.isOnForeignVolume, !policy.crossesMountPoints { return .otherVolume }
        if policy.ignoredDirectoryNames.contains(candidate.name) { return .ignoredDirectory }
        if candidate.isPackage, policy.packageHandling == .skipEntirely { return .package }
        if !policy.includesHiddenDirectories, Self.isDotted(candidate.name) { return .hidden }
        return nil
    }

    /// Why this file should not be kept, or `nil` to keep it.
    public func reasonToSkip(_ candidate: WalkCandidate) -> SkipReason? {
        if candidate.isSymbolicLink { return .symbolicLink }
        if !candidate.isRegularFile { return .notRegularFile }
        if policy.noiseFileNames.contains(candidate.name) { return .noise }
        if !policy.includesHiddenFiles, Self.isDotted(candidate.name) { return .hidden }
        if let size = candidate.size, size < policy.minimumSize { return .tooSmall }
        return nil
    }

    /// Whether a name is hidden by the CLI's rule: it starts with a dot.
    ///
    /// Not `NSURLIsHiddenKey`. That key also reports files carrying the `UF_HIDDEN` flag and entries
    /// listed in a `.hidden` file, which is a different -- larger -- set than the CLI's
    /// `name.startswith(".")`. Using it would silently drop files the CLI keeps.
    static func isDotted(_ name: String) -> Bool {
        name.hasPrefix(".")
    }
}

extension PackageHandling: Equatable {}
