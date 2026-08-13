import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    // A stable digest per seed, so a "same content" claim in a fixture is exact.
    var hex = ""
    for byte in Array(seed.utf8).prefix(32) {
        hex += String(format: "%02x", byte)
    }
    while hex.count < 64 { hex += "0" }
    return Digest32(hexString: String(hex.prefix(64)))!
}

private func file(_ path: String, _ content: String) -> TreeFile {
    TreeFile(path: path, digest: digest(content))
}

// MARK: - The brute-force reference

/// The CLI's algorithm, transliterated and deliberately naive.
///
/// This is the oracle for the differential test: it materialises `{relpath: digest}` for every directory and
/// compares every pair, exactly as `folder_duplicates.py` does. It is too slow for real trees, which is the
/// entire reason the fast path exists -- and it is simple enough to be obviously right, which is the entire
/// reason it is worth keeping.
private enum BruteForce {
    static func fingerprints(root: String, files: [TreeFile]) -> [String: [String: Digest32]] {
        var directories: Set<String> = []
        for item in files {
            var current = (item.path as NSString).deletingLastPathComponent
            while current.count >= root.count {
                directories.insert(current)
                if current == root { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }

        var result: [String: [String: Digest32]] = [:]
        for directory in directories {
            var map: [String: Digest32] = [:]
            for item in files where item.path.hasPrefix(directory + "/") {
                map[String(item.path.dropFirst(directory.count + 1))] = item.digest
            }
            result[directory] = map
        }
        return result
    }

    static func pairs(root: String, files: [TreeFile], threshold: Double) -> [FolderPair] {
        let prints = fingerprints(root: root, files: files)
        // The root itself is not a candidate, matching `_collect_subdirs`.
        let folders = prints.keys.filter { $0 != root }.sorted()

        var found: [FolderPair] = []
        for i in folders.indices {
            for j in (i + 1)..<folders.count {
                let a = folders[i]
                let b = folders[j]
                // Nested pairs are skipped.
                if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") { continue }

                let fpA = prints[a] ?? [:]
                let fpB = prints[b] ?? [:]
                let totalA = fpA.count
                let totalB = fpB.count
                if totalA + totalB == 0 { continue }

                let common = Set(fpA.keys).intersection(fpB.keys)
                let matching = common.filter { fpA[$0] == fpB[$0] }.count
                let changed = common.filter { fpA[$0] != fpB[$0] }.sorted()
                let onlyInA = Set(fpA.keys).subtracting(fpB.keys).sorted()
                let onlyInB = Set(fpB.keys).subtracting(fpA.keys).sorted()
                let similarity = Double(2 * matching) / Double(totalA + totalB)
                if similarity < threshold { continue }

                found.append(
                    FolderPair(
                        folderA: a, folderB: b, similarity: similarity, matching: matching,
                        onlyInA: onlyInA, onlyInB: onlyInB, changed: changed,
                        totalA: totalA, totalB: totalB
                    )
                )
            }
        }
        return found
    }
}

/// A reproducible generator, so a failure can be replayed from its seed.
private struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed | 1 }

    mutating func next(_ bound: Int) -> Int {
        // xorshift64: good enough to shape a fixture, and identical on every machine.
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return bound <= 0 ? 0 : Int(state % UInt64(bound))
    }
}

/// Builds a random tree with duplicated subtrees, renames and edits.
private func randomTree(seed: UInt64, root: String = "/r") -> [TreeFile] {
    var rng = Rng(seed: seed)
    var files: [TreeFile] = []

    let templates = (0..<(2 + rng.next(3))).map { index -> [(String, String)] in
        (0..<(1 + rng.next(4))).map { fileIndex in
            let depth = rng.next(3)
            let directory = (0..<depth).map { "d\(rng.next(3))/\($0)" }.joined(separator: "/")
            let name = "f\(fileIndex).bin"
            let relative = directory.isEmpty ? name : directory + "/" + name
            return (relative, "content-\(index)-\(fileIndex)")
        }
    }

    for copy in 0..<(2 + rng.next(4)) {
        let template = templates[rng.next(templates.count)]
        let folder = "\(root)/copy\(copy)"
        for (relative, content) in template {
            // Sometimes rename the file, sometimes edit it: both make the pair less than identical.
            let roll = rng.next(10)
            let finalRelative = roll == 0 ? relative + ".renamed" : relative
            let finalContent = roll == 1 ? content + "-edited" : content
            files.append(file(folder + "/" + finalRelative, finalContent))
        }
        // A stray file some of the time, so counts differ.
        if rng.next(3) == 0 {
            files.append(file(folder + "/extra\(copy).bin", "extra-\(copy)"))
        }
    }
    return files
}

@Suite("DiceBounds")
struct DiceBoundsTests {

