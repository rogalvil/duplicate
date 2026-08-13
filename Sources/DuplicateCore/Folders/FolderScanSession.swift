import Foundation

/// Runs one folder-similarity scan end to end.
///
/// **This detector hashes every file, and that is the difference that matters.** The exact-duplicate scan
/// hashes only files whose size collides with another's -- 244 of 10,506 in one measured tree, 986 of 15,242
/// in another. A folder fingerprint needs a digest for *every* file, so there is no size bucket to hide
/// behind and the hash cache stops being an optimisation and becomes the difference between minutes and
/// seconds on a second run.
public struct FolderScanSession: Sendable {

    public struct Request: Sendable {
        public var root: String
        /// Dice threshold. The CLI's default.
        public var threshold: Double
        public var policy: ScanPolicy
        public var concurrency: Int?
        public var usesCache: Bool

        public init(
            root: String,
            threshold: Double = 0.9,
            policy: ScanPolicy = ScanPolicy(),
            concurrency: Int? = nil,
            usesCache: Bool = true
        ) {
            self.root = root
            self.threshold = threshold
            self.policy = policy
            self.concurrency = concurrency
            self.usesCache = usesCache
        }
    }

    public struct Result: Sendable {
        public let scan: FolderScan
        /// Files that could not be hashed. Skipped, not fatal.
        public let unreadable: [String]
        /// Directories the walk could not enter.
        public let inaccessible: [String]
        public let cacheHits: Int
        /// `(digest, basename)` classes too large to enumerate, named so the UI can warn.
        public let truncated: [FolderSimilarity.TruncatedClass]
        public let savedPath: String?
        public let saveFailure: String?
        /// How many directories were compared, and how many pairs survived to an exact comparison.
        public let folderCount: Int
        public let examinedPairs: Int
    }

    private let store: ScanStore
    private let walker: any DirectoryEnumerating
    private let hasher: any FileHashing
    private let trashResolver: any TrashRootResolving
    private let cacheURL: URL?

    public init(
        store: ScanStore = ScanStore(),
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: any FileHashing = ContentHasher(),
        trashResolver: any TrashRootResolving = SystemTrashRootResolver(),
        cacheURL: URL? = nil
    ) {
        self.store = store
        self.walker = walker
        self.hasher = hasher
        self.trashResolver = trashResolver
        self.cacheURL = cacheURL
    }

    /// Walks, hashes everything, compares folders, saves.
    ///
    /// Saving is last and a failure to save is reported rather than thrown, for the same reason as the exact
    /// scan: a finished scan of a large tree must not be discarded because the state directory was
    /// read-only.
    public func run(
        _ request: Request,
        instant: ScanIdentifier.Instant,
        progress: ProgressCounters = ProgressCounters()
    ) async throws -> Result {
        progress.setPhase(.indexing)
        let exclusions = ExclusionSet.forScan(of: request.root, resolver: trashResolver)
        let walk = try walker.walk(
            root: request.root, policy: request.policy, exclusions: exclusions)
        try Task.checkCancellation()

        let cache = request.usesCache ? HashCache(url: cacheURL ?? HashCache.defaultURL()) : nil
        await cache?.load()

        // **Every file, not a bucket.** `setCandidates` is the whole walk here, so the progress bar means
        // what it says instead of jumping to 100% and sitting there.
        progress.setPhase(.hashing)
        progress.setCandidates(walk.entries.count)

        var treeFiles: [TreeFile] = []
        treeFiles.reserveCapacity(walk.entries.count)
        var unreadable: [String] = []
        var hits = 0

        for entry in walk.entries {
            try Task.checkCancellation()
            if let cache, let known = await cache.digest(for: entry) {
                hits += 1
                progress.noteCacheHit()
                progress.noteHashed(path: entry.path, bytes: 0)
                treeFiles.append(TreeFile(path: entry.path, digest: known))
                continue
            }
            guard let result = try? hasher.fullDigest(atPath: entry.path) else {
                unreadable.append(entry.path)
                continue
            }
            if let cache { await cache.store(result.digest, for: entry) }
            progress.noteHashed(path: entry.path, bytes: result.byteCount)
            treeFiles.append(TreeFile(path: entry.path, digest: result.digest))
        }
        if let cache { _ = try? await cache.persist() }

        progress.setPhase(.grouping)
        let tree = DirectoryTree.build(root: request.root, files: treeFiles)
        let found = try FolderSimilarity.find(in: tree, threshold: request.threshold)
        progress.setPhase(.finished)

        let scan = FolderScan(
            scanID: instant.identifier,
            root: request.root,
            createdAt: instant.timestamp,
            threshold: request.threshold,
            pairs: found.pairs
        )

        var savedPath: String?
        var saveFailure: String?
        do {
            savedPath = try store.save(scan)
        } catch {
            saveFailure = String(describing: error)
        }

        return Result(
            scan: scan,
            unreadable: unreadable,
            inaccessible: walk.inaccessiblePaths,
            cacheHits: hits,
            truncated: found.truncated,
            savedPath: savedPath,
            saveFailure: saveFailure,
            // The root is not comparable, matching the CLI.
            folderCount: tree.comparableIndices.count,
            examinedPairs: found.examinedPairs
        )
    }

    /// Scans at `date`, resolving a free identifier first.
    ///
    /// Same reasoning as the exact scan: the identifier decides the filename and the instant decides what is
    /// stamped inside, so they come from one value.
    public func run(
        _ request: Request,
        at date: Date,
        progress: ProgressCounters = ProgressCounters()
    ) async throws -> Result {
        let taken = Set(store.identifiers(in: .folderScans))
        var instant = ScanIdentifier.Instant(date)
        for _ in 0..<1000 {
            if !taken.contains(instant.identifier) { break }
            instant = instant.nextMicrosecond
        }
        return try await run(request, instant: instant, progress: progress)
    }
}
