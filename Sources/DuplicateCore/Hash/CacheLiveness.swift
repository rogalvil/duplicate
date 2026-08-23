import Foundation

/// Counts how many rows of a cache still describe a file that exists.
///
/// **Written to decide whether pruning is worth building, not as a step towards it.** The two caches grow one
/// row per `(file, version)` ever seen and nothing removes one, so the question is how fast that turns into
/// waste -- and the honest way to answer it is to look at the rows on this machine rather than to reason about
/// them.
///
/// **A cache row holds no path.** The key is `(volume, inode, size, mtime, generation)`, so asking "does this
/// file still exist" means resolving an inode, and macOS resolves inodes through `/.vol/<st_dev>/<inode>`. The
/// row's volume is a *fold* of Foundation's opaque volume identifier, not a device number, so a mapping has to
/// be built from the volumes mounted right now: for each one, fold its identifier the same way the walker did
/// and pair it with the `st_dev` from `stat`.
///
/// **Which is exactly where the danger lives.** A row whose volume is not mounted cannot be checked at all, and
/// this user's corpus is on an external disk: treating unresolvable as dead would throw away the cache that
/// took 177 seconds to build the moment WD12TB is unplugged. So those rows are counted separately and never
/// judged.
public enum CacheLiveness {

    public struct Report: Sendable, Equatable {
        public var totalRows = 0
        /// Rows whose volume is mounted right now, so their liveness is knowable.
        public var checkableRows = 0
        /// Rows on a volume that is not mounted. **Unknowable, never dead.**
        public var unmountedRows = 0
        /// Rows whose inode still resolves to a file.
        public var liveRows = 0
        /// Rows whose inode no longer resolves **because nothing is there**: `ENOENT`.
        public var deadRows = 0
        /// Rows whose inode could not be resolved for any other reason -- permission, most likely.
        ///
        /// **Counted apart from dead, and that distinction is what makes pruning safe.** A `stat` of
        /// `/.vol/<dev>/<inode>` fails with `EACCES` when the app has lost access to a directory it once
        /// hashed: revoke Desktop access in System Settings and every row for a file there stops resolving.
        /// Reading that as "deleted" would delete a cache row for a file sitting right where it always was --
        /// harmless once, and the same shape of reasoning that would wipe the cache of an unplugged disk.
        public var unresolvableRows = 0
        /// Rows whose inode resolves but whose **size** no longer matches: an older version of a file that is
        /// still there.
        ///
        /// **Size only, and never mtime.** The key's `mtimeNanoseconds` comes from Foundation's
        /// `contentModificationDate`, which is a `Date` -- a `Double` whose granularity around 1.79e18
        /// nanoseconds is a few hundred nanoseconds -- while `stat` reports an exact `st_mtimespec`. Comparing
        /// them is comparing a rounded number to an unrounded one, and they disagree for files that never
        /// changed. A first version of this compared both and classified **every live row as superseded**, which
        /// as a pruning rule would have deleted the entire cache. A test caught it; the arithmetic is the
        /// finding.
        public var supersededRows = 0

        /// Dead plus superseded, over what could be checked at all.
        public var wasteFraction: Double {
            guard checkableRows > 0 else { return 0 }
            return Double(deadRows + supersededRows) / Double(checkableRows)
        }
    }

