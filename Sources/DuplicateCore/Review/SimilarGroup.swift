import Foundation

/// Files a perceptual scan found alike, joined through their pairs (#217).
///
/// **Why a review needs these at all.** The scan stores pairs, and three copies of one video are three pairs. Decided
/// one pair at a time, the third pair has no good answer: keeping A against B and A against C leaves B against C,
/// where keeping either "keeps" a file the earlier pairs remove -- a contradiction the apply then excludes. Measured on
/// this user's 84 perceptual scans, 8,288 video pairs fall into 1,254 groups, and one group of 23 copies was 253 pairs.
/// A group gets one decision, and one decision cannot contradict itself.
///
/// **Not every group is a set of copies.** A~B and B~C put A and C in one group even when nobody found them alike:
/// 46 of 683 image groups of three or more are chained like that, the worst 125 files over 19% of their possible
/// pairs. ``isFullyLinked`` says which kind a group is, and ``links`` keep the pairs that were actually found, so a
/// review can refuse to discard a file that is alike to nothing it keeps.
public struct SimilarGroup: Sendable, Hashable {
    /// One pair of the scan, by its index there and by the positions of its two files in ``files``.
    public struct Link: Sendable, Hashable {
        public let pairIndex: Int
        /// The pair's `file_a`.
        public let a: Int
        /// The pair's `file_b`.
        public let b: Int

        public init(pairIndex: Int, a: Int, b: Int) {
            self.pairIndex = pairIndex
            self.a = a
            self.b = b
        }
    }

    public let mediaKind: MediaKind
    /// The members, in byte order.
    public let files: [String]
    /// The pairs, in the scan's order.
    public let links: [Link]
    public let lowestSimilarity: Double
    public let highestSimilarity: Double

    public init(mediaKind: MediaKind, files: [String], links: [Link], similarities: [Double]) {
        self.mediaKind = mediaKind
        self.files = files
        self.links = links
        self.lowestSimilarity = similarities.min() ?? 0
        self.highestSimilarity = similarities.max() ?? 0
    }

    public var pairIndices: [Int] { links.map(\.pairIndex) }

    /// Whether every member was found alike to every other: a set of copies rather than a chain.
    public var isFullyLinked: Bool {
        links.count == files.count * (files.count - 1) / 2
    }

    /// The members found alike to `file`.
    public func neighbours(of file: Int) -> Set<Int> {
        var found = Set<Int>()
        for link in links {
            if link.a == file { found.insert(link.b) }
            if link.b == file { found.insert(link.a) }
        }
        return found
    }

    /// The pair joining two members, if the scan found one.
    public func link(between first: Int, and second: Int) -> Link? {
        links.first { ($0.a == first && $0.b == second) || ($0.a == second && $0.b == first) }
    }
}

public enum SimilarGrouping {
    /// The connected groups of a scan's pairs, in the order of each group's first pair.
    ///
    /// **Files are told apart by their bytes**, not by `String` equality, which compares canonical equivalence: an
    /// NFC and an NFD spelling of one name are two files on the external volume and one `String`, and merging them
    /// would put two files in one slot -- one of them reviewed under the other's name.
    public static func groups(of pairs: [SimilarPair]) -> [SimilarGroup] {
        var nodeOf: [[UInt8]: Int] = [:]
        var paths: [String] = []
        var parent: [Int] = []

        func node(_ path: String) -> Int {
            let key = Array(path.utf8)
            if let known = nodeOf[key] { return known }
            let created = paths.count
            nodeOf[key] = created
            paths.append(path)
            parent.append(created)
            return created
        }
        func root(_ start: Int) -> Int {
            var current = start
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        var ends: [(Int, Int)] = []
        ends.reserveCapacity(pairs.count)
        for pair in pairs {
            let a = node(pair.fileA)
            let b = node(pair.fileB)
            ends.append((a, b))
            let rootA = root(a)
            let rootB = root(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        // Pairs by group, in scan order, with groups ordered by their first pair.
        var groupOfRoot: [Int: Int] = [:]
        var members: [[Int]] = []
        for (index, (a, _)) in ends.enumerated() {
            let groupRoot = root(a)
            if groupOfRoot[groupRoot] == nil {
                groupOfRoot[groupRoot] = members.count
                members.append([])
            }
            members[groupOfRoot[groupRoot]!].append(index)
        }

        return members.map { pairIndices in
            var nodes: [Int] = []
            var seen = Set<Int>()
            for index in pairIndices {
                for end in [ends[index].0, ends[index].1] where seen.insert(end).inserted {
                    nodes.append(end)
                }
            }
            nodes.sort { PathOrder.lessThan(paths[$0], paths[$1]) }
            var position: [Int: Int] = [:]
            for (offset, node) in nodes.enumerated() { position[node] = offset }
            let links = pairIndices.map { index in
                SimilarGroup.Link(
                    pairIndex: index, a: position[ends[index].0]!, b: position[ends[index].1]!)
            }
            return SimilarGroup(
                mediaKind: pairs[pairIndices[0]].mediaKind,
                files: nodes.map { paths[$0] },
                links: links,
                similarities: pairIndices.map { pairs[$0].similarity })
        }
    }
}
