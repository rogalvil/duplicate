import Foundation

/// Runs a full exact-duplicate scan: walk, bucket, probe, hash, group.
///
/// The orchestration the CLI does inline in `find_duplicates`,
/// with two structural changes.
///
/// **Parallel over files, not over buckets.** Bucket sizes are wildly skewed -- one bucket of 40,000
/// `.DS_Store` files next to 30,000 buckets of two -- so a task per bucket has terrible load balance:
/// the run finishes when the single largest bucket does. The bucket only decides membership; the work
/// unit is a file.
///
/// **A sliding window, not a task per file.** `for file in files { group.addTask { … } }` over 800,000
/// files creates 800,000 suspended tasks before the first one completes: hundreds of megabytes of task
/// allocations, and 800,000 `open` calls racing a soft `RLIMIT_NOFILE` of 256. The window bounds tasks,
/// read buffers and file descriptors with one number.
///
/// Blocking `pread` runs under `withTaskExecutorPreference` on a concurrent Dispatch queue, so it never
/// occupies a thread in Swift's cooperative pool.
public struct DuplicateFinder: Sendable {
    public struct Configuration: Sendable {
        public var policy: ScanPolicy
        public var exclusions: ExclusionSet
        /// How many files to hash at once. `nil` asks ``IOConcurrencyPolicy`` for the root's volume.
        public var concurrency: Int?
        /// Where to look before reading a file, and where to record what was read.
        ///
        /// `nil` disables caching entirely, which is what the tests that assert read counts use. The
        /// caller loads and persists it: a scan should not decide on its own to write to a shared cache.
        public var cache: HashCache?

        public init(
            policy: ScanPolicy = ScanPolicy(),
            exclusions: ExclusionSet = ExclusionSet(),
            concurrency: Int? = nil,
            cache: HashCache? = nil
        ) {
            self.policy = policy
            self.exclusions = exclusions
            self.concurrency = concurrency
            self.cache = cache
        }
    }

    /// A finished scan, plus what the walk could not see.
    public struct Outcome: Sendable {
        public let scan: DuplicateScan
        /// What the walk could not see, and how much it visited -- **without its entries** (#161).
        ///
        /// Carrying every file the walk found kept that list alive until the scan returned: 72 bytes an entry,
        /// plus growth slack, for a list nothing downstream reads. The app reads `inaccessiblePaths`.
        public let walk: WalkResult
        /// Candidates that could not be hashed, with the reason. Skipped, not fatal.
        public let unreadable: [String]
        /// How many candidates the cache answered without a read.
        public let cacheHits: Int

        public init(
            scan: DuplicateScan,
            walk: WalkResult,
            unreadable: [String],
            cacheHits: Int = 0
        ) {
            self.scan = scan
            self.walk = walk
            self.unreadable = unreadable
            self.cacheHits = cacheHits
        }
    }

    private let walker: any DirectoryEnumerating
    private let hasher: any FileHashing
    private let ioQueue: DispatchQueue

