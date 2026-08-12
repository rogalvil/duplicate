import Foundation

/// Runs a full exact-duplicate scan: walk, bucket, probe, hash, group.
///
/// The orchestration the CLI does inline in `find_duplicates`
/// (`src/rav/core/duplicates.py:51-94`), with two structural changes.
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

        public init(
            policy: ScanPolicy = ScanPolicy(),
            exclusions: ExclusionSet = ExclusionSet(),
            concurrency: Int? = nil
        ) {
            self.policy = policy
            self.exclusions = exclusions
            self.concurrency = concurrency
        }
    }

    /// A finished scan, plus what the walk could not see.
    public struct Outcome: Sendable {
        public let scan: DuplicateScan
        public let walk: WalkResult
        /// Candidates that could not be hashed, with the reason. Skipped, not fatal.
        public let unreadable: [String]

        public init(scan: DuplicateScan, walk: WalkResult, unreadable: [String]) {
            self.scan = scan
            self.walk = walk
            self.unreadable = unreadable
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

        let walk = try walker.walk(
            root: root,
            policy: configuration.policy,
            exclusions: configuration.exclusions
        )
        for entry in walk.entries {
            progress.noteFileSeen(path: entry.path)
        }
        try Task.checkCancellation()

        let buckets = SizeBuckets.candidates(
            in: walk.entries,
            minimumSize: configuration.policy.minimumSize
        )
        let width =
            configuration.concurrency ?? IOConcurrencyPolicy.recommended(forItemAt: root)
        progress.setCandidates(buckets.reduce(0) { $0 + $1.count })

        // Stage one: probe the head, tail and length of the large buckets, and split them. A bucket that
        // survives as a singleton never gets read in full, which is where the whole win of the probe
        // lives -- two 4 GB disk images of the same length go from 8 GB of reads to 16 KiB.
        progress.setPhase(.probing)
        let survivors = try await narrow(buckets, width: width, progress: progress)
        try Task.checkCancellation()

        // Stage two: the full digest, which is the content identity the shared format stores.
        progress.setPhase(.hashing)
        progress.setCandidates(survivors.count)
        let hashed = try await hashAll(survivors, width: width, progress: progress)
        try Task.checkCancellation()

        progress.setPhase(.grouping)
        let groups = GroupBuilder.groups(from: hashed.digests)
        progress.setPhase(.finished)

        return Outcome(
            scan: GroupBuilder.scan(root: root, instant: instant, groups: groups),
            walk: walk,
            unreadable: hashed.unreadable
        )
    }

    // MARK: - Stage one: prefix probe

    /// Splits each large bucket by its prefix digest and drops the resulting singletons.
    private func narrow(
        _ buckets: [[FileEntry]],
        width: Int,
        progress: ProgressCounters
    ) async throws -> [FileEntry] {
        var result: [FileEntry] = []
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

    private func hashAll(
        _ entries: [FileEntry],
        width: Int,
        progress: ProgressCounters
    ) async throws -> (digests: [(entry: FileEntry, digest: Digest32)], unreadable: [String]) {
        let results = await run(over: entries, width: width) {
            entry -> Result<HashResult, any Error> in
            do {
                let hashed = try self.hasher.fullDigest(atPath: entry.path)
                progress.noteHashed(path: entry.path, bytes: hashed.byteCount)
                return .success(hashed)
            } catch {
                return .failure(error)
            }
        }

        var digests: [(entry: FileEntry, digest: Digest32)] = []
        var unreadable: [String] = []
        for (entry, outcome) in zip(entries, results) {
            switch outcome {
            case .success(let hashed)?:
                // The size the walk recorded is what put this file in its bucket. If the file changed
                // underneath the scan, its digest is still correct for what is on disk -- but it is no
                // longer evidence of a match, so the walk's size is replaced with the one that was
                // actually hashed and the group builder decides again.
                digests.append(
                    (FileEntry(path: entry.path, size: hashed.byteCount), hashed.digest)
                )
            case .failure?:
                // Reported either way. A file that vanished mid-scan and a file on a failing disk are
                // both "we did not get a digest", and the caller shows the list rather than pretending
                // the scan was complete.
                unreadable.append(entry.path)
            case nil:
                // The window returns nil only for work it never ran, which happens on cancellation.
                // Cancellation is surfaced by the checkCancellation call after this stage, so there is
                // nothing to record here.
                break
            }
        }
        return (digests, unreadable)
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
        guard !elements.isEmpty else { return [] }
        var results = [Value?](repeating: nil, count: elements.count)
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
                results[index] = value
                guard !Task.isCancelled, next < elements.count else { continue }
                schedule(next)
                next += 1
            }
        }
        return results
    }
}
