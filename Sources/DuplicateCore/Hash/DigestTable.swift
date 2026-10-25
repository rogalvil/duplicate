/// The hash cache's digests in memory: one array sorted by key, plus a small dictionary for what arrived since.
///
/// **A dictionary was the largest thing in the process at scale** (#161). Its buckets are a power of two above
/// `count / 0.75`, so 800,000 keys of 40 bytes with 32-byte digests sat in 2²¹ slots, ~150 MB, and loading the
/// cache took a warm scan from 29 to 354 MB before it walked anything. The same records in a sorted array are
/// 72 bytes each with nothing around them -- 58 MB -- and a binary search is twenty comparisons.
///
/// Inserts would cost a shift each, so new keys wait in `recent` and are merged in once it grows. The merge runs
/// from the back of the array, in place: the table never exists twice. A key is in exactly one of the two, which
/// keeps every comparison strict.
struct DigestTable {
    private var sorted: [HashCacheRecord] = []
    private var recent: [HashCacheKey: Digest32] = [:]
    /// The smallest batch worth a merge. The real trigger also grows with the table, so a cold scan storing
    /// 800,000 digests merges a dozen times rather than fifty.
    private let minimumMerge: Int

    init(minimumMerge: Int = 16_384) {
        self.minimumMerge = minimumMerge
    }

    /// A table over records already sorted by key, with no key twice.
    init(sortedUnique records: [HashCacheRecord], minimumMerge: Int = 16_384) {
        self.sorted = records
        self.minimumMerge = minimumMerge
    }

    var count: Int { sorted.count + recent.count }

    subscript(key: HashCacheKey) -> Digest32? {
        if let digest = recent[key] { return digest }
        return index(of: key).map { sorted[$0].digest }
    }

    mutating func set(_ digest: Digest32, for key: HashCacheKey) {
        if let index = index(of: key) {
            sorted[index] = HashCacheRecord(key: key, digest: digest)
            return
        }
        recent[key] = digest
        if recent.count >= max(minimumMerge, sorted.count / 8) { merge() }
    }

    /// Room for `count` more keys in the array, so the merges that follow do not reallocate it.
    mutating func reserve(_ count: Int) {
        sorted.reserveCapacity(sorted.count + recent.count + count)
    }

    /// Drops every key the predicate selects. The order of what is left is unchanged.
    mutating func removeAll(where shouldRemove: (HashCacheKey) -> Bool) {
        merge()
        sorted.removeAll { shouldRemove($0.key) }
    }

    /// Every record, in key order.
    mutating func records() -> [HashCacheRecord] {
        merge()
        return sorted
    }

    private func index(of key: HashCacheKey) -> Int? {
        var low = 0
        var high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if HashCacheKey.isOrdered(sorted[middle].key, key) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < sorted.count && sorted[low].key == key ? low : nil
    }

    /// Moves `recent` into the array, largest first, so each element is placed once.
    private mutating func merge() {
        guard !recent.isEmpty else { return }
        var incoming = recent.map { HashCacheRecord(key: $0.key, digest: $0.value) }
        recent.removeAll(keepingCapacity: true)
        incoming.sort { HashCacheKey.isOrdered($0.key, $1.key) }

        var old = sorted.count - 1
        var new = incoming.count - 1
        // Placeholders, overwritten below: the array grows once and the merge fills it from the end.
        sorted.append(contentsOf: incoming)
        var slot = sorted.count - 1
        while new >= 0 {
            if old >= 0, HashCacheKey.isOrdered(incoming[new].key, sorted[old].key) {
                sorted[slot] = sorted[old]
                old -= 1
            } else {
                sorted[slot] = incoming[new]
                new -= 1
            }
            slot -= 1
        }
    }
}

extension HashCacheKey {
    /// A total order on keys: the order the table is kept in, and the order a compacted file is written in.
    static func isOrdered(_ a: HashCacheKey, _ b: HashCacheKey) -> Bool {
        if a.volume != b.volume { return a.volume < b.volume }
        if a.inode != b.inode { return a.inode < b.inode }
        if a.size != b.size { return a.size < b.size }
        if a.mtimeNanoseconds != b.mtimeNanoseconds {
            return a.mtimeNanoseconds < b.mtimeNanoseconds
        }
        return a.generation < b.generation
    }
}
