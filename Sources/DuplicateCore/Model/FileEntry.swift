import Foundation

/// Which volume a file lives on, and which inode it occupies there.
///
/// Two files with the same identity are the *same* file reached by two names -- a hardlink. Removing
/// one frees nothing, so proposing it as a duplicate overstates the recoverable space by its whole
/// size, and the user can catch the lie with `df`.
///
/// The volume identifier that Foundation returns is documented as opaque, and it really is: an
/// 8-byte `NSData` on APFS. It is hashed into a `UInt64` here so the identity is a cheap value type
/// that can live in a `Set` and in a struct-of-arrays. Hashing loses the ability to recover the
/// original bytes, which nothing needs, and keeps the ability to compare, which is all anyone does.
public struct FileIdentity: Hashable, Sendable {
    public let volume: UInt64
    public let inode: UInt64

    public init(volume: UInt64, inode: UInt64) {
        self.volume = volume
        self.inode = inode
    }
}

/// One file the walk found.
///
/// The seam that lets every stage downstream of the walk be driven by synthetic entries with no
/// filesystem. Only `path` and `size` are required, so bucketing and grouping can be tested with two
/// fields; the rest arrives when a real walk populates it.
///
/// `path` holds the raw bytes the walk produced. Never normalise it -- see ``PathOrder``.
public struct FileEntry: Hashable, Sendable {
    public let path: String
    public let size: Int64

    /// Volume and inode, when the walk could read them.
    ///
    /// `nil` on a volume that does not report them, which is not the same as "this file is unique":
    /// the hardlink partition has to treat an unknown identity as its own class rather than merging
    /// unknowns together.
    public let identity: FileIdentity?

    /// APFS content-stream identifier: **only clones and their originals share one**.
    ///
    /// This is the cheap clone detection the design needed and nearly did without. Applied *inside* a
    /// group whose SHA-256 already matches, it separates two independent copies (deleting one frees
    /// `size`) from two clones (deleting one frees nothing). `nil` off APFS, where the recoverable
    /// figure becomes an upper bound the UI has to label as such.
    public let contentIdentifier: Int64?

    /// Whether more than one directory entry points at this inode.
    ///
    /// A free pre-filter: `1` means no hardlink exists and the identity partition can skip the file
    /// entirely.
    public let linkCount: Int?

    /// Opaque per-file change counter, hashed into a `UInt64`.
    ///
    /// Strictly stronger than a modification date for cache invalidation. Verified on APFS: it
    /// advances on an append, on a same-length rewrite, and on a rewrite whose modification date was
    /// forced backwards with `utimes` -- which is exactly the `rsync -t` and `touch -r` case that
    /// makes an mtime-keyed cache serve a stale digest. `nil` where the volume does not support it.
    public let generation: UInt64?

    /// Modification time in whole nanoseconds since 1970, when available.
    public let modifiedNanoseconds: Int64?

    public init(
        path: String,
        size: Int64,
        identity: FileIdentity? = nil,
        contentIdentifier: Int64? = nil,
        linkCount: Int? = nil,
        generation: UInt64? = nil,
        modifiedNanoseconds: Int64? = nil
    ) {
        self.path = path
        self.size = size
        self.identity = identity
        self.contentIdentifier = contentIdentifier
        self.linkCount = linkCount
        self.generation = generation
        self.modifiedNanoseconds = modifiedNanoseconds
    }

    /// Whether this file certainly has no hardlink siblings.
    public var isCertainlyUnlinked: Bool { linkCount == 1 }

    /// The same entry with a different size, keeping every identity field.
    ///
    /// The hasher reads until end of file, so the length it saw can differ from the one the walk
    /// recorded. Rebuilding the entry from scratch to correct the size silently drops the identity,
    /// the generation and the modification time -- which makes the hash cache key nil and turns every
    /// store into a no-op. That looks exactly like a cold machine rather than a bug, and it is what
    /// the warm-scan test caught.
    public func withSize(_ newSize: Int64) -> FileEntry {
        FileEntry(
            path: path,
            size: newSize,
            identity: identity,
            contentIdentifier: contentIdentifier,
            linkCount: linkCount,
            generation: generation,
            modifiedNanoseconds: modifiedNanoseconds
        )
    }
}

/// Hashes an opaque Foundation identifier into a comparable `UInt64`.
///
/// `NSURLVolumeIdentifierKey` and `NSURLGenerationIdentifierKey` both come back as opaque `NSData`
/// -- 8 and 12 bytes respectively on APFS -- rather than as numbers. Foundation documents them as
/// comparable but not interpretable, so folding them is the only honest way to store them in a value
/// type.
enum OpaqueIdentifier {
    /// FNV-1a over the bytes. Not cryptographic and does not need to be: the only requirement is that
    /// equal inputs fold equally, and that unequal inputs almost never do.
    static func fold(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    /// Folds whatever Foundation handed back, if it is data at all.
    ///
    /// Takes `Any?` because that is what Foundation offers: `URLResourceValues.volumeIdentifier` and
    /// `.generationIdentifier` are typed `(any NSCopying & NSSecureCoding & NSObjectProtocol)?`, which
    /// is not `Sendable` and cannot be narrowed at the call site.
    static func fold(_ value: Any?) -> UInt64? {
        guard let data = value as? Data else { return nil }
        return fold(data)
    }
}
