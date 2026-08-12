/// One file the walk found: its path and its length.
///
/// The seam that lets every stage downstream of the walk be driven by synthetic entries with no
/// filesystem. Identity and timestamp fields arrive with the walker that can populate them; the
/// bucketing and grouping stages need only these two.
///
/// `path` is a `String` holding the raw bytes the walk produced. Never normalise it -- see
/// ``PathOrder``.
public struct FileEntry: Hashable, Sendable {
    public let path: String
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }
}
