/// A set of files with identical content: same byte length, same SHA-256.
///
/// Paths are `String`, deliberately not `URL`. They are the raw bytes the walker produced, and every
/// comparison and every sort goes through ``PathOrder``. See that type for why Swift's `String`
/// comparison is the wrong tool here.
public struct DuplicateGroup: Hashable, Sendable {
    /// Byte length, shared by every member by construction.
    public let size: Int64
    public let digest: Digest32
    /// Member paths, in the order the document carried them.
    public let files: [String]

    /// How the members share storage, when the scan knew.
    ///
    /// `nil` for a group decoded from a document that did not record it -- every scan the CLI wrote, and
    /// every scan this app wrote before the partition existed. A `nil` here is not "no sharing": it is
    /// "unknown", and the difference matters because the reclaimable figure has to be labelled
    /// accordingly.
    public let storage: StoragePartition?

    public init(
        size: Int64,
        digest: Digest32,
        files: [String],
        storage: StoragePartition? = nil
    ) {
        self.size = size
        self.digest = digest
        self.files = files
        self.storage = storage
    }

    /// The key decisions are stored under: `"<size>:<hex digest>"`.
    ///
    /// Ports `group_key` (`src/rav/core/duplicate_review.py:160`). Keying on content rather than on
    /// paths is what lets a review survive a rescan: the same files found again produce the same key,
    /// so decisions made yesterday still apply.
    public var key: String { "\(size):\(digest.hexString)" }

    /// How many bytes would be freed if every member had its own storage.
    ///
    /// **An upper bound, and often a wrong one.** Copying a file on APFS produces a clone -- measured:
    /// `FileManager.copyItem` and `cp` both go through `clonefile` -- so two files with identical
    /// content frequently share their bytes, and removing one frees nothing. Kept so a scan can show
    /// how much of its apparent saving is real; nothing user-facing should present this as "space you
    /// will recover".
    public var redundantByteCountUpperBound: Int64 {
        guard files.count > 1 else { return 0 }
        return size * Int64(files.count - 1)
    }

    /// Bytes that removing the redundant copies would actually free.
    ///
    /// Falls back to the upper bound when the scan recorded no partition, which is what every document
    /// the CLI wrote looks like.
    public var reclaimableBytes: Int64 {
        storage?.reclaimableBytes(size: size) ?? redundantByteCountUpperBound
    }

    /// Whether ``reclaimableBytes`` is exact, or an upper bound the UI has to label as such.
    public var isReclaimExact: Bool { storage?.isExact ?? false }

    /// Whether some pair of members shares storage, so removing one would free nothing.
    public var hasSharedStorage: Bool { storage?.hasSharedStorage ?? false }

    /// The files to remove when `keeper` is kept: one representative per storage cluster.
    ///
    /// **Never `files[1:]`.** That is what the CLI hands to its move and delete paths
    /// (`src/rav/core/duplicates.py:140-144`), and on a group containing a hardlink it moves a second
    /// name for the very inode being kept: the keeper survives, the promised space is not recovered,
    /// and a path the user may still rely on is gone.
    public func removalCandidates(keeping keeper: String) -> [String] {
        guard let storage else {
            return files.filter { !PathOrder.equal($0, keeper) }
        }
        return storage.removalCandidates(keeping: keeper)
    }

    /// Paths that share storage with `keeper`. Shown as "the same file", never offered for removal.
    public func storageSiblings(of keeper: String) -> [String] {
        storage?.siblings(of: keeper) ?? []
    }

    /// Whether any member path is relative.
    ///
    /// `rav duplicate scan .` stores whatever string it was given, so a scan can carry relative
    /// paths (`src/rav/core/duplicates.py:97-104`). They cannot be acted on: the app's working
    /// directory is `/` when Launch Services starts it.
    public var hasRelativePaths: Bool {
        files.contains { !$0.hasPrefix("/") }
    }
}
