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

    public init(size: Int64, digest: Digest32, files: [String]) {
        self.size = size
        self.digest = digest
        self.files = files
    }

    /// The key decisions are stored under: `"<size>:<hex digest>"`.
    ///
    /// Ports `group_key` (`src/rav/core/duplicate_review.py:160`). Keying on content rather than on
    /// paths is what lets a review survive a rescan: the same files found again produce the same key,
    /// so decisions made yesterday still apply.
    public var key: String { "\(size):\(digest.hexString)" }

    /// How many bytes would be freed by keeping one member and removing the rest -- **as an upper
    /// bound, not a promise**.
    ///
    /// Hardlinks and APFS clones share storage, so removing one of them frees nothing. Until the
    /// group is partitioned by storage class, this number can overstate the gain, and its name says
    /// so. Nothing user-facing should present it as "space you will recover".
    public var redundantByteCountUpperBound: Int64 {
        guard files.count > 1 else { return 0 }
        return size * Int64(files.count - 1)
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