    /// The number the plan derives, checked against the plan.
    @Test("The ratio bound at 0.9 is 1.2222")
    func matchesTheDerivation() {
        let bound = DiceBounds.maximumCountRatio(threshold: 0.9)
        #expect(abs(bound - 1.2222222222222223) < 1e-12)
    }

    @Test("Counts differing by more than the bound are ruled out")
    func rulesOutLopsidedPairs() {
        // 100 against 130 is a ratio of 1.3, past 1.2222.
        #expect(DiceBounds.couldReach(threshold: 0.9, countA: 100, countB: 130) == false)
        #expect(DiceBounds.couldReach(threshold: 0.9, countA: 100, countB: 120))
        #expect(DiceBounds.couldReach(threshold: 0.9, countA: 100, countB: 100))
    }

    /// **The bound has to be sound, not just useful**: no pair it rules out may actually reach the
    /// threshold. Checked by brute force over every small pair of counts.
    @Test("The bound never rules out a pair that could reach the threshold")
    func isSound() {
        for threshold in [0.5, 0.7, 0.9, 0.95] {
            for countA in 1...40 {
                for countB in 1...40 {
                    // The best case any pair can do: every file of the smaller side matches.
                    let best = Double(2 * min(countA, countB)) / Double(countA + countB)
                    if best >= threshold {
                        #expect(
                            DiceBounds.couldReach(
                                threshold: threshold, countA: countA, countB: countB),
                            "ruled out \(countA)/\(countB) at \(threshold), which can reach \(best)"
                        )
                    }
                }
            }
        }
    }

    @Test("An empty pair cannot reach any threshold")
    func rejectsEmptyPairs() {
        #expect(DiceBounds.couldReach(threshold: 0.9, countA: 0, countB: 0) == false)
        #expect(DiceBounds.couldReach(threshold: 0.9, countA: 0, countB: 5) == false)
    }
}

@Suite("DirectoryTree")
struct DirectoryTreeTests {

    @Test("Every ancestor directory becomes a node")
    func buildsIntermediateDirectories() {
        let tree = DirectoryTree.build(root: "/r", files: [file("/r/a/b/c/x.bin", "x")])
        #expect(tree.nodes.map(\.path) == ["/r", "/r/a", "/r/a/b", "/r/a/b/c"])
        #expect(tree.nodes[0].depth == 0)
        #expect(tree.nodes[3].depth == 3)
    }

    /// The property the whole layout exists for.
    @Test("A subtree's files are one contiguous range")
    func laysFilesOutContiguously() {
        let tree = DirectoryTree.build(
            root: "/r",
            files: [
                file("/r/a/1.bin", "1"), file("/r/a/deep/2.bin", "2"),
                file("/r/b/3.bin", "3"),
            ]
        )
        let a = tree.indexByPath["/r/a"]!
        #expect(tree.nodes[a].subtreeFiles.count == 2)
        let paths = tree.nodes[a].subtreeFiles.map { tree.files[$0].path }
        #expect(paths == ["/r/a/1.bin", "/r/a/deep/2.bin"])
        #expect(tree.subtreeFileCount(0) == 3)
    }

    /// One integer comparison instead of `relative_to` inside a `try/except`.
    @Test("The Euler interval answers the ancestor question")
    func answersAncestry() {
        let tree = DirectoryTree.build(
            root: "/r",
            files: [file("/r/a/b/x.bin", "x"), file("/r/c/y.bin", "y")]
        )
        let a = tree.indexByPath["/r/a"]!
        let b = tree.indexByPath["/r/a/b"]!
        let c = tree.indexByPath["/r/c"]!
        #expect(tree.isAncestor(a, of: b))
        #expect(tree.isAncestor(b, of: a) == false)
        #expect(tree.isAncestor(a, of: a))
        #expect(tree.isAncestor(a, of: c) == false)
        #expect(tree.areNested(a, b))
        #expect(tree.areNested(a, c) == false)
    }

    /// `_collect_subdirs` gathers names out of `dirnames`, so the root is never compared.
    @Test("The root is not a comparable folder")
    func excludesTheRoot() {
        let tree = DirectoryTree.build(root: "/r", files: [file("/r/a/x.bin", "x")])
        #expect(tree.comparableIndices.contains(0) == false)
        #expect(tree.comparableIndices.count == tree.nodes.count - 1)
    }

    @Test("A path outside the root is ignored")
    func ignoresOutsiders() {
        let tree = DirectoryTree.build(
            root: "/r", files: [file("/r/a/x.bin", "x"), file("/elsewhere/y.bin", "y")])
        #expect(tree.files.count == 1)
    }

    @Test("The layout is reproducible")
    func isReproducible() {
        let files = randomTree(seed: 99)
        let first = DirectoryTree.build(root: "/r", files: files)
        let second = DirectoryTree.build(root: "/r", files: files.reversed())
        #expect(first.nodes.map(\.path) == second.nodes.map(\.path))
        #expect(first.files.map(\.path) == second.files.map(\.path))
    }
}

