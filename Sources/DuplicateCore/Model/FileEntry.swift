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
///
/// **72 bytes, not 112** (#161). Five optional fields cost 16 bytes each -- an 8-byte value and a tag padded to
/// the next 8 -- so the optional metadata was a third of every entry, and a scan holds several lists of every
/// file at once. They are stored as plain values beside one bitmask that says which are present, and read back
/// through the same optional properties, so nothing outside this type can tell. A value that is absent is
/// stored as zero, which keeps the synthesised equality and hash meaning exactly what they meant before.
public struct FileEntry: Hashable, Sendable {
    public let path: String
    public let size: Int64

    private let volumeStorage: UInt64
    private let inodeStorage: UInt64
    private let contentIdentifierStorage: Int64
    private let generationStorage: UInt64
    private let modifiedStorage: Int64
    /// Clamped to 32 bits: the only questions asked of it are "is it one" and "is it more than one", and no
    /// volume this app reads allows four billion names for a file.
    private let linkCountStorage: UInt32
    private let present: Present

    private struct Present: OptionSet, Hashable, Sendable {
        let rawValue: UInt8
        static let identity = Present(rawValue: 1 << 0)
        static let contentIdentifier = Present(rawValue: 1 << 1)
        static let linkCount = Present(rawValue: 1 << 2)
        static let generation = Present(rawValue: 1 << 3)
        static let modified = Present(rawValue: 1 << 4)
    }

    /// Volume and inode, when the walk could read them.
    ///
    /// `nil` on a volume that does not report them, which is not the same as "this file is unique":
    /// the hardlink partition has to treat an unknown identity as its own class rather than merging
    /// unknowns together.
    public var identity: FileIdentity? {
        present.contains(.identity) ? FileIdentity(volume: volumeStorage, inode: inodeStorage) : nil
    }

    /// APFS content-stream identifier: **only clones and their originals share one**.
    ///
    /// This is the cheap clone detection the design needed and nearly did without. Applied *inside* a
    /// group whose SHA-256 already matches, it separates two independent copies (deleting one frees
    /// `size`) from two clones (deleting one frees nothing). `nil` off APFS, where the recoverable
    /// figure becomes an upper bound the UI has to label as such.
    public var contentIdentifier: Int64? {
        present.contains(.contentIdentifier) ? contentIdentifierStorage : nil
    }

    /// Whether more than one directory entry points at this inode.
    ///
    /// A free pre-filter: `1` means no hardlink exists and the identity partition can skip the file
    /// entirely.
    public var linkCount: Int? {
        present.contains(.linkCount) ? Int(linkCountStorage) : nil
    }

    /// Opaque per-file change counter, hashed into a `UInt64`.
    ///
    /// Strictly stronger than a modification date for cache invalidation. Verified on APFS: it
    /// advances on an append, on a same-length rewrite, and on a rewrite whose modification date was
    /// forced backwards with `utimes` -- which is exactly the `rsync -t` and `touch -r` case that
    /// makes an mtime-keyed cache serve a stale digest. `nil` where the volume does not support it.
    public var generation: UInt64? {
        present.contains(.generation) ? generationStorage : nil
    }

    /// Modification time in whole nanoseconds since 1970, when available.
    public var modifiedNanoseconds: Int64? {
        present.contains(.modified) ? modifiedStorage : nil
    }

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
        var present: Present = []
        volumeStorage = identity?.volume ?? 0
        inodeStorage = identity?.inode ?? 0
        if identity != nil { present.insert(.identity) }
        contentIdentifierStorage = contentIdentifier ?? 0
        if contentIdentifier != nil { present.insert(.contentIdentifier) }
        linkCountStorage = linkCount.map { UInt32(clamping: $0) } ?? 0
        if linkCount != nil { present.insert(.linkCount) }
        generationStorage = generation ?? 0
        if generation != nil { present.insert(.generation) }
        modifiedStorage = modifiedNanoseconds ?? 0
        if modifiedNanoseconds != nil { present.insert(.modified) }
        self.present = present
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
