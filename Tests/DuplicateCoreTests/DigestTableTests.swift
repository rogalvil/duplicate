import Testing

@testable import DuplicateCore

private func key(_ seed: UInt64) -> HashCacheKey {
    // Spread over every field, so the order is decided at different depths of the comparison.
    HashCacheKey(
        volume: seed % 3, inode: seed % 11, size: Int64(seed % 7), mtimeNanoseconds: Int64(seed),
        generation: seed % 5)
}

private func digest(_ seed: UInt64) -> Digest32 {
    Digest32(a: seed, b: ~seed, c: seed &* 31, d: seed &+ 7)
}

@Suite("DigestTable")
struct DigestTableTests {

    /// **Checked against a dictionary**, which is what the table replaced (#161). A merge every four inserts
    /// means a few hundred of them, interleaved with updates of keys on both sides of the split.
    @Test("It answers like a dictionary across many merges")
    func matchesADictionary() {
        var table = DigestTable(minimumMerge: 4)
        var model: [HashCacheKey: Digest32] = [:]
        var generator = SystemRandomNumberGenerator()
        for step in 0..<3_000 {
            let seed = UInt64.random(in: 0..<800, using: &generator)
            let value = digest(UInt64(step))
            table.set(value, for: key(seed))
            model[key(seed)] = value
        }
        #expect(table.count == model.count)
        for seed in 0..<900 {
            #expect(table[key(UInt64(seed))] == model[key(UInt64(seed))])
        }

        let records = table.records()
        #expect(records.count == model.count)
        for (left, right) in zip(records, records.dropFirst()) {
            #expect(HashCacheKey.isOrdered(left.key, right.key), "records out of order or repeated")
        }
        #expect(
            Dictionary(records.map { ($0.key, $0.digest) }, uniquingKeysWith: { first, _ in first })
                == model)
    }

    @Test("Removing keeps the rest, in order")
    func removesInOrder() {
        var table = DigestTable(minimumMerge: 4)
        for seed in UInt64(0)..<50 { table.set(digest(seed), for: key(seed)) }
        table.removeAll { $0.mtimeNanoseconds % 2 == 0 }
        #expect(table.count == 25)
        #expect(table[key(4)] == nil)
        #expect(table[key(5)] == digest(5))
        let records = table.records()
        for (left, right) in zip(records, records.dropFirst()) {
            #expect(HashCacheKey.isOrdered(left.key, right.key))
        }
    }

    /// The array cannot be shifted for every insert, so a new key waits beside it -- and must be found there.
    @Test("A key not yet merged is found, and updating it does not duplicate it")
    func findsRecentKeys() {
        var table = DigestTable(minimumMerge: 1_000)
        table.set(digest(1), for: key(1))
        #expect(table[key(1)] == digest(1))
        table.set(digest(2), for: key(1))
        #expect(table[key(1)] == digest(2))
        #expect(table.count == 1)
        #expect(table.records().map(\.digest) == [digest(2)])
        // And once merged, an update replaces the row in place.
        table.set(digest(3), for: key(1))
        #expect(table.records().map(\.digest) == [digest(3)])
    }
}