@Suite("FolderSimilarity")
struct FolderSimilarityTests {

    /// The anchor the plan computes by hand: ten files against nine identical ones at the same relative
    /// paths gives `18/19`.
    @Test("Ten against nine identical files is 18/19")
    func matchesTheHandComputedAnchor() throws {
        var files: [TreeFile] = []
        for index in 0..<10 { files.append(file("/r/a/f\(index).bin", "c\(index)")) }
        for index in 0..<9 { files.append(file("/r/b/f\(index).bin", "c\(index)")) }
        let tree = DirectoryTree.build(root: "/r", files: files)

        let result = try FolderSimilarity.find(in: tree, threshold: 0.9)
        let pair = try #require(result.pairs.first)
        #expect(pair.matching == 9)
        #expect(pair.totalA == 10)
        #expect(pair.totalB == 9)
        #expect(abs(pair.similarity - 18.0 / 19.0) < 1e-12)
        #expect(pair.onlyInA == ["f9.bin"])
        #expect(pair.onlyInB.isEmpty)
        #expect(pair.changed.isEmpty)
    }

    @Test("Two identical folders are 1.0")
    func findsIdenticalFolders() throws {
        let tree = DirectoryTree.build(
            root: "/r",
            files: [
                file("/r/a/x.bin", "x"), file("/r/a/sub/y.bin", "y"),
                file("/r/b/x.bin", "x"), file("/r/b/sub/y.bin", "y"),
            ]
        )
        let result = try FolderSimilarity.find(in: tree, threshold: 0.9)
        let pair = try #require(result.pairs.first { $0.folderA == "/r/a" && $0.folderB == "/r/b" })
        #expect(pair.similarity == 1.0)
        #expect(pair.matching == 2)
    }

    @Test("A changed file is reported as changed, not missing")
    func separatesChangedFromMissing() throws {
        let tree = DirectoryTree.build(
            root: "/r",
            files: [
                file("/r/a/x.bin", "x"), file("/r/a/y.bin", "y"), file("/r/a/z.bin", "z"),
                file("/r/b/x.bin", "x"), file("/r/b/y.bin", "y-edited"),
            ]
        )
        let result = try FolderSimilarity.find(in: tree, threshold: 0.1)
        let pair = try #require(result.pairs.first { $0.folderA == "/r/a" && $0.folderB == "/r/b" })
        #expect(pair.matching == 1)
        #expect(pair.changed == ["y.bin"])
        #expect(pair.onlyInA == ["z.bin"])
        #expect(pair.onlyInB.isEmpty)
    }

    @Test("Nested folders are never paired")
    func skipsNestedFolders() throws {
        let tree = DirectoryTree.build(
            root: "/r", files: [file("/r/a/sub/x.bin", "x"), file("/r/a/sub/y.bin", "y")])
        let result = try FolderSimilarity.find(in: tree, threshold: 0.1)
        #expect(result.pairs.isEmpty)
    }

    @Test("Two empty folders produce nothing rather than a division by zero")
    func handlesEmptyFolders() {
        let tree = DirectoryTree.build(root: "/r", files: [])
        #expect(FolderSimilarity.compare(0, 0, in: tree) == nil)
    }

    /// **The highest-value test in the plan.** Random trees through the fast path and through a deliberately
    /// naive transliteration of the CLI, asserting identical pair sets, identical counts, identical
    /// `only_in_*` and `changed`, and identical floats.
    ///
    /// It covers all four places the redesign could be subtly wrong at once: the suffix-length argument, the
    /// Euler ancestor test, the soundness of the size bound, and the depth-first contiguity assumption.
    /// **Not vacuous.** A differential test that compares two empty answers proves nothing, so this counts
    /// what the fixtures actually produce and fails if the generator stopped making comparable folders.
    @Test("The random trees really do produce pairs to compare")
    func fixturesAreNotEmpty() throws {
        var totalPairs = 0
        var seedsWithPairs = 0
        var withChanged = 0
        var withOnlyIn = 0
        for seed in 1...60 {
            let files = randomTree(seed: UInt64(seed) * 2_654_435_761)
            let tree = DirectoryTree.build(root: "/r", files: files)
            let pairs = try FolderSimilarity.find(in: tree, threshold: 0.5).pairs
            totalPairs += pairs.count
            if !pairs.isEmpty { seedsWithPairs += 1 }
            withChanged += pairs.filter { !$0.changed.isEmpty }.count
            withOnlyIn += pairs.filter { !$0.onlyInA.isEmpty || !$0.onlyInB.isEmpty }.count
        }
        // Measured: 38 of the 60 seeds produce at least one pair. The floors are set below that so a
        // regression in the generator shows up, without pinning numbers that a harmless tweak would break.
        #expect(totalPairs >= 100, "only \(totalPairs) pairs across 60 seeds")
        #expect(seedsWithPairs >= 30, "only \(seedsWithPairs) of 60 seeds produced a pair")
        // The interesting cases have to appear, or the differential only ever compares identical folders.
        #expect(withChanged > 0, "no pair had a changed file")
        #expect(withOnlyIn > 0, "no pair had a file missing on one side")
    }

