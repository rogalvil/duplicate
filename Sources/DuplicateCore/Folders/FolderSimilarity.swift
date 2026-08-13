import Foundation

/// Two folders that share content, in the shape the CLI writes.
public struct FolderPair: Sendable, Hashable {
    public let folderA: String
    public let folderB: String
    /// Dice coefficient: `2 * matching / (totalA + totalB)`.
    public let similarity: Double
    /// Files present in both with the same digest.
    public let matching: Int
    /// Relative paths only in A, sorted.
    public let onlyInA: [String]
    /// Relative paths only in B, sorted.
    public let onlyInB: [String]
    /// Relative paths in both whose digests differ, sorted.
    public let changed: [String]
    public let totalA: Int
    public let totalB: Int

    public init(
        folderA: String, folderB: String, similarity: Double, matching: Int,
        onlyInA: [String], onlyInB: [String], changed: [String], totalA: Int, totalB: Int
    ) {
        self.folderA = folderA
        self.folderB = folderB
        self.similarity = similarity
        self.matching = matching
        self.onlyInA = onlyInA
        self.onlyInB = onlyInB
        self.changed = changed
        self.totalA = totalA
        self.totalB = totalB
    }
}

/// The bound that makes the pair search affordable.
public enum DiceBounds {
    /// The largest ratio of file counts a pair can have and still reach `threshold`.
    ///
    /// From `Dice = 2M/(|A|+|B|) >= t` and `M <= min(|A|,|B|)`:
    ///
    /// ```
    /// 2·min(|A|,|B|) >= t·(|A|+|B|)   =>   |B|/|A| <= (2−t)/t     for |B| >= |A|
    /// ```
    ///
    /// At `t = 0.9` that is **1.2222**: any pair whose file counts differ by more than 22% cannot reach the
    /// threshold, and is discarded by an integer test before anything is compared. The derivation is what
    /// makes the discard safe -- it is not a heuristic.
    public static func maximumCountRatio(threshold: Double) -> Double {
        guard threshold > 0 else { return .infinity }
        return (2 - threshold) / threshold
    }

    /// Whether two file counts could possibly reach `threshold`.
    public static func couldReach(threshold: Double, countA: Int, countB: Int) -> Bool {
        guard countA + countB > 0 else { return false }
        let smaller = Double(min(countA, countB))
        let larger = Double(max(countA, countB))
        guard smaller > 0 else { return false }
        return larger / smaller <= maximumCountRatio(threshold: threshold)
    }
}

/// Finds folders whose contents overlap.
///
/// **The redesign, and why it is not the obvious loop.** The CLI builds a `{relpath: digest}` dictionary for
/// every directory and compares all `D²` pairs (`folder_duplicates.py:144-169`). Building those dictionaries
/// hashes every file once per ancestor directory -- a file eight levels deep is hashed eight times -- and
/// holds `Θ(N·d)` strings.
///
/// This computes the same numbers from one pass:
///
/// **The reformulation.** An element of `FP(a) ∩ FP(b)` is a pair of files with equal digest *and* equal
/// relative path. A relative path always ends in the file name, so **equal relative paths force equal
/// basenames**. Therefore only pairs of files sharing a digest *and* a basename can contribute anything to
/// any pair of directories.
///
/// **The count is exact, not a bound.** For files `fa` and `fb` in such a class, let `K` be the number of
/// components in their longest common path suffix. The pair contributes exactly 1 to `matching(a, b)` for
/// exactly the `K` pairs of ancestors at depths 1...K above them, and to no other pair.
///
/// > **Proof of completeness.** If `Dice(a,b) >= t > 0` then `matching(a,b) >= 1`, so there exist
/// > `fa ∈ subtree(a)`, `fb ∈ subtree(b)` with equal digests and equal relative paths. Equal relative paths
/// > imply equal basenames, so the pair lies in some `(digest, basename)` class of size at least two and is
/// > enumerated. Equal relative paths of `k` components imply the common suffix is at least `k` components,
/// > so `k <= K` and the inner loop reaches `(a, b)` at its step `k`. Therefore no pair above any positive
/// > threshold is missed. ∎
///
/// **The honest worst case.** A large `(digest, basename)` class is quadratic in its own size: ten thousand
/// identical `__init__.py` files give fifty million pairs. `maximumClassSize` truncates such a class and
/// **says so in the result**, rather than returning quietly wrong answers.
public enum FolderSimilarity {

