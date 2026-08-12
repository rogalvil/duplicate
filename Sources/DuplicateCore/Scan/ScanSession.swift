import Foundation

/// Runs one scan end to end: pick an identifier, walk, hash, group, save.
///
/// The seam that was missing. ``DuplicateFinder`` produces a scan and ``ScanStore`` writes one, but
/// deciding *which* identifier, *which* exclusions, *whether* to use the shared hash cache and *when* the
/// document reaches disk are decisions with consequences, and they were spread between a test and a
/// selftest instead of living anywhere.
///
/// In Core because every one of those decisions is a value, and because the window must not be the place
/// that knows them. A scan started from a window and a scan started from a future command line have to
/// produce the same document.
public struct ScanSession: Sendable {

    /// What the caller wants scanned, and how.
    public struct Request: Sendable {
        public var root: String
        public var policy: ScanPolicy
        /// `nil` asks ``IOConcurrencyPolicy`` for the root's volume, which is almost always right.
        public var concurrency: Int?
        /// Whether to consult and update the shared hash cache.
        ///
        /// On by default. Off is for measuring: the cache turns a cold 133 s scan of this user's external
        /// drive into a warm 4 s one, so a benchmark that leaves it on measures the cache, not the scanner.
        public var usesCache: Bool

        public init(
            root: String,
            policy: ScanPolicy = ScanPolicy(),
            concurrency: Int? = nil,
            usesCache: Bool = true
        ) {
            self.root = root
            self.policy = policy
            self.concurrency = concurrency
            self.usesCache = usesCache
        }
    }

    /// What happened, including where the document landed.
    public struct Result: Sendable {
        public let outcome: DuplicateFinder.Outcome
        /// Where the scan was written, or `nil` when it was not.
        public let savedPath: String?
        /// Why it was not written, when it was not.
        public let saveFailure: String?

        public var scan: DuplicateScan { outcome.scan }
    }

    private let store: ScanStore
    private let finder: DuplicateFinder
    private let trashResolver: any TrashRootResolving
    private let cacheURL: URL?

    /// - Parameters:
    ///   - trashResolver: injected so a test can point the Trash exclusion at a directory it made, rather
    ///     than needing the real `~/.Trash` to be involved.
    ///   - cacheURL: `nil` uses the default under `~/Library/Caches`. A test passes a temp path so it
    ///     never touches the real cache -- which would make the next real scan look warm for the wrong
    ///     reason.
    public init(
        store: ScanStore = ScanStore(),
        finder: DuplicateFinder = DuplicateFinder(),
        trashResolver: any TrashRootResolving = SystemTrashRootResolver(),
        cacheURL: URL? = nil
    ) {
        self.store = store
        self.finder = finder
        self.trashResolver = trashResolver
        self.cacheURL = cacheURL
    }

    /// Scans and saves.
    ///
    /// **Saving is the last thing that happens, and a failure to save is reported rather than thrown.** A
    /// scan of 800,000 files that finished successfully must not be discarded because the state directory
    /// was read-only: the caller can still review it in memory, and the report says the document is not on
    /// disk. Throwing here would turn a recoverable problem into twenty minutes of lost work.
    ///
    /// Cancellation propagates: ``DuplicateFinder`` checks at four points, and nothing is written until it
    /// returns, so a cancelled scan leaves no document behind. The hash cache keeps whatever it learned,
    /// deliberately -- those are true facts, and discarding them would make the next attempt pay the full
    /// price again.
    public func run(
        _ request: Request,
        instant: ScanIdentifier.Instant,
        progress: ProgressCounters = ProgressCounters()
    ) async throws -> Result {
        let cache = request.usesCache ? HashCache(url: cacheURL ?? HashCache.defaultURL()) : nil
        await cache?.load()

        // The Trash and the CLI's three quarantine roots are excluded by **identity**, so a root reached
        // through a symlink is pruned too. This is the CLI's live bug: `rav duplicate ~` twice
        // re-discovers everything the first run just quarantined, and offers to quarantine it again.
        let exclusions = ExclusionSet.forScan(of: request.root, resolver: trashResolver)

        let configuration = DuplicateFinder.Configuration(
            policy: request.policy,
            exclusions: exclusions,
            concurrency: request.concurrency,
            cache: cache
        )

        let outcome = try await finder.find(
            root: request.root,
            instant: instant,
            configuration: configuration,
            progress: progress
        )
        // Persisted before the document is saved, and a failure here is swallowed on purpose: the cache is
        // derived data that `~/Library/Caches` may purge anyway, and losing it must not cost a finished
        // scan.
        if let cache { _ = try? await cache.persist() }

        do {
            let path = try store.save(outcome.scan)
            return Result(outcome: outcome, savedPath: path, saveFailure: nil)
        } catch {
            return Result(
                outcome: outcome, savedPath: nil, saveFailure: String(describing: error))
        }
    }

    /// Scans at `date`, resolving a free identifier first.
    ///
    /// **The overload that callers should use.** Taking a `Date` and resolving the instant here is what
    /// keeps the two from disagreeing: the identifier decides the filename, the instant decides what is
    /// stamped inside the document, and they come from the same value. An earlier version handed out an
    /// identifier from one method and took an instant in another, which let a caller deduplicate one and
    /// save under the other.
    public func run(
        _ request: Request,
        at date: Date,
        progress: ProgressCounters = ProgressCounters()
    ) async throws -> Result {
        try await run(request, instant: availableInstant(at: date), progress: progress)
    }

    /// The first instant at or after `date` whose identifier is not already taken.
    ///
    /// Consults the store, because the CLI and the app can both be running and overwriting somebody else's
    /// scan is not an acceptable way to discover a collision. Gives up after a thousand microseconds and
    /// returns the plain instant: at that precision, 1,000 consecutive collisions means something is wrong
    /// that a different identifier will not fix.
    public func availableInstant(at date: Date, limit: Int = 1000) -> ScanIdentifier.Instant {
        let taken = Set(store.identifiers(in: .scans))
        var instant = ScanIdentifier.Instant(date)
        for _ in 0..<limit {
            if !taken.contains(instant.identifier) { return instant }
            instant = instant.nextMicrosecond
        }
        return ScanIdentifier.Instant(date)
    }

    /// Whether a path can be scanned at all, before any work starts.
    ///
    /// Refusing up front is much better than walking for a minute and reporting zero groups, which is what
    /// an unreadable root produces and which looks exactly like success.
    public func check(root: String) -> RootCheck {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .notADirectory }
        guard FileManager.default.isReadableFile(atPath: root) else { return .unreadable }
        return .ok
    }

    public enum RootCheck: Sendable, Equatable {
        case ok
        case missing
        case notADirectory
        case unreadable

        public var canScan: Bool { self == .ok }
    }
}