    @Test("The fast path agrees with brute force on random trees", arguments: 1...60)
    func agreesWithBruteForce(seed: Int) throws {
        let files = randomTree(seed: UInt64(seed) * 2_654_435_761)
        let tree = DirectoryTree.build(root: "/r", files: files)

        for threshold in [0.5, 0.9] {
            let fast = try FolderSimilarity.find(in: tree, threshold: threshold).pairs
            let slow = BruteForce.pairs(root: "/r", files: files, threshold: threshold)

            let fastKeys = Set(fast.map { "\($0.folderA)|\($0.folderB)" })
            let slowKeys = Set(slow.map { "\($0.folderA)|\($0.folderB)" })
            #expect(
                fastKeys == slowKeys,
                """
                seed \(seed) at \(threshold): \
                only fast \(fastKeys.subtracting(slowKeys).sorted()), \
                only slow \(slowKeys.subtracting(fastKeys).sorted())
                """
            )

            let slowByKey = Dictionary(
                uniqueKeysWithValues: slow.map { ("\($0.folderA)|\($0.folderB)", $0) })
            for pair in fast {
                let reference = try #require(slowByKey["\(pair.folderA)|\(pair.folderB)"])
                #expect(pair.matching == reference.matching, "seed \(seed): matching")
                #expect(pair.totalA == reference.totalA, "seed \(seed): totalA")
                #expect(pair.totalB == reference.totalB, "seed \(seed): totalB")
                #expect(pair.similarity == reference.similarity, "seed \(seed): similarity")
                #expect(pair.onlyInA == reference.onlyInA, "seed \(seed): onlyInA")
                #expect(pair.onlyInB == reference.onlyInB, "seed \(seed): onlyInB")
                #expect(pair.changed == reference.changed, "seed \(seed): changed")
            }
        }
    }

    /// A class too large to enumerate is reported rather than silently dropped: ten thousand identical
    /// `__init__.py` files would otherwise turn into fifty million pairs, or into a quietly wrong answer.
    @Test("An oversized class is truncated and named")
    func reportsTruncation() throws {
        var files: [TreeFile] = []
        for index in 0...FolderSimilarity.maximumClassSize {
            files.append(file("/r/d\(index)/__init__.py", "same"))
        }
        let tree = DirectoryTree.build(root: "/r", files: files)
        let result = try FolderSimilarity.find(in: tree, threshold: 0.9)
        #expect(result.truncated.count == 1)
        #expect(result.truncated.first?.basename == "__init__.py")
        #expect(result.truncated.first?.fileCount == FolderSimilarity.maximumClassSize + 1)
    }

    @Test("The size bound actually rejects pairs")
    func usesTheSizeBound() throws {
        // 10 files against 20: ratio 2.0, past 1.2222, so the pair is never compared.
        var files: [TreeFile] = []
        for index in 0..<10 { files.append(file("/r/a/f\(index).bin", "c\(index)")) }
        for index in 0..<20 { files.append(file("/r/b/f\(index).bin", "c\(index)")) }
        let tree = DirectoryTree.build(root: "/r", files: files)

        let result = try FolderSimilarity.find(in: tree, threshold: 0.9)
        #expect(result.pairs.isEmpty)
        #expect(result.examinedPairs == 0)
        // And brute force agrees it is below the threshold: 2*10/30 = 0.667.
        #expect(BruteForce.pairs(root: "/r", files: files, threshold: 0.9).isEmpty)
    }

    @Test("Results are sorted by similarity, with ties broken deterministically")
    func sortsDeterministically() throws {
        var files: [TreeFile] = []
        for folder in ["b", "a", "c"] {
            files.append(file("/r/\(folder)/x.bin", "x"))
            files.append(file("/r/\(folder)/y.bin", "y"))
        }
        let tree = DirectoryTree.build(root: "/r", files: files)
        let first = try FolderSimilarity.find(in: tree, threshold: 0.9).pairs
        let second = try FolderSimilarity.find(in: tree, threshold: 0.9).pairs
        #expect(
            first.map { "\($0.folderA)|\($0.folderB)" }
                == second.map { "\($0.folderA)|\($0.folderB)" })
        // All three pairs are 1.0, so the tie-break decides: byte order on the paths.
        #expect(first.map(\.folderA) == ["/r/a", "/r/a", "/r/b"])
    }
}
