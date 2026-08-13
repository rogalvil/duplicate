import Foundation

/// Finds which pairs of perceptual hashes are worth comparing, instead of comparing all of them.
///
/// **The bound, and it is a proof rather than a heuristic.** Split the 64 bits into `k` bands. If
/// `popcount(x ^ y) <= T`, the differing bits touch at most `T` bands, so at least `k - T` bands are identical.
/// To guarantee **at least one** identical band, take `k >= T + 1`. At the CLI's threshold of 5 that is **six
/// bands**, of 11, 11, 11, 11, 10 and 10 bits. So indexing every hash by each of its six band values and
/// looking only at hashes that share a band value cannot miss a pair within the threshold.
///
/// **Why bands this wide.** Six bands of 11 bits give 2,048 buckets each; eight bands of 8 bits would give 256,
/// so every bucket would hold eight times as many unrelated hashes and the candidate list would fill with work
/// the exact comparison then throws away. Wider bands are more selective, and `T + 1` is the fewest the proof
/// allows.
///
/// **Identical hashes collapse into one class first, which matters more than the asymptotics.** Every black
/// video frame, every letterboxed title card and every solid-colour image produces the *same* `UInt64`. A naive
/// index puts ten thousand of them in one bucket and then enumerates fifty million pairs inside it. Collapsing
/// them means the index holds one entry for the class, and the pairs inside a class need no comparison at all --
/// they are distance zero by construction.
///
/// **Each pair is emitted once, without a `Set`.** A pair that collides in several bands is accepted only from
/// the first band it collides in: on finding it in band `j`, check bands `0 ..< j` and skip if any of them also
/// matches. That is at most six comparisons of two `UInt64` values already in registers, against hashing a pair
/// into a set and growing it to millions of entries.
public struct MultiIndexLSH: Sendable {

    /// The largest Hamming distance a pair may have and still have to be found. The CLI's default is 5.
    public let maximumDistance: Int
    /// Bit counts per band, summing to 64.
    public let bandWidths: [Int]

    public init(maximumDistance: Int = 5) {
        precondition(maximumDistance >= 0, "a distance cannot be negative")
        precondition(
            maximumDistance < PerceptualHash.bitCount,
            "a threshold of \(maximumDistance) accepts every pair of 64-bit hashes")
        self.maximumDistance = maximumDistance
        bandWidths = MultiIndexLSH.bandWidths(for: maximumDistance)
    }

    /// `T + 1` bands splitting 64 bits as evenly as possible, the wider ones first.
    ///
    /// The pigeonhole argument needs `T + 1`; more bands would be correct and less selective, fewer would be
    /// wrong.
    public static func bandWidths(for maximumDistance: Int) -> [Int] {
        let count = maximumDistance + 1
        let base = PerceptualHash.bitCount / count
        let remainder = PerceptualHash.bitCount % count
        return (0..<count).map { $0 < remainder ? base + 1 : base }
    }

    /// A set of items whose hashes are byte-identical.
    public struct HashClass: Sendable, Hashable {
        public let hash: PerceptualHash
        /// Indices into the caller's array, ascending.
        public let members: [Int]

        public init(hash: PerceptualHash, members: [Int]) {
            self.hash = hash
            self.members = members
        }
    }

    /// A candidate pair of classes, `a < b` by class index.
    public struct ClassPair: Sendable, Hashable {
        public let a: Int
        public let b: Int

        public init(_ first: Int, _ second: Int) {
            a = min(first, second)
            b = max(first, second)
        }
    }

    public struct Candidates: Sendable {
        public let classes: [HashClass]
        /// Class pairs that share at least one band, so they might be within the threshold.
        public let pairs: [ClassPair]
        /// How many pairs of classes exist at all, for reporting how much work the index avoided.
        public let totalClassPairs: Int
    }

