import Foundation
import Testing

@testable import DuplicateCore

/// A reproducible generator, so a failure can be replayed from its seed.
private struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func next(_ bound: Int) -> Int {
        bound <= 0 ? 0 : Int(next() % UInt64(bound))
    }
}

/// Every pair within `threshold`, the way the CLI finds them: two nested loops.
private func bruteForcePairs(_ hashes: [PerceptualHash], threshold: Int) -> Set<[Int]> {
    var found: Set<[Int]> = []
    for i in hashes.indices {
        for j in (i + 1)..<hashes.count where hashes[i].distance(to: hashes[j]) <= threshold {
            found.insert([i, j])
        }
    }
    return found
}

@Suite("MultiIndexLSH")
struct MultiIndexLSHTests {

    /// The pigeonhole argument, as arithmetic: `T + 1` bands covering exactly 64 bits.
    @Test("Six bands of 11, 11, 11, 11, 10, 10 at the CLI's threshold")
    func splitsTheBits() {
        let index = MultiIndexLSH(maximumDistance: 5)
        #expect(index.bandWidths == [11, 11, 11, 11, 10, 10])
        #expect(index.bandWidths.reduce(0, +) == 64)
        #expect(index.bandWidths.count == 6)

        for threshold in 0...20 {
            let widths = MultiIndexLSH.bandWidths(for: threshold)
            #expect(
                widths.count == threshold + 1,
                "a threshold of \(threshold) needs \(threshold + 1) bands")
            #expect(widths.reduce(0, +) == 64)
            // As even as possible: at most one bit between the widest and the narrowest.
            #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1)
        }
    }

    @Test("The bands cover the bits once each, with no overlap and no gap")
    func coversEveryBit() {
        let index = MultiIndexLSH(maximumDistance: 5)
        let offsets = index.bandOffsets()
        var covered = Set<Int>()
        for band in index.bandWidths.indices {
            for bit in offsets[band]..<(offsets[band] + index.bandWidths[band]) {
                #expect(covered.insert(bit).inserted, "bit \(bit) is in two bands")
            }
        }
        #expect(covered.count == 64)
    }

    /// **The property the whole thing rests on.** A candidate set that misses a pair silently loses a duplicate,
    /// which is why this is a property test over random hashes and not an example.
    @Test("The candidate set is a superset of every pair within the threshold", arguments: 1...12)
    func neverMissesAPair(seed: Int) {
        var rng = Rng(seed: UInt64(seed))
        // Half random, half near-copies of earlier values, so pairs within the threshold actually exist.
        var hashes: [PerceptualHash] = []
        for index in 0..<400 {
            if index >= 200, index % 2 == 0 {
                let source = hashes[rng.next(hashes.count)].bits
                var mutated = source
                for _ in 0..<rng.next(7) { mutated ^= 1 << UInt64(rng.next(64)) }
                hashes.append(PerceptualHash(bits: mutated))
            } else {
                hashes.append(PerceptualHash(bits: rng.next()))
            }
        }

        let index = MultiIndexLSH(maximumDistance: 5)
        let (matches, candidates) = index.matches(in: hashes)

        // Map class pairs back to item pairs to compare against brute force.
        var foundPairs: Set<[Int]> = []
        for match in matches {
            for a in candidates.classes[match.a].members {
                for b in candidates.classes[match.b].members {
                    foundPairs.insert([min(a, b), max(a, b)])
                }
            }
        }
        // Members of one class are distance zero from each other.
        for item in candidates.classes where item.members.count > 1 {
            for i in item.members.indices {
                for j in (i + 1)..<item.members.count {
                    foundPairs.insert([item.members[i], item.members[j]])
                }
            }
        }

        let expected = bruteForcePairs(hashes, threshold: 5)
        #expect(
            foundPairs == expected,
            "seed \(seed): found \(foundPairs.count), wanted \(expected.count)")
        #expect(!expected.isEmpty, "seed \(seed) produced no pairs, so it proves nothing")
    }

    /// **The degenerate case the collapse exists for.** Ten thousand identical hashes are one class and one
    /// index entry, not fifty million pairs.
    @Test("Identical hashes collapse into a single class")
    func collapsesDuplicates() throws {
        var hashes = [PerceptualHash](repeating: PerceptualHash(bits: 0), count: 10_000)
        var rng = Rng(seed: 99)
        for _ in 0..<100 { hashes.append(PerceptualHash(bits: rng.next())) }

        let index = MultiIndexLSH(maximumDistance: 5)
        let (_, candidates) = index.matches(in: hashes)
        let black = try #require(candidates.classes.first { $0.hash.bits == 0 })
        #expect(black.members.count == 10_000)
        // 10,100 items, but at most 101 classes -- and the pair work is quadratic in classes, not items.
        #expect(candidates.classes.count <= 101)
        #expect(candidates.totalClassPairs <= 101 * 100 / 2)
    }

    @Test("Each candidate pair is emitted exactly once")
    func emitsEachPairOnce() {
        var rng = Rng(seed: 7)
        // Deliberately close together, so pairs collide in several bands at a time.
        var hashes: [PerceptualHash] = []
        let base = rng.next()
        for _ in 0..<300 {
            var mutated = base
            for _ in 0..<rng.next(4) { mutated ^= 1 << UInt64(rng.next(64)) }
            hashes.append(PerceptualHash(bits: mutated))
        }
        let candidates = MultiIndexLSH(maximumDistance: 5).candidates(for: hashes)
        var seen = Set<MultiIndexLSH.ClassPair>()
        for pair in candidates.pairs {
            #expect(seen.insert(pair).inserted, "pair (\(pair.a), \(pair.b)) came out twice")
        }
        #expect(!candidates.pairs.isEmpty)
    }

    @Test("A pair past the threshold is dropped by the exact comparison")
    func verifiesCandidates() {
        // Same first band, six bits apart: a candidate the exact comparison must reject at a threshold of 5.
        let a = PerceptualHash(bits: 0)
        let b = PerceptualHash(bits: 0b111111 << 11)
        #expect(a.distance(to: b) == 6)
        let (matches, candidates) = MultiIndexLSH(maximumDistance: 5).matches(in: [a, b])
        #expect(
            candidates.pairs.count == 1, "the two share their lowest band, so they are a candidate")
        #expect(matches.isEmpty, "six bits apart is past a threshold of five")
    }

    @Test("Matches carry the CLI's similarity")
    func reportsSimilarity() throws {
        let a = PerceptualHash(bits: 0)
        let b = PerceptualHash(bits: 0b1111)
        let (matches, _) = MultiIndexLSH(maximumDistance: 5).matches(in: [a, b])
        let match = try #require(matches.first)
        #expect(match.distance == 4)
        #expect(abs(match.similarity - (1.0 - 4.0 / 64.0)) < 1e-12)
    }

    /// The integer test and the CLI's float test are the same test, and 64 being a power of two is why.
    @Test("The integer threshold agrees with the CLI's float threshold at every distance")
    func agreesWithTheFloatFormulation() {
        for threshold in 0...10 {
            let minimum = 1.0 - Double(threshold) / 64.0
            for distance in 0...64 {
                let similarity = 1.0 - Double(distance) / 64.0
                #expect((similarity >= minimum) == (distance <= threshold))
            }
        }
    }

    @Test("An empty or single-item input produces nothing rather than failing")
    func handlesEmptyInput() {
        let index = MultiIndexLSH(maximumDistance: 5)
        #expect(index.candidates(for: []).pairs.isEmpty)
        #expect(index.candidates(for: []).classes.isEmpty)
        let one = index.candidates(for: [PerceptualHash(bits: 12)])
        #expect(one.classes.count == 1)
        #expect(one.pairs.isEmpty)
        #expect(one.totalClassPairs == 0)
    }

    /// How much work the index actually avoids, on hashes shaped like a real photo library.
    @Test("The index examines a small fraction of the pairs")
    func reducesTheWork() {
        var rng = Rng(seed: 4242)
        var hashes: [PerceptualHash] = []
        for index in 0..<3_000 {
            if index % 10 == 0, !hashes.isEmpty {
                var mutated = hashes[rng.next(hashes.count)].bits
                for _ in 0..<rng.next(4) { mutated ^= 1 << UInt64(rng.next(64)) }
                hashes.append(PerceptualHash(bits: mutated))
            } else {
                hashes.append(PerceptualHash(bits: rng.next()))
            }
        }
        let (matches, candidates) = MultiIndexLSH(maximumDistance: 5).matches(in: hashes)
        let fraction = Double(candidates.pairs.count) / Double(candidates.totalClassPairs)
        print(
            "  3,000 hashes: \(candidates.totalClassPairs) class pairs, "
                + "\(candidates.pairs.count) candidates (\(String(format: "%.4f%%", fraction * 100))), "
                + "\(matches.count) matches")
        #expect(fraction < 0.01, "the index only saves time if it discards nearly everything")
        #expect(!matches.isEmpty)
    }
}
