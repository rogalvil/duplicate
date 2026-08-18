import Foundation

/// Runs one perceptual scan end to end: walk, hash, index, verify, save.
///
/// **Images and videos are found by two different searches, and only one of them can be indexed.** An image is
/// one hash, so the LSH index applies and 0.41% of the pairs get compared. A video is a *list* of eight hashes
/// compared by a greedy asymmetric rule, and no band index answers that -- so videos are compared pairwise, the
/// way the CLI does it. The cost is bearable because the comparison is popcounts: 617 videos are 190,000 pairs
/// of at most 64 hash comparisons each. What costs is the hashing.
///
/// **Measured on 617 real videos**: 213 ms each serially, 151 ms with four concurrent, and **eight is no faster
/// than four** -- `AVAssetImageGenerator` already parallelises inside itself, so the bounded group is there to
/// keep four decodes in flight rather than to find more parallelism.
public struct SimilarScanSession: Sendable {

    /// The extensions the CLI treats as images (`perceptual.py:16-18`).
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    /// And as videos, from the same lines.
    ///
    /// **`.mkv` and `.avi` are listed and will not open.** `AVAssetImageGenerator` has no demuxer for them, so
    /// they are hashed as nothing and reported unreadable rather than silently skipped. Measured on this
    /// user's corpus: `.mp4` 1,938, `.mov` 2, and **zero** of either, which is why this is documented instead
    /// of solved.
    public static let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "m4v"]

    /// How many videos to decode at once.
    ///
    /// Measured, not guessed: 60 real videos took 213 ms each serially, 151 ms at four concurrent, and 151 ms
    /// at eight. The generator parallelises internally, so more workers only add memory.
    public static let videoConcurrency = 4

    public struct Request: Sendable {
        public var root: String
        /// Maximum Hamming distance out of 64. The CLI's default is 5.
        public var imageThreshold: Int
        /// Recorded in the document even though no video is scanned yet, because the CLI's reader expects the
        /// field and a scan at a different video threshold is a different scan.
        public var videoThreshold: Double
        public var policy: ScanPolicy
        /// Whether to read and write the perceptual cache.
        public var usesCache: Bool
        /// Whether to hash videos as well.
        ///
        /// On by default, like the CLI. Off is worth offering because video is the expensive half: on this
        /// user's test tree, 2,779 images take 19 seconds and 617 videos take 93.
        public var includesVideo: Bool

        public init(
            root: String,
            imageThreshold: Int = 5,
            videoThreshold: Double = 0.70,
            policy: ScanPolicy = ScanPolicy(),
            usesCache: Bool = true,
            includesVideo: Bool = true
        ) {
            self.root = root
            self.imageThreshold = imageThreshold
            self.videoThreshold = videoThreshold
            self.policy = policy
            self.usesCache = usesCache
            self.includesVideo = includesVideo
        }
    }

    public struct Result: Sendable {
        public let scan: SimilarScan
        /// Images ImageIO could not decode. Skipped, not fatal -- the CLI's `phash_image` returns `None` and
        /// moves on, and one unreadable JPEG must not lose the other nine thousand.
        public let unreadable: [String]
        public let inaccessible: [String]
        /// How many files were hashed, both kinds.
        public let hashedCount: Int
        /// How many videos were hashed, and how many pairs of them were compared.
        public let videoCount: Int
        public let videoPairsCompared: Int
        /// Files served by the cache, split by kind because the two cost wildly different amounts.
        public let imageCacheHits: Int
        public let videoCacheHits: Int
        /// Distinct hash values, so a caller can see how much of the corpus is exact-duplicate images.
        public let classCount: Int
        /// Pairs of classes the index examined, against the number it would have compared without one.
        public let examinedPairs: Int
        public let totalPairs: Int
        /// Which media kinds this build actually looked at.
        public let scannedKinds: Set<MediaKind>
        public let savedPath: String?
        public let saveFailure: String?
    }

    private let store: ScanStore
    private let walker: any DirectoryEnumerating
    private let hasher: ImageHasher
    private let videoHasher: VideoHasher
    private let trashResolver: any TrashRootResolving
    private let cacheURL: URL?

    public init(
        store: ScanStore = ScanStore(),
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: ImageHasher = ImageHasher(),
        videoHasher: VideoHasher = VideoHasher(),
        trashResolver: any TrashRootResolving = SystemTrashRootResolver(),
        cacheURL: URL? = nil
    ) {
        self.store = store
        self.walker = walker
        self.hasher = hasher
        self.videoHasher = videoHasher
        self.trashResolver = trashResolver
        self.cacheURL = cacheURL
    }

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

        let images = walk.entries.filter {
            SimilarScanSession.imageExtensions.contains(
                ($0.path as NSString).pathExtension.lowercased())
        }
        let videos =
            request.includesVideo
            ? walk.entries.filter {
                SimilarScanSession.videoExtensions.contains(
                    ($0.path as NSString).pathExtension.lowercased())
            } : []

        // Every image and every video is hashed -- there is no size bucket to hide behind, the same as the
        // folder detector. The video half is what the progress bar is mostly counting: measured, one video
        // costs about as much as thirty images.
        progress.setPhase(.hashing)
        progress.setCandidates(images.count + videos.count)

        let cache =
            request.usesCache
            ? PerceptualCache(
                url: cacheURL ?? PerceptualCache.defaultURL(),
                imageConfiguration: hasher.configuration,
                videoConfiguration: videoHasher.configuration
            ) : nil
        await cache?.load()

        var paths: [String] = []
        var hashes: [PerceptualHash] = []
        var unreadable: [String] = []
        var imageHits = 0
        paths.reserveCapacity(images.count)
        hashes.reserveCapacity(images.count)

        for entry in images {
            try Task.checkCancellation()
            if let cache, let known = await cache.hashes(for: entry, kind: .image),
                let first = known.first
            {
                imageHits += 1
                progress.noteCacheHit()
                progress.noteHashed(path: entry.path, bytes: 0)
                paths.append(entry.path)
                hashes.append(first)
                continue
            }
            guard let hash = try? hasher.hash(fileURL: URL(filePath: entry.path)) else {
                unreadable.append(entry.path)
                continue
            }
            if let cache { await cache.store([hash], for: entry, kind: .image) }
            progress.noteHashed(path: entry.path, bytes: entry.size)
            paths.append(entry.path)
            hashes.append(hash)
        }

        var videoHits = 0
        let videoResults = try await hashVideos(
            videos, progress: progress, cache: cache, hits: &videoHits, unreadable: &unreadable)
        // Written before the pairs are built: the hashing is the expensive part, and a crash while comparing
        // must not throw away work that is already true.
        if let cache { _ = try? await cache.persist() }

        progress.setPhase(.grouping)
        let index = MultiIndexLSH(maximumDistance: request.imageThreshold)
        let (matches, candidates) = index.matches(in: hashes)
        try Task.checkCancellation()

        var pairs: [SimilarPair] = []
        // Pairs inside one class: identical hashes, so similarity is exactly 1.0 and no comparison is needed.
        for item in candidates.classes where item.members.count > 1 {
            for i in item.members.indices {
                for j in (i + 1)..<item.members.count {
                    pairs.append(
                        makePair(
                            paths[item.members[i]], paths[item.members[j]], similarity: 1.0))
                }
            }
        }
        // And pairs across classes, every member against every member.
        for match in matches {
            for a in candidates.classes[match.a].members {
                for b in candidates.classes[match.b].members {
                    pairs.append(makePair(paths[a], paths[b], similarity: match.similarity))
                }
            }
        }

        // Videos, pairwise. **No index applies**: the comparison is between two *lists* of hashes under a
        // greedy asymmetric rule, and a band index answers questions about single hashes. The CLI compares
        // every pair too; what makes it affordable is that each comparison is at most 64 popcounts.
        var videoPairsCompared = 0
        for i in videoResults.indices {
            try Task.checkCancellation()
            for j in (i + 1)..<videoResults.count {
                videoPairsCompared += 1
                let similarity = VideoSimilarity.orientedSimilarity(
                    pathA: videoResults[i].path, hashesA: videoResults[i].hashes,
                    pathB: videoResults[j].path, hashesB: videoResults[j].hashes,
                    threshold: request.imageThreshold
                )
                guard similarity >= request.videoThreshold else { continue }
                let ordered =
                    PathOrder.lessThan(videoResults[i].path, videoResults[j].path)
                    ? (videoResults[i].path, videoResults[j].path)
                    : (videoResults[j].path, videoResults[i].path)
                pairs.append(
                    SimilarPair(
                        fileA: ordered.0, fileB: ordered.1, similarity: similarity,
                        mediaKind: .video))
            }
        }

        // Similarity descending like the CLI, with ties broken on the two paths by bytes. The CLI's sort is
        // stable over `os.walk` order, which is not reproducible on another machine.
        pairs.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if !PathOrder.equal($0.fileA, $1.fileA) {
                return PathOrder.lessThan($0.fileA, $1.fileA)
            }
            return PathOrder.lessThan($0.fileB, $1.fileB)
        }
        progress.setPhase(.finished)

        let scan = SimilarScan(
            scanID: instant.identifier,
            root: request.root,
            createdAt: instant.timestamp,
            imageThreshold: request.imageThreshold,
            videoThreshold: request.videoThreshold,
            pairs: pairs
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
            hashedCount: hashes.count + videoResults.count,
            videoCount: videoResults.count,
            videoPairsCompared: videoPairsCompared,
            imageCacheHits: imageHits,
            videoCacheHits: videoHits,
            classCount: candidates.classes.count,
            examinedPairs: candidates.pairs.count,
            totalPairs: hashes.count * (hashes.count - 1) / 2,
            scannedKinds: request.includesVideo ? [.image, .video] : [.image],
            savedPath: savedPath,
            saveFailure: saveFailure
        )
    }

    /// Hashes videos with a bounded number of decodes in flight.
    ///
    /// **Bounded at four because that is where the measurement stops improving**, not because four is a nice
    /// number: 60 real videos took 213 ms each serially, 151 ms at four, and 151 ms at eight. Beyond four the
    /// only thing that grows is how many decoded frames are alive at once.
    ///
    /// Results come back in completion order and are sorted by path afterwards, so the document does not depend
    /// on which decode finished first.
    private func hashVideos(
        _ entries: [FileEntry],
        progress: ProgressCounters,
        cache: PerceptualCache?,
        hits: inout Int,
        unreadable: inout [String]
    ) async throws -> [(path: String, hashes: [PerceptualHash])] {
        guard !entries.isEmpty else { return [] }
        let hasher = videoHasher
        var collected: [(path: String, hashes: [PerceptualHash])] = []
        var failed: [String] = []

        // The cache is consulted before anything is queued, so a warm scan never opens a decoder at all.
        var pending: [FileEntry] = []
        for entry in entries {
            if let cache, let known = await cache.hashes(for: entry, kind: .video) {
                hits += 1
                progress.noteCacheHit()
                progress.noteHashed(path: entry.path, bytes: 0)
                collected.append((entry.path, known))
                continue
            }
            pending.append(entry)
        }

        try await withThrowingTaskGroup(of: (String, [PerceptualHash], Int64).self) { group in
            var index = 0
            var running = 0
            while index < pending.count || running > 0 {
                while running < SimilarScanSession.videoConcurrency, index < pending.count {
                    let entry = pending[index]
                    index += 1
                    running += 1
                    group.addTask {
                        let result = try? await hasher.hashes(fileURL: URL(filePath: entry.path))
                        return (entry.path, result?.hashes ?? [], entry.size)
                    }
                }
                guard let finished = try await group.next() else { break }
                running -= 1
                try Task.checkCancellation()
                progress.noteHashed(path: finished.0, bytes: finished.2)
                // A video nothing could be read from is skipped and named, like an unreadable image. That is
                // where `.mkv` and `.avi` land: listed by the CLI, and with no demuxer here.
                if finished.1.isEmpty {
                    failed.append(finished.0)
                } else {
                    collected.append((finished.0, finished.1))
                }
            }
        }

        if let cache {
            var byPath: [String: FileEntry] = [:]
            for entry in pending { byPath[entry.path] = entry }
            for row in collected {
                guard let entry = byPath[row.path] else { continue }
                await cache.store(row.hashes, for: entry, kind: .video)
            }
        }

        unreadable.append(contentsOf: PathOrder.sorted(failed))
        collected.sort { PathOrder.lessThan($0.path, $1.path) }
        return collected
    }

    /// Scans at `date`, resolving a free identifier first.
    ///
    /// Same reasoning as the other two sessions: the identifier decides the filename and the instant decides
    /// what is stamped inside, so they come from one value.
    public func run(
        _ request: Request,
        at date: Date,
        progress: ProgressCounters = ProgressCounters()
    ) async throws -> Result {
        let taken = Set(store.identifiers(in: .similarScans))
        var instant = ScanIdentifier.Instant(date)
        for _ in 0..<1000 {
            if !taken.contains(instant.identifier) { break }
            instant = instant.nextMicrosecond
        }
        return try await run(request, instant: instant, progress: progress)
    }

    // MARK: - Private

    /// **`file_a` is the byte-smaller path, and it decides which file gets destroyed.**
    ///
    /// `similar-decisions` records `keep_a` or `keep_b` against a `"a||b"` key (`similar_review.py:310-315`), so
    /// which path sits in which field is what a review acts on. Taking it from the walk's enumeration order
    /// would take it from something nothing promises to reproduce -- the same lesson the folder detector learned
    /// the hard way, where all 42 pairs came out mirrored from the CLI's.
    private func makePair(_ first: String, _ second: String, similarity: Double) -> SimilarPair {
        let ordered =
            PathOrder.lessThan(first, second) ? (first, second) : (second, first)
        return SimilarPair(
            fileA: ordered.0, fileB: ordered.1, similarity: similarity, mediaKind: .image)
    }
}
