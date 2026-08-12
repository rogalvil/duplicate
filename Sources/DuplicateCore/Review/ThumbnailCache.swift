import Foundation

/// What identifies one thumbnail.
///
/// **Keyed on the digest, not the path, and that is the whole point.** Every file in a duplicate group has
/// identical content by construction, so a group of eight photos needs *one* thumbnail, not eight. Keying
/// on the path would send eight XPC round trips to `quicklookd` and hold eight copies of the same bitmap
/// for a group the user looks at once.
///
/// **The extension is part of the key, and that is not caution -- it is documented.**
/// `QLThumbnailGenerator.Request` says the content type "is derived from the file extension", and the
/// content type picks the thumbnail *provider*. So the same bytes named `report.pdf` and `report.dat`
/// legitimately render differently, and a cache keyed on the digest alone would show one under the other's
/// name. Rare in a duplicate group; free to get right.
public struct ThumbnailKey: Hashable, Sendable {
    public let digest: Digest32
    /// Lowercased, without the dot. Empty when the file has none.
    public let pathExtension: String
    /// Pixels, not points -- a cache shared between a Retina and a non-Retina screen must not confuse them.
    public let pixelSize: Int

    public init(digest: Digest32, pathExtension: String, pixelSize: Int) {
        self.digest = digest
        self.pathExtension = pathExtension.lowercased()
        self.pixelSize = pixelSize
    }

    /// The key for one file of a group whose content digest is already known.
    public init(digest: Digest32, path: String, pixelSize: Int) {
        self.init(
            digest: digest,
            pathExtension: ThumbnailPolicy.pathExtension(of: path),
            pixelSize: pixelSize
        )
    }
}

/// The sizing and eligibility rules, separated from anything that draws.
public enum ThumbnailPolicy {
    /// Smallest and largest thumbnail edge, in pixels.
    ///
    /// The floor keeps a request from being so small that the generator returns an icon instead. The
    /// ceiling bounds memory: at 4 bytes per pixel, 512 is 1 MB per thumbnail, and the cache holds several.
    public static let minimumPixels = 32
    public static let maximumPixels = 512

    /// Points times scale, clamped.
    ///
    /// Rounded to a multiple of 32 on purpose: a pane the user drags produces a continuum of point sizes,
    /// and keying the cache on each one would make every resize a cache miss and a fresh XPC call.
    public static func pixelSize(points: Double, scale: Double) -> Int {
        let raw = points * max(1, scale)
        let rounded = (Int(raw.rounded(.up)) + 31) / 32 * 32
        return min(maximumPixels, max(minimumPixels, rounded))
    }

    /// The last extension, lowercased, without the dot. Empty when there is none.
    ///
    /// A leading dot is not an extension: `.DS_Store` has none.
    public static func pathExtension(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let bytes = Array(name.utf8)
        var dot: Int?
        var index = 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: ".") { dot = index }
            index += 1
        }
        guard let dot, dot + 1 < bytes.count else { return "" }
        return String(decoding: bytes[(dot + 1)...], as: UTF8.self).lowercased()
    }
}

/// A bounded least-recently-used cache.
///
/// Generic and value-typed so it can be tested with integers rather than bitmaps: the eviction order is
/// the part worth testing, and a `CGImage` in a test proves nothing about it.
///
/// Bounded by **count**, not bytes. Every entry in one instance holds an image of the same pixel size by
/// construction -- the size is part of the key, and a pane asks for one size at a time -- so a count is a
/// byte bound with less bookkeeping.
public struct LRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Key: Value] = [:]
    /// Most recently used last. Linear on access, which is correct at this size: the cap is dozens, and a
    /// linked list would cost more in complexity than it saves in a scan of 64 keys.
    private var order: [Key] = []

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { storage.count }
    /// Keys from least to most recently used, for tests and diagnostics.
    public var keysByAge: [Key] { order }

    /// Reads a value and marks it as most recently used.
    public mutating func value(for key: Key) -> Value? {
        guard let value = storage[key] else { return nil }
        touch(key)
        return value
    }

    /// Reads without affecting the eviction order.
    public func peek(_ key: Key) -> Value? { storage[key] }

    /// Inserts or replaces, evicting the least recently used entry when full.
    ///
    /// - Returns: the key that was evicted, if any. Returned rather than swallowed so a caller can log or
    ///   assert on it; a cache that silently drops the entry the user is looking at is hard to diagnose.
    @discardableResult
    public mutating func insert(_ value: Value, for key: Key) -> Key? {
        if storage[key] != nil {
            storage[key] = value
            touch(key)
            return nil
        }
        var evicted: Key?
        if storage.count >= capacity, let oldest = order.first {
            storage.removeValue(forKey: oldest)
            order.removeFirst()
            evicted = oldest
        }
        storage[key] = value
        order.append(key)
        return evicted
    }

    public mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}
