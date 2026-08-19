import Foundation

/// One folder a review would move, and the pair that says so.
public struct FolderApplyItem: Hashable, Sendable {
    public let path: String
    /// The folder being kept, whose contents the doomed one must be contained in.
    public let keeper: String
    public let pairKey: String
    /// How many files the scan counted in the folder being moved.
    public let recordedFileCount: Int

    public init(path: String, keeper: String, pairKey: String, recordedFileCount: Int) {
        self.path = path
        self.keeper = keeper
        self.pairKey = pairKey
        self.recordedFileCount = recordedFileCount
    }
}

/// What a folder apply would do.
///
/// **Removing a folder is not removing a file, and this plan is where that difference lives.** Three exclusions,
/// each of which would otherwise destroy something the user asked to keep:
///
/// **Nested pairs collapse.** A folder scan finds `Pole ↔ Pole` and `Pole/videos ↔ Pole/videos` as separate
/// pairs -- measured on the real corpus, where the 42 pairs include parents and their own children. Moving the
/// parent takes the child with it, so a plan holding both would move the parent and then fail on a path that no
/// longer exists, reporting an error for something that worked. The descendant is dropped and named in
/// ``collapsed``.
///
/// **A folder that contains a keeper is excluded.** If the plan moves `X` and another pair keeps `X/sub`, moving
/// `X` deletes `X/sub` too. That is not a conflict the user can see coming, and it is not resolvable by ordering.
///
/// **And a folder kept by another pair is excluded**, the same rule the perceptual plan uses: both decisions are
/// the user's, and the only reading that respects both is to act on neither.
public struct FolderApplyPlan: Sendable {
    public let items: [FolderApplyItem]
    /// Descendants dropped because an ancestor is already being moved.
    public let collapsed: [String]
    /// Folders dropped because another decision keeps them, or keeps something inside them.
    public let contradicted: [String]
    public let scanID: String

    public init(
        items: [FolderApplyItem], collapsed: [String], contradicted: [String], scanID: String
    ) {
        self.items = items
        self.collapsed = collapsed
        self.contradicted = contradicted
        self.scanID = scanID
    }

    public var isEmpty: Bool { items.isEmpty }

    public static func from(_ state: FolderReviewState) -> FolderApplyPlan {
        // Everything any decision keeps, so a folder that contains one can be spotted.
        var kept: Set<String> = []
        for index in state.scan.pairs.indices {
            guard let decision = state.decision(at: index).keptPaths else { continue }
            for path in decision { kept.insert(DirectoryTree.canonical(path)) }
        }

        var candidates: [FolderApplyItem] = []
        var contradicted: [String] = []
        var seen: Set<String> = []

        for (index, pair) in state.scan.pairs.enumerated() {
            guard let keptPaths = state.decision(at: index).keptPaths else { continue }
            let keptSet = Set(keptPaths.map(DirectoryTree.canonical))
            for (folder, other) in [(pair.folderA, pair.folderB), (pair.folderB, pair.folderA)] {
                let canonical = DirectoryTree.canonical(folder)
                guard !keptSet.contains(canonical) else { continue }
                guard seen.insert(canonical).inserted else { continue }
                // Kept by another pair, or holding something another pair keeps.
                if kept.contains(canonical)
                    || kept.contains(where: { isAncestor(canonical, of: $0) })
                {
                    contradicted.append(canonical)
                    continue
                }
                candidates.append(
                    FolderApplyItem(
                        path: canonical,
                        keeper: DirectoryTree.canonical(other),
                        pairKey: folderPairKey(pair),
                        recordedFileCount: folder == pair.folderA ? pair.totalA : pair.totalB
                    ))
            }
        }

        // Collapse: drop anything under a folder that is already going.
        candidates.sort { PathOrder.lessThan($0.path, $1.path) }
        var items: [FolderApplyItem] = []
        var collapsed: [String] = []
        for candidate in candidates {
            if items.contains(where: { isAncestor($0.path, of: candidate.path) }) {
                collapsed.append(candidate.path)
                continue
            }
            items.append(candidate)
        }

        return FolderApplyPlan(
            items: items,
            collapsed: PathOrder.sorted(collapsed),
            contradicted: PathOrder.sorted(contradicted),
            scanID: state.scan.scanID
        )
    }

    /// The `a||b` key, in the CLI's shape.
    public static func folderPairKey(_ pair: FolderPair) -> String {
        pair.folderA + "||" + pair.folderB
    }

    /// Whether `ancestor` contains `path`, by whole path components.
    ///
    /// **Component-wise, not by string prefix**: `/a/photos` is not inside `/a/photo`, and a prefix test would say
    /// it is -- then move a folder nobody decided about.
    public static func isAncestor(_ ancestor: String, of path: String) -> Bool {
        guard ancestor != path else { return false }
        return path.hasPrefix(ancestor.hasSuffix("/") ? ancestor : ancestor + "/")
    }

    public var fingerprint: String {
        var hash = FNV1a()
        for item in items {
            hash.combine(item.pairKey)
            hash.combine("\u{1}")
            hash.combine(item.path)
            hash.combine("\u{2}")
        }
        return hash.value
    }
}