    /// A class that was too large to enumerate.
    public struct TruncatedClass: Sendable, Hashable {
        public let basename: String
        public let fileCount: Int
    }

    public struct Candidates: Sendable {
        /// `matching(a, b)` for every pair that shares at least one file, keyed by the two node indices with
        /// `a < b`.
        public let matching: [Pair: Int]
        /// Classes that were truncated, so a caller can warn instead of implying completeness.
        public let truncated: [TruncatedClass]

        public init(matching: [Pair: Int], truncated: [TruncatedClass]) {
            self.matching = matching
            self.truncated = truncated
        }
    }

    /// An unordered pair of directory indices, normalised so `a < b`.
    public struct Pair: Sendable, Hashable {
        public let a: Int
        public let b: Int

        public init(_ first: Int, _ second: Int) {
            a = min(first, second)
            b = max(first, second)
        }
    }

    /// How many files one `(digest, basename)` class may hold before it is truncated.
    ///
    /// 512 gives 130,816 pairs for the worst class, which is bounded work. The filter on junk names removes
    /// the usual offenders before this ever triggers; when it does trigger, the result says so.
    public static let maximumClassSize = 512

    /// Counts `matching(a, b)` for every pair of directories that shares a file.
    ///
    /// This is the exact number the CLI computes, from one pass over the files.
    public static func candidates(in tree: DirectoryTree) -> Candidates {
        // Group by (digest, basename): the only pairs that can contribute anything.
        var classes: [ClassKey: [Int]] = [:]
        for (index, file) in tree.files.enumerated() {
            let name = (file.path as NSString).lastPathComponent
            classes[ClassKey(digest: file.digest, basename: name), default: []].append(index)
        }

        // The directory each file sits in, so ancestors can be walked without touching strings.
        var directoryOfFile = [Int](repeating: 0, count: tree.files.count)
        for (index, node) in tree.nodes.enumerated() {
            for file in node.ownFiles { directoryOfFile[file] = index }
        }

        var matching: [Pair: Int] = [:]
        var truncated: [TruncatedClass] = []

        for (key, members) in classes where members.count > 1 {
            guard members.count <= maximumClassSize else {
                truncated.append(TruncatedClass(basename: key.basename, fileCount: members.count))
                continue
            }
            for i in members.indices {
                for j in (i + 1)..<members.count {
                    let fa = members[i]
                    let fb = members[j]
                    // Walk both chains of ancestors upward in step. The k-th step pairs the directories that
                    // are k levels above each file -- which is exactly the pair for which both files have the
                    // same k-component relative path, as long as the components matched all the way up.
                    var da = directoryOfFile[fa]
                    var db = directoryOfFile[fb]
                    var componentsA = pathComponents(tree.files[fa].path)
                    var componentsB = pathComponents(tree.files[fb].path)
                    // The basename matched by construction, so start one level up from the file.
                    componentsA.removeLast()
                    componentsB.removeLast()

                    while true {
                        // Same directory on both sides means the two files are in one folder: no pair.
                        if da != db { matching[Pair(da, db), default: 0] += 1 }

                        guard let nextA = tree.nodes[da].parent, let nextB = tree.nodes[db].parent,
                            let lastA = componentsA.last, let lastB = componentsB.last,
                            PathOrder.equal(lastA, lastB)
                        else { break }
                        componentsA.removeLast()
                        componentsB.removeLast()
                        da = nextA
                        db = nextB
                    }
                }
            }
        }
        return Candidates(matching: matching, truncated: truncated)
    }