    /// Folded volume identifier to the device numbers it can appear under.
    ///
    /// **A folded volume identifier does not map to one device, and finding that out was the whole trick.**
    /// macOS firmlinks the boot volume: `/` and `/private/tmp` report the *same* volume identifier and sit on
    /// *different* `st_dev` -- the sealed system volume and the Data volume. A map built from
    /// `mountedVolumeURLs` alone therefore looks up a Data-volume inode under the system volume's device, where
    /// nothing resolves, and every one of those rows reads as deleted. The first version of this measurement did
    /// exactly that and reported waste that was not there.
    ///
    /// So the map is built from **every mount** `getmntinfo` reports, and a folded identifier keeps a list of
    /// devices. A row is only dead when it resolves under none of them.
    public static func mountedVolumes() -> [UInt64: [Int32]] {
        var mapping: [UInt64: [Int32]] = [:]
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return mapping }
        for index in 0..<Int(count) {
            var mount = buffer[index]
            let path = withUnsafePointer(to: &mount.f_mntonname) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard
                let values = try? URL(filePath: path).resourceValues(forKeys: [
                    .volumeIdentifierKey
                ]),
                let folded = OpaqueIdentifier.fold(values.volumeIdentifier)
            else { continue }
            var status = stat()
            guard stat(path, &status) == 0 else { continue }
            if !(mapping[folded]?.contains(status.st_dev) ?? false) {
                mapping[folded, default: []].append(status.st_dev)
            }
        }
        return mapping
    }

    /// Classifies keys against the filesystem. **The one implementation**, shared by both caches.
    ///
    /// Two copies of this would be two chances to disagree about whether a row is dead, and one of those
    /// answers deletes it -- the same argument that collapsed the two folder-manifest builders into one.
    public static func classify(keys: [HashCacheKey]) -> Report {
        var report = Report()
        report.totalRows = keys.count
        let volumes = mountedVolumes()
        for key in keys {
            guard let devices = volumes[key.volume] else {
                report.unmountedRows += 1
                continue
            }
            report.checkableRows += 1
            switch resolve(key: key, devices: devices) {
            case .live: report.liveRows += 1
            case .lengthChanged: report.supersededRows += 1
            case .gone: report.deadRows += 1
            case .cannotTell: report.unresolvableRows += 1
            }
        }
        return report
    }

    /// What the filesystem says about one key.
    public enum Resolution: Sendable, Equatable {
        /// The inode resolves and the length still matches.
        case live
        /// The inode resolves and the length does not: an older version of a file that is still there.
        ///
        /// **Length, never mtime.** The key's `mtimeNanoseconds` comes from Foundation's
        /// `contentModificationDate`, a `Date` -- a `Double` whose granularity near 1.79e18 nanoseconds is
        /// hundreds of nanoseconds -- while `stat` reports an exact `st_mtimespec`. Comparing them is comparing a
        /// rounded number to an unrounded one, and the first version of this called **every live row superseded**,
        /// which as a pruning rule deletes the whole cache.
        case lengthChanged
        /// `ENOENT` under every device the volume can appear as. The only proof a file is gone.
        case gone
        /// The inode failed to resolve for some other reason -- permission, most likely. **Never dead.**
        case cannotTell
    }

    /// Resolves one key through `/.vol`, trying every device its volume can appear as.
    public static func resolve(key: HashCacheKey, devices: [Int32]) -> Resolution {
        var status = stat()
        var sawOnlyMissing = true
        for device in devices {
            if stat("/.vol/\(device)/\(key.inode)", &status) == 0 {
                return Int64(status.st_size) == key.size ? .live : .lengthChanged
            }
            if errno != ENOENT { sawOnlyMissing = false }
        }
        return sawOnlyMissing ? .gone : .cannotTell
    }

    /// Reads a digest cache file and reports how much of it is still true. Never writes.
    public static func measure(hashCacheAt url: URL) -> Report {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return Report() }
        let bytes = [UInt8](data)
        guard bytes.count > HashCacheFormat.headerSize else { return Report() }
        let rows = (bytes.count - HashCacheFormat.headerSize) / HashCacheFormat.recordSize
        var keys: [HashCacheKey] = []
        keys.reserveCapacity(rows)
        for index in 0..<rows {
            let start = HashCacheFormat.headerSize + index * HashCacheFormat.recordSize
            guard
                let record = HashCacheFormat.decode(
                    bytes[start..<(start + HashCacheFormat.recordSize)])
            else { continue }
            keys.append(record.key)
        }
        return classify(keys: keys)
    }

    /// The same for the perceptual cache, whose rows are 112 bytes and hold hashes rather than a digest.
    ///
    /// The salt is not checked. A file written under different pipeline parameters is discarded whole on load,
    /// so its liveness means nothing to a scan -- but counting its rows is still the honest answer to "how much
    /// of this file describes files that exist".
    public static func measure(perceptualCacheAt url: URL) -> Report {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return Report() }
        let bytes = [UInt8](data)
        guard bytes.count > PerceptualCacheFormat.headerSize else { return Report() }
        let rows =
            (bytes.count - PerceptualCacheFormat.headerSize) / PerceptualCacheFormat.recordSize
        var keys: [HashCacheKey] = []
        keys.reserveCapacity(rows)
        for index in 0..<rows {
            let start =
                PerceptualCacheFormat.headerSize + index * PerceptualCacheFormat.recordSize
            let row = Array(bytes[start..<(start + PerceptualCacheFormat.recordSize)])
            guard let decoded = PerceptualCacheFormat.decode(row) else { continue }
            keys.append(decoded.key)
        }
        return classify(keys: keys)
    }
}