    public init(
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: any FileHashing = ContentHasher()
    ) {
        self.walker = walker
        self.hasher = hasher
        ioQueue = DispatchQueue(
            label: "com.rogalvil.duplicate.io",
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    /// Scans `root` and returns a document ready to save.
    ///
    /// - Parameter instant: the moment the scan is stamped with. Injected so a test can assert an exact
    ///   identifier, and because `Date()` in the middle of a pipeline makes output irreproducible.
    public func find(
        root: String,
        instant: ScanIdentifier.Instant,
        configuration: Configuration = Configuration(),
        progress: ProgressCounters = ProgressCounters()
    ) async throws -> Outcome {
        progress.setPhase(.indexing)

        // **Every list of all the files is let go as soon as the next one exists** (#161). Peak memory was the
        // sum of copies nobody read any more -- the walk's list until the scan returned, the buckets through the
        // hashing, the survivors through the grouping -- and on 800,000 files that was 657-714 MB against a
        // target of 400. The scopes and the emptied variables below are what end those lifetimes.
        let walk: WalkResult
        var buckets: [[FileEntry]]
        do {
            let walked = try walker.walk(
                root: root,
                policy: configuration.policy,
                exclusions: configuration.exclusions
            )
            for entry in walked.entries {
                progress.noteFileSeen(path: entry.path)
            }
            try Task.checkCancellation()
            buckets = SizeBuckets.candidates(
                in: walked.entries,
                minimumSize: configuration.policy.minimumSize
            )
            walk = WalkResult(
                entries: [],
                inaccessiblePaths: walked.inaccessiblePaths,
                skipped: walked.skipped,
                visitedCount: walked.visitedCount
            )
        }
        let width =
            configuration.concurrency ?? IOConcurrencyPolicy.recommended(forItemAt: root)
        progress.setCandidates(buckets.reduce(0) { $0 + $1.count })

        // Stage one: probe the head, tail and length of the large buckets, and split them. A bucket that
        // survives as a singleton never gets read in full, which is where the whole win of the probe
        // lives -- two 4 GB disk images of the same length go from 8 GB of reads to 16 KiB.
        progress.setPhase(.probing)
        var survivors = try await narrow(buckets, width: width, progress: progress)
        buckets = []
        try Task.checkCancellation()

        // Stage two: the full digest, which is the content identity the shared format stores.
        progress.setPhase(.hashing)
        progress.setCandidates(survivors.count)

        // The cache is consulted here rather than inside the hasher, for two reasons. `FileHashing` is
        // synchronous and `HashCache` is an actor, so a caching hasher could not await it; and asking
        // once per candidate outside the bounded window keeps an actor hop out of the hot path.
        //
        // **The digests sit beside the survivors, not paired with them** (#161): one slot per candidate, `nil`
        // until it is known. A list of `(entry, digest)` pairs was a third list of every candidate at 104 bytes
        // a row, and joining the cached half to the hashed half once made a fourth.
        var digests = [Digest32?](repeating: nil, count: survivors.count)
        var toRead: [Int] = []
        if let cache = configuration.cache {
            for (index, entry) in survivors.enumerated() {
                if let digest = await cache.digest(for: entry) {
                    digests[index] = digest
                    progress.noteCacheHit()
                } else {
                    toRead.append(index)
                }
            }
        } else {
            toRead = Array(survivors.indices)
        }
        let cacheHits = survivors.count - toRead.count

        let unreadable = try await hashAll(
            toRead, of: &survivors, into: &digests, width: width, progress: progress)
        try Task.checkCancellation()

        if let cache = configuration.cache {
            await cache.reserve(toRead.count)
            for index in toRead {
                guard let digest = digests[index] else { continue }
                await cache.store(digest, for: survivors[index])
            }
        }

        progress.setPhase(.grouping)
        let groups = GroupBuilder.groups(entries: survivors, digests: digests)
        // **Not `.finished` here.** Finding is over; the scan is not. `ScanSession` still has to persist the
        // cache and write the document, and on a large tree that is minutes. A caller driving this type
        // directly ends at `.grouping`, which is the truth for what it does.

        return Outcome(
            scan: GroupBuilder.scan(root: root, instant: instant, groups: groups),
            walk: walk,
            unreadable: unreadable,
            cacheHits: cacheHits
        )
    }

    // MARK: - Stage one: prefix probe

    /// Splits each large bucket by its prefix digest and drops the resulting singletons.
    private func narrow(
        _ buckets: [[FileEntry]],
        width: Int,
        progress: ProgressCounters
    ) async throws -> [FileEntry] {
        // Sized for every candidate up front: grown by appends it doubled while the buckets it copies from were
        // still alive (#161). The probe only ever removes files, so this is an upper bound.
        var result: [FileEntry] = []
        result.reserveCapacity(buckets.reduce(0) { $0 + $1.count })
        for bucket in buckets {
            try Task.checkCancellation()
            guard let size = bucket.first?.size, hasher.usesPrefixStage(forSize: size) else {
                result.append(contentsOf: bucket)
                continue
            }
            let probes = await run(over: bucket, width: width) { entry in
                let digest = try? self.hasher.prefixDigest(atPath: entry.path, size: entry.size)
                progress.noteProbed(path: entry.path)
                return digest
            }
            // A file whose probe failed keeps going rather than being dropped: the full hash will
            // report the same failure with a better error, and silently discarding it here would
            // under-report duplicates.
            // The window's own optional (work never run, on cancellation) is flattened into the probe's
            // optional (probe failed): both mean "no discriminator", and both keep the file in.
            var byPrefix: [Digest32?: [FileEntry]] = [:]
            for (entry, digest) in zip(bucket, probes) {
                byPrefix[digest ?? nil, default: []].append(entry)
            }
            for (digest, members) in byPrefix {
                if digest == nil || members.count > 1 {
                    result.append(contentsOf: members)
                }
            }
        }
        return result
    }

    // MARK: - Stage two: full hash

    /// Hashes the survivors at `indices`, writing each digest into its slot, and returns the paths that could
    /// not be read.
    ///
    /// The size the walk recorded is what put a file in its bucket. If the file changed underneath the scan, its
    /// digest is still correct for what is on disk -- but it is no longer evidence of a match, so the entry takes
    /// the size that was actually hashed and the group builder decides again.
    private func hashAll(
        _ indices: [Int],
        of entries: inout [FileEntry],
        into digests: inout [Digest32?],
        width: Int,
        progress: ProgressCounters
    ) async throws -> [String] {
        let paths = indices.map { entries[$0].path }
        // Each result goes straight into its slot as it lands: collecting them first was one more list of every
        // file read, 48 bytes a row, alive beside the slots it was about to be copied into (#161). Work the window
        // never ran, on cancellation, delivers nothing, and the `checkCancellation` after this stage reports it.
        var failed: [Int] = []
        await run(
            over: paths, width: width,
            work: { path -> Result<HashResult, any Error> in
                do {
                    let hashed = try self.hasher.fullDigest(atPath: path)
                    progress.noteHashed(path: path, bytes: hashed.byteCount)
                    return .success(hashed)
                } catch {
                    return .failure(error)
                }
            },
            deliver: { position, outcome in
                let index = indices[position]
                switch outcome {
                case .success(let hashed):
                    if hashed.byteCount != entries[index].size {
                        entries[index] = entries[index].withSize(hashed.byteCount)
                    }
                    digests[index] = hashed.digest
                case .failure:
                    failed.append(position)
                }
            })
        // Reported either way. A file that vanished mid-scan and a file on a failing disk are both "we did not get
        // a digest", and the caller shows the list rather than pretending the scan was complete -- in input
        // order, so two runs of the same tree say it the same way.
        return failed.sorted().map { paths[$0] }
    }

    // MARK: - The bounded window

    /// Runs `work` over every element with at most `width` in flight, returning results in input order.
    ///
    /// Results are written by index, so the output never depends on completion order -- which is what
    /// keeps two runs of the same tree byte-identical.
    ///
    /// Each unit of work is bridged onto a concurrent Dispatch queue with a continuation, rather than
    /// running on Swift's cooperative pool. `pread` blocks, and blocking a cooperative thread can starve
    /// unrelated async work. **`withTaskExecutorPreference` would be the tidier way to say this and is
    /// not usable here: `DispatchQueue`'s `TaskExecutor` conformance requires macOS 15.4**, while this
    /// package targets 15.0. The bridge behaves identically and needs no availability check.
    private func run<Element: Sendable, Value: Sendable>(
        over elements: [Element],
        width: Int,
        work: @escaping @Sendable (Element) -> Value
    ) async -> [Value?] {
        var results = [Value?](repeating: nil, count: elements.count)
        await run(over: elements, width: width, work: work) { results[$0] = $1 }
        return results
    }

    /// The same window, handing each result to `deliver` with its index as it completes instead of keeping them.
    private func run<Element: Sendable, Value: Sendable>(
        over elements: [Element],
        width: Int,
        work: @escaping @Sendable (Element) -> Value,
        deliver: (Int, Value) -> Void
    ) async {
        guard !elements.isEmpty else { return }
        let inflight = max(1, min(width, elements.count))
        let queue = ioQueue

        await withTaskGroup(of: (Int, Value?).self) { group in
            func schedule(_ index: Int) {
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    let value = await withCheckedContinuation { continuation in
                        queue.async {
                            continuation.resume(returning: work(elements[index]))
                        }
                    }
                    return (index, value)
                }
            }

            var next = 0
            while next < inflight {
                schedule(next)
                next += 1
            }
            while let (index, value) = await group.next() {
                if let value { deliver(index, value) }
                guard !Task.isCancelled, next < elements.count else { continue }
                schedule(next)
                next += 1
            }
        }
    }
}
