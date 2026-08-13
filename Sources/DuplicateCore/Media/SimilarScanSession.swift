import Foundation

/// Runs one perceptual scan of images end to end: walk, hash, index, verify, save.
///
/// **Images only, for now, and the document says so by what it does not contain.** The CLI's `similar` command
/// also hashes videos; this writes a document with `vid_threshold` recorded and no video pairs in it. That is a
/// real difference in what a scan finds, not a formatting one, so it is reported by ``Result/scannedKinds`` and
/// stated in the README rather than left for someone to notice.
public struct SimilarScanSession: Sendable {

    /// The extensions the CLI treats as images (`perceptual.py:16-18`).
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "gif"]

    public struct Request: Sendable {
        public var root: String
        /// Maximum Hamming distance out of 64. The CLI's default is 5.
        public var imageThreshold: Int
        /// Recorded in the document even though no video is scanned yet, because the CLI's reader expects the
        /// field and a scan at a different video threshold is a different scan.
        public var videoThreshold: Double
        public var policy: ScanPolicy
        public var usesCache: Bool

        public init(
            root: String,
            imageThreshold: Int = 5,
            videoThreshold: Double = 0.70,
            policy: ScanPolicy = ScanPolicy(),
            usesCache: Bool = true
        ) {
            self.root = root
            self.imageThreshold = imageThreshold
            self.videoThreshold = videoThreshold
            self.policy = policy
            self.usesCache = usesCache
        }
    }

    public struct Result: Sendable {
        public let scan: SimilarScan
        /// Images ImageIO could not decode. Skipped, not fatal -- the CLI's `phash_image` returns `None` and
        /// moves on, and one unreadable JPEG must not lose the other nine thousand.
        public let unreadable: [String]
        public let inaccessible: [String]
        /// How many files were hashed.
        public let hashedCount: Int
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
    private let trashResolver: any TrashRootResolving

    public init(
        store: ScanStore = ScanStore(),
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: ImageHasher = ImageHasher(),
        trashResolver: any TrashRootResolving = SystemTrashRootResolver()
    ) {
        self.store = store
        self.walker = walker
        self.hasher = hasher
        self.trashResolver = trashResolver
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

        // Every image is hashed -- there is no size bucket to hide behind, the same as the folder detector.
        progress.setPhase(.hashing)
        progress.setCandidates(images.count)

        var paths: [String] = []
        var hashes: [PerceptualHash] = []
        var unreadable: [String] = []
        paths.reserveCapacity(images.count)
        hashes.reserveCapacity(images.count)

        for entry in images {
            try Task.checkCancellation()
            guard let hash = try? hasher.hash(fileURL: URL(filePath: entry.path)) else {
                unreadable.append(entry.path)
                continue
            }
            progress.noteHashed(path: entry.path, bytes: entry.size)
            paths.append(entry.path)
            hashes.append(hash)
        }

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
            hashedCount: hashes.count,
            classCount: candidates.classes.count,
            examinedPairs: candidates.pairs.count,
            totalPairs: hashes.count * (hashes.count - 1) / 2,
            scannedKinds: [.image],
            savedPath: savedPath,
            saveFailure: saveFailure
        )
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
