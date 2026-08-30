/// Splits a group's files by the storage they actually occupy.
///
/// Two files with identical content do not necessarily occupy two copies of it:
///
/// - **Hardlinks** are one inode under two names. Removing one frees nothing.
/// - **APFS clones** are two inodes sharing one content stream. Removing one frees nothing either,
///   until the last reference goes.
///
/// Both matter more than they sound, because **copying a file on APFS produces a clone.** Measured:
/// `FileManager.copyItem` and `cp` both go through `clonefile`, so a file duplicated in Finder shares
/// storage with its original. A tool that reported that pair as recoverable space would be claiming
/// bytes that deleting it cannot return -- and the user can falsify the claim with `df`.
///
/// | how the second file was made | inode | content id | deleting one frees |
/// |---|---|---|---|
/// | `link(2)` | same | same | nothing |
/// | `clonefile(2)` | different | **same** | nothing |
/// | `FileManager.copyItem` / `cp` on APFS | different | **same** | nothing |
/// | written independently, or downloaded twice | different | different | its whole size |
///
/// `NSURLFileContentIdentifierKey` is documented as shared only by clones and their originals, and that
/// was verified against `clonefile(2)` on this machine. Where it is absent -- a volume that is not APFS
/// -- every file is assumed to have its own storage, which makes the figure an **upper bound**. Callers
/// must say so rather than round it into a confident number; ``StoragePartition/isExact`` reports which
/// case it is.
public struct StoragePartition: Hashable, Sendable {
    /// Paths grouped by the storage they share. Every cluster has at least one member.
    public let clusters: [[String]]
    /// Whether every file reported a content identifier, so the count is certain.
    public let isExact: Bool

    public init(clusters: [[String]], isExact: Bool) {
        self.clusters = clusters
        self.isExact = isExact
    }

    /// How many distinct copies of the content exist.
    public var distinctCopies: Int { clusters.count }

    /// Whether any cluster holds more than one path, meaning some pair shares storage.
    public var hasSharedStorage: Bool { clusters.contains { $0.count > 1 } }

    /// Bytes freed by keeping one cluster and removing the rest.
    ///
    /// Exact when ``isExact`` is true, an upper bound otherwise.
    public func reclaimableBytes(size: Int64) -> Int64 {
        guard clusters.count > 1 else { return 0 }
        return size * Int64(clusters.count - 1)
    }

    /// Partitions entries by storage.
    ///
    /// Clusters and the paths inside them come back in byte order, so the result is reproducible and can
    /// be serialised into a scan document without depending on hash-table iteration order.
    public static func of(_ entries: [FileEntry]) -> StoragePartition {
        var byClass: [StorageClass: [String]] = [:]
        var isExact = true
        for entry in entries {
            let key: StorageClass
            if let content = entry.contentIdentifier {
                // Shared by clones and their originals, and by hardlinks too -- a hardlink has the same
                // inode, so it necessarily has the same content stream.
                key = .content(content)
            } else if let identity = entry.identity {
                // No content identifier: fall back to the inode, which still catches hardlinks. Clones
                // become indistinguishable from independent copies, so the count can only be too high.
                isExact = false
                key = .inode(identity)
            } else {
                // Nothing to group by. Treated as its own storage, which is the conservative direction:
                // it can overstate what is reclaimable, never understate it.
                isExact = false
                key = .unknown(entry.path)
            }
            byClass[key, default: []].append(entry.path)
        }

        let clusters =
            byClass.values
            .map { PathOrder.sorted($0) }
            .sorted { PathOrder.lessThan($0[0], $1[0]) }
        return StoragePartition(clusters: clusters, isExact: isExact)
    }

    /// The files to remove, keeping the cluster that holds `keeper`.
    ///
    /// **Never `files[1:]`.** That is what the CLI hands to its move and delete paths
    /// (`src/rav/core/duplicates.py:140-144`), and on a group containing a hardlink it moves a second
    /// name for the very inode being kept: the keeper survives, the reported space is not recovered, and
    /// a path the user may still rely on is gone. One representative per cluster, minus the keeper's,
    /// is the only set whose removal frees exactly what was promised.
    public func removalCandidates(keeping keeper: String) -> [String] {
        clusters
            .filter { cluster in !cluster.contains { PathOrder.equal($0, keeper) } }
            .compactMap(\.first)
    }

    /// The files to remove when every path in `kept` survives.
    ///
    /// One representative per cluster, minus **every** cluster that holds a kept path -- which is not
    /// the same as ``removalCandidates(keeping:)`` plus a filter over the kept paths. That version
    /// excludes one cluster and then drops kept paths from the representatives of the others, so a
    /// cluster whose byte-order first member is not the kept one still offered its other name. Moving
    /// that frees nothing, because it is the same storage, and it takes away a path the user chose to
    /// keep -- the same failure `removalCandidates(keeping:)` exists to prevent, one case further out.
    public func removalCandidates(keepingAll kept: [String]) -> [String] {
        clusters
            .filter { cluster in
                !cluster.contains { path in kept.contains { PathOrder.equal($0, path) } }
            }
            .compactMap(\.first)
    }

    /// Every path that shares storage with `keeper`, excluding it.
    ///
    /// What the UI shows as "these are the same file", rather than offering them for removal.
    public func siblings(of keeper: String) -> [String] {
        guard
            let cluster = clusters.first(where: { cluster in
                cluster.contains { PathOrder.equal($0, keeper) }
            })
        else { return [] }
        return cluster.filter { !PathOrder.equal($0, keeper) }
    }
}

/// How a file's storage is identified, in decreasing order of certainty.
private enum StorageClass: Hashable {
    /// An APFS content stream: shared only by clones, their originals, and hardlinks.
    case content(Int64)
    /// An inode, when no content identifier is available. Catches hardlinks only.
    case inode(FileIdentity)
    /// Neither was readable. The path stands in, so the file counts as its own storage.
    case unknown(String)
}