    /// Indexes the hashes and returns the pairs worth comparing exactly.
    ///
    /// Never misses a pair within `maximumDistance` -- that is the pigeonhole proof above, and a property test
    /// checks it against brute force over random hashes.
    public func candidates(for hashes: [PerceptualHash]) -> Candidates {
        let classes = equivalenceClasses(of: hashes)
        guard classes.count > 1 else {
            return Candidates(classes: classes, pairs: [], totalClassPairs: 0)
        }

        // One bucket table per band: band value -> class indices carrying it.
        let offsets = bandOffsets()
        var tables = [[UInt64: [Int]]](repeating: [:], count: bandWidths.count)
        for (index, item) in classes.enumerated() {
            for band in bandWidths.indices {
                let value = bandValue(
                    of: item.hash, offset: offsets[band], width: bandWidths[band])
                tables[band][value, default: []].append(index)
            }
        }

        var pairs: [ClassPair] = []
        for band in bandWidths.indices {
            for (_, bucket) in tables[band] where bucket.count > 1 {
                for i in bucket.indices {
                    for j in (i + 1)..<bucket.count {
                        let first = bucket[i]
                        let second = bucket[j]
                        // Emitted already if an earlier band also holds both.
                        guard
                            !collidesInAnEarlierBand(
                                classes[first].hash, classes[second].hash, before: band,
                                offsets: offsets)
                        else { continue }
                        pairs.append(ClassPair(first, second))
                    }
                }
            }
        }

        let total = classes.count * (classes.count - 1) / 2
        return Candidates(classes: classes, pairs: pairs, totalClassPairs: total)
    }

    /// A verified pair: two classes and the distance between their hashes.
    public struct Match: Sendable, Hashable {
        public let a: Int
        public let b: Int
        public let distance: Int

        public init(a: Int, b: Int, distance: Int) {
            self.a = a
            self.b = b
            self.distance = distance
        }

        /// The CLI's `image_similarity`, `1.0 - hamming / 64.0`.
        public var similarity: Double {
            1.0 - Double(distance) / Double(PerceptualHash.bitCount)
        }
    }

    /// Candidate generation followed by the exact comparison.
    ///
    /// The candidates are a superset, so this is where the answer is decided. Sorted by distance and then by
    /// class index, which is deterministic -- the caller re-sorts by path once it has them, because the CLI's
    /// own order comes from `os.walk` and is not reproducible.
    ///
    /// **The integer comparison is exactly the CLI's float one.** It writes `sim >= 1.0 - threshold / 64.0`
    /// with `sim = 1.0 - distance / 64.0`; 64 is a power of two, so both quotients are exact in binary floating
    /// point and `sim >= min` holds precisely when `distance <= threshold`. No rounding to reason about.
    public func matches(in hashes: [PerceptualHash]) -> (matches: [Match], candidates: Candidates) {
        let found = candidates(for: hashes)
        var matches: [Match] = []
        for pair in found.pairs {
            let distance = found.classes[pair.a].hash.distance(to: found.classes[pair.b].hash)
            guard distance <= maximumDistance else { continue }
            matches.append(Match(a: pair.a, b: pair.b, distance: distance))
        }
        matches.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.a != $1.a { return $0.a < $1.a }
            return $0.b < $1.b
        }
        return (matches, found)
    }

    // MARK: - Private

    /// Groups identical hashes, keeping the first appearance's order so the result is reproducible.
    func equivalenceClasses(of hashes: [PerceptualHash]) -> [HashClass] {
        var order: [PerceptualHash] = []
        var members: [PerceptualHash: [Int]] = [:]
        for (index, hash) in hashes.enumerated() {
            if members[hash] == nil { order.append(hash) }
            members[hash, default: []].append(index)
        }
        return order.map { HashClass(hash: $0, members: members[$0] ?? []) }
    }

    /// The bit offset each band starts at, counting from the least significant bit.
    func bandOffsets() -> [Int] {
        var offsets: [Int] = []
        var running = 0
        for width in bandWidths {
            offsets.append(running)
            running += width
        }
        return offsets
    }

    func bandValue(of hash: PerceptualHash, offset: Int, width: Int) -> UInt64 {
        let mask: UInt64 = width >= 64 ? .max : (1 << UInt64(width)) - 1
        return (hash.bits >> UInt64(offset)) & mask
    }

    private func collidesInAnEarlierBand(
        _ first: PerceptualHash, _ second: PerceptualHash, before band: Int, offsets: [Int]
    ) -> Bool {
        for earlier in 0..<band {
            let width = bandWidths[earlier]
            let offset = offsets[earlier]
            if bandValue(of: first, offset: offset, width: width)
                == bandValue(of: second, offset: offset, width: width)
            {
                return true
            }
        }
        return false
    }
}
