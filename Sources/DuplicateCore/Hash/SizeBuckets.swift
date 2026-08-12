/// Finds the files worth hashing: those sharing a byte length with at least one other file.
///
/// Ports the first stage of `find_duplicates` (`src/rav/core/duplicates.py:57-79`), but by sorting
/// rather than by building a dictionary of arrays.
///
/// The CLI uses `defaultdict(list)`. For 800,000 files that allocates 800,000 arrays, nearly all of
/// them holding a single element -- and a singleton Swift `Array` is a heap allocation of its own, so
/// the mostly-empty buckets alone cost tens of megabytes before any path is stored. Sorting an index
/// array and walking it for runs of equal size allocates nothing per bucket, and it hands the sort
/// order to the grouping stage for free.
public enum SizeBuckets {
    /// Files that share a size, grouped, with singletons dropped.
    ///
    /// Ordered by descending size so the largest candidates are hashed first: a scan cancelled halfway
    /// has then already covered the groups that matter most. Within a run, entries keep byte order.
    ///
    /// - Parameter minimumSize: entries smaller than this are dropped before bucketing. The CLI
    ///   defaults to 1, which excludes zero-byte files -- of which a real disk has hundreds, all
    ///   trivially identical and none worth a decision.
    public static func candidates(in entries: [FileEntry], minimumSize: Int64 = 1) -> [[FileEntry]]
    {
        var indices = entries.indices.filter { entries[$0].size >= minimumSize }
        indices.sort { left, right in
            let a = entries[left]
            let b = entries[right]
            if a.size != b.size { return a.size > b.size }
            return PathOrder.lessThan(a.path, b.path)
        }

        var runs: [[FileEntry]] = []
        var start = 0
        while start < indices.count {
            var end = start + 1
            let size = entries[indices[start]].size
            while end < indices.count, entries[indices[end]].size == size {
                end += 1
            }
            // A bucket of one is never hashed. That invariant is most of the reason a scan is fast at
            // all, and it has its own test.
            if end - start > 1 {
                runs.append(indices[start..<end].map { entries[$0] })
            }
            start = end
        }
        return runs
    }

    /// How many files would be hashed, which is the denominator the progress bar needs.
    ///
    /// The CLI computes the same count (`src/rav/core/duplicates.py:72-73`) so the hashing phase can
    /// show a determinate total while the indexing phase cannot.
    public static func candidateCount(in entries: [FileEntry], minimumSize: Int64 = 1) -> Int {
        candidates(in: entries, minimumSize: minimumSize).reduce(0) { $0 + $1.count }
    }
}