    /// The exact comparison, for one pair.
    ///
    /// Reads the two subtrees as contiguous slices, which is what the depth-first layout is for. Produces
    /// the CLI's numbers, including `nil` when both folders are empty -- `_compare_pair` returns `None`
    /// there rather than dividing by zero.
    public static func compare(_ a: Int, _ b: Int, in tree: DirectoryTree) -> FolderPair? {
        guard tree.nodes.indices.contains(a), tree.nodes.indices.contains(b) else { return nil }
        let nodeA = tree.nodes[a]
        let nodeB = tree.nodes[b]
        let totalA = nodeA.subtreeFiles.count
        let totalB = nodeB.subtreeFiles.count
        guard totalA + totalB > 0 else { return nil }

        var digestsA: [String: Digest32] = [:]
        digestsA.reserveCapacity(totalA)
        for index in nodeA.subtreeFiles {
            digestsA[PathElision.relative(tree.files[index].path, to: nodeA.path)] =
                tree.files[index].digest
        }

        var matching = 0
        var changed: [String] = []
        var onlyInB: [String] = []
        var seen: Set<String> = []
        seen.reserveCapacity(totalB)
        for index in nodeB.subtreeFiles {
            let relative = PathElision.relative(tree.files[index].path, to: nodeB.path)
            seen.insert(relative)
            guard let other = digestsA[relative] else {
                onlyInB.append(relative)
                continue
            }
            if other == tree.files[index].digest {
                matching += 1
            } else {
                changed.append(relative)
            }
        }
        let onlyInA = digestsA.keys.filter { !seen.contains($0) }

        return FolderPair(
            folderA: nodeA.path,
            folderB: nodeB.path,
            similarity: Double(2 * matching) / Double(totalA + totalB),
            matching: matching,
            onlyInA: PathOrder.sorted(onlyInA),
            onlyInB: PathOrder.sorted(onlyInB),
            changed: PathOrder.sorted(changed),
            totalA: totalA,
            totalB: totalB
        )
    }

    /// What a search found.
    public struct Result: Sendable {
        public let pairs: [FolderPair]
        public let truncated: [TruncatedClass]
        /// How many pairs survived candidate generation and the size bound, before the exact comparison.
        public let examinedPairs: Int

        public init(pairs: [FolderPair], truncated: [TruncatedClass], examinedPairs: Int) {
            self.pairs = pairs
            self.truncated = truncated
            self.examinedPairs = examinedPairs
        }
    }

    /// Every pair at or above `threshold`.
    ///
    /// Four stages: enumerate candidates, drop nested pairs, drop pairs the count bound rules out, then
    /// compare the survivors exactly.
    ///
    /// Sorted by similarity descending like the CLI, with ties broken on the two paths by bytes. **The CLI
    /// leaves ties in `os.walk` order**, which is not reproducible across machines; a deterministic order
    /// is a divergence in output order only, and the alternative is a file that differs between runs.
    ///
    /// **Within a pair, `folderA` is the byte-smaller path, and that is a safety property rather than
    /// cosmetics.** `rav duplicate folders-move` keeps `folder_a` and moves `folder_b` to quarantine, so
    /// orientation in a shared document decides which folder a caller destroys. Taking it from the node
    /// indices would take it from the walk's enumeration order, which nothing promises to reproduce on
    /// another machine or after the tree changes. Neither side is semantically the survivor -- the CLI's
    /// own orientation is `os.walk` order -- but arbitrary and reproducible beats arbitrary and
    /// enumerator-dependent when a command deletes one of the two.
    public static func find(
        in tree: DirectoryTree,
        threshold: Double = 0.9
    ) throws -> Result {
        let candidates = candidates(in: tree)
        var pairs: [FolderPair] = []
        var examined = 0

        for (pair, _) in candidates.matching {
            try Task.checkCancellation()
            // The root is never a candidate, matching `_collect_subdirs`.
            guard pair.a != 0, pair.b != 0 else { continue }
            // Nested folders are skipped outright, like the CLI.
            guard !tree.areNested(pair.a, pair.b) else { continue }
            guard
                DiceBounds.couldReach(
                    threshold: threshold,
                    countA: tree.subtreeFileCount(pair.a),
                    countB: tree.subtreeFileCount(pair.b)
                )
            else { continue }

            examined += 1
            // Orient by bytes before comparing, so `only_in_a` and `only_in_b` follow the same rule as the
            // two paths and a caller that acts on `folder_b` acts on a reproducible choice.
            let (first, second) =
                PathOrder.lessThan(tree.nodes[pair.a].path, tree.nodes[pair.b].path)
                ? (pair.a, pair.b) : (pair.b, pair.a)
            guard let compared = compare(first, second, in: tree),
                compared.similarity >= threshold
            else { continue }
            pairs.append(compared)
        }

        pairs.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if !PathOrder.equal($0.folderA, $1.folderA) {
                return PathOrder.lessThan($0.folderA, $1.folderA)
            }
            return PathOrder.lessThan($0.folderB, $1.folderB)
        }
        return Result(
            pairs: pairs, truncated: candidates.truncated, examinedPairs: examined)
    }

    // MARK: - Private

    private struct ClassKey: Hashable {
        let digest: Digest32
        let basename: String
    }

    private static func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
