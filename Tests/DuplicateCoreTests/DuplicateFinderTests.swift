import Foundation
import Testing

@testable import DuplicateCore

private let testInstant = ScanIdentifier.Instant(
    year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 685054
)

/// Counts how many times each method was called, so a test can assert that the prefix stage actually
/// prevented full reads rather than merely running.
private final class CountingHasher: FileHashing, @unchecked Sendable {
    private let real = ContentHasher(configuration: .init(prefixThreshold: 0, prefixWindow: 8))
    private let lock = NSLock()
    private(set) var prefixCalls = 0
    private(set) var fullCalls = 0
    private let prefixEnabled: Bool

    init(prefixEnabled: Bool = true) {
        self.prefixEnabled = prefixEnabled
    }

    func usesPrefixStage(forSize size: Int64) -> Bool { prefixEnabled }

    func prefixDigest(atPath path: String, size: Int64) throws -> Digest32 {
        lock.withLock { prefixCalls += 1 }
        return try real.prefixDigest(atPath: path, size: size)
    }

    func fullDigest(atPath path: String) throws -> HashResult {
        lock.withLock { fullCalls += 1 }
        return try real.fullDigest(atPath: path)
    }
}

@Suite("DuplicateFinder")
struct DuplicateFinderTests {
    @Test("Finds duplicates by content, whatever the names are")
    func findsDuplicatesByContent() async throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        // Same bytes, different names and depths.
        for path in ["a.bin", "sub/b.bin", "sub/deeper/c.bin"] {
            try fixture.file(path, bytes: 300)
        }
        // Same size, different content: must not be grouped.
        try Data([9] + Array(repeating: UInt8(1), count: 299)).write(
            to: URL(filePath: try fixture.file("decoy.bin", bytes: 300))
        )
        // A unique file.
        try fixture.file("alone.bin", bytes: 77)

        let outcome = try await DuplicateFinder().find(
            root: fixture.root,
            instant: testInstant,
            configuration: .init(concurrency: 4)
        )
        #expect(outcome.scan.groups.count == 1)
        #expect(outcome.scan.groups[0].files.count == 3)
        #expect(outcome.scan.groups[0].size == 300)
        #expect(outcome.unreadable.isEmpty)
    }

    @Test("Produces the same document at every concurrency width")
    func outputIsIndependentOfConcurrency() async throws {
        // The property that makes a scan reproducible. Results are written by index, so completion order
        // cannot leak into the document -- and if it ever did, two runs of the same tree would differ
        // and the interop round-trip would start failing intermittently.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        for index in 0..<12 {
            try fixture.file("g1-\(index).bin", bytes: 500)
        }
        for index in 0..<8 {
            try fixture.file("dir\(index)/g2.bin", bytes: 900)
        }

        var documents: [Data] = []
        for width in [1, 2, 3, 8, 16] {
            let outcome = try await DuplicateFinder().find(
                root: fixture.root,
                instant: testInstant,
                configuration: .init(concurrency: width)
            )
            documents.append(try JSONWriter.document(DuplicateScanCodec.encode(outcome.scan)))
        }
        #expect(Set(documents).count == 1, "the document changed with the concurrency width")
    }

    @Test("The prefix stage prevents full reads it can rule out")
    func prefixStagePreventsFullReads() async throws {
        // The stage only earns its place if it stops work. Two files share a size but differ in their
        // last byte, so the probe separates them and neither needs a full read.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        let bytes = ScratchTree.pattern(400)
        var other = bytes
        other[399] = other[399] &+ 1
        try Data(bytes).write(to: URL(filePath: fixture.root + "/x.bin"))
        try Data(other).write(to: URL(filePath: fixture.root + "/y.bin"))

        let hasher = CountingHasher()
        let outcome = try await DuplicateFinder(hasher: hasher).find(
            root: fixture.root,
            instant: testInstant,
            configuration: .init(concurrency: 2)
        )
        #expect(outcome.scan.groups.isEmpty)
        #expect(hasher.prefixCalls == 2)
        #expect(hasher.fullCalls == 0, "the probe ruled both out, so neither should have been read")
    }

    @Test("The prefix stage keeps files it cannot separate")
    func prefixStageKeepsAmbiguousFiles() async throws {
        // A prefix collision must cost work, never correctness: two files agreeing on head, tail and
        // length still get a full read, and the full digest decides.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("x.bin", bytes: 400)
        try fixture.file("y.bin", bytes: 400)

        let hasher = CountingHasher()
        let outcome = try await DuplicateFinder(hasher: hasher).find(
            root: fixture.root,
            instant: testInstant,
            configuration: .init(concurrency: 2)
        )
        #expect(outcome.scan.groups.count == 1)
        #expect(hasher.fullCalls == 2)
    }

    @Test("Disabling the prefix stage changes the work, not the answer")
    func prefixStageDoesNotChangeTheAnswer() async throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        for index in 0..<6 { try fixture.file("f\(index).bin", bytes: 512) }

        let withProbe = CountingHasher(prefixEnabled: true)
        let withoutProbe = CountingHasher(prefixEnabled: false)
        let a = try await DuplicateFinder(hasher: withProbe).find(
            root: fixture.root, instant: testInstant, configuration: .init(concurrency: 3)
        )
        let b = try await DuplicateFinder(hasher: withoutProbe).find(
            root: fixture.root, instant: testInstant, configuration: .init(concurrency: 3)
        )
        #expect(a.scan == b.scan)
        #expect(withProbe.prefixCalls == 6)
        #expect(withoutProbe.prefixCalls == 0)
    }

    @Test("Skips a file that vanished between the walk and the hash")
    func skipsVanishedFile() async throws {
        // Ordinary on a live machine. A scan that aborts on the first missing temporary file is useless,
        // but silently dropping it would be dishonest -- so it is reported.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("keep-a.bin", bytes: 200)
        try fixture.file("keep-b.bin", bytes: 200)
        let doomed = try fixture.file("gone.bin", bytes: 200)

        struct VanishingHasher: FileHashing {
            let inner = ContentHasher()
            let doomed: String
            func usesPrefixStage(forSize size: Int64) -> Bool { false }
            func prefixDigest(atPath path: String, size: Int64) throws -> Digest32 {
                try inner.prefixDigest(atPath: path, size: size)
            }
            func fullDigest(atPath path: String) throws -> HashResult {
                if path == doomed {
                    try? FileManager.default.removeItem(atPath: path)
                }
                return try inner.fullDigest(atPath: path)
            }
        }

        let outcome = try await DuplicateFinder(hasher: VanishingHasher(doomed: doomed)).find(
            root: fixture.root,
            instant: testInstant,
            configuration: .init(concurrency: 1)
        )
        #expect(outcome.scan.groups.count == 1)
        #expect(outcome.scan.groups[0].files.count == 2)
        #expect(outcome.unreadable == [doomed])
    }

    @Test("Reports the directories the walk could not read")
    func reportsInaccessibleDirectories() async throws {
        try #require(getuid() != 0, "root can read a 0o000 directory")
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("open/a.bin", bytes: 10)
        try fixture.directory("closed")
        try fixture.file("closed/b.bin", bytes: 10)
        try fixture.chmod("closed", 0o000)

        let outcome = try await DuplicateFinder().find(
            root: fixture.root,
            instant: testInstant
        )
        #expect(outcome.walk.inaccessiblePaths.count == 1)
    }

    @Test("Stamps the identifier and timestamp from the injected instant")
    func stampsInjectedInstant() async throws {
        // Injected rather than read from the clock, because a Date() in the middle of a pipeline makes
        // the output irreproducible and untestable.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("a.bin", bytes: 10)

        let outcome = try await DuplicateFinder().find(root: fixture.root, instant: testInstant)
        #expect(outcome.scan.scanID == "20260511-064716-685054")
        #expect(outcome.scan.createdAt == "2026-05-11T06:47:16.685054Z")
        #expect(outcome.scan.root == fixture.root)
    }

    @Test("An empty tree produces an empty scan, not a failure")
    func emptyTreeProducesEmptyScan() async throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        let outcome = try await DuplicateFinder().find(root: fixture.root, instant: testInstant)
        #expect(outcome.scan.groups.isEmpty)
        // And it round-trips, so an empty scan is a saveable document like any other.
        let data = try JSONWriter.document(DuplicateScanCodec.encode(outcome.scan))
        #expect(try DuplicateScanCodec.decode(JSONReader.parse(data)).groups.isEmpty)
    }

    @Test("Reports cancellation instead of returning a partial document")
    func reportsCancellation() async throws {
        // A scan cancelled mid-hash must not hand back a document that looks complete. The groups found
        // so far are correct, but completeness is lost, and only the caller can decide what to do with
        // that.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        for index in 0..<40 { try fixture.file("f\(index).bin", bytes: 4096) }

        // Only the path crosses into the task: WalkFixture is not Sendable, and capturing it would be a
        // data race the compiler is right to refuse.
        let root = fixture.root
        let task = Task {
            try await DuplicateFinder().find(
                root: root,
                instant: testInstant,
                configuration: .init(concurrency: 1)
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

@Suite("ProgressCounters")
struct ProgressCountersTests {
    @Test("Counts every file and advances the phase")
    func countsAndAdvancesPhase() {
        let counters = ProgressCounters()
        #expect(counters.snapshot().phase == .idle)
        counters.setPhase(.indexing)
        for index in 0..<100 { counters.noteFileSeen(path: "/x/\(index)") }
        let snapshot = counters.snapshot()
        #expect(snapshot.phase == .indexing)
        #expect(snapshot.filesSeen == 100)
    }

    @Test("Samples the path rather than storing one per file")
    func samplesPath() {
        // Assigning the path per file would allocate 800,000 strings for a label nobody reads more than
        // ten times a second.
        let counters = ProgressCounters()
        counters.noteFileSeen(path: "/first")
        // The interval is a power of two, so the first sampled call is the 64th.
        for index in 1..<ProgressCounters.pathSampleInterval {
            counters.noteFileSeen(path: "/ignored-\(index)")
        }
        #expect(counters.snapshot().currentPath == "/first")
        counters.noteFileSeen(path: "/sampled")
        #expect(counters.snapshot().currentPath == "/sampled")
    }

    @Test("Always samples the path while hashing")
    func alwaysSamplesWhileHashing() {
        // Hashing is slow enough per file that a stale label would look like a frozen scan.
        let counters = ProgressCounters()
        counters.noteHashed(path: "/one", bytes: 10)
        #expect(counters.snapshot().currentPath == "/one")
        counters.noteHashed(path: "/two", bytes: 10)
        #expect(counters.snapshot().currentPath == "/two")
        #expect(counters.snapshot().bytesRead == 20)
        #expect(counters.snapshot().filesHashed == 2)
    }

    @Test("Reports a fraction only when the phase has a total")
    func fractionOnlyWhenDeterminate() {
        // Indexing genuinely does not know how many files exist, exactly as the CLI's on_file hook
        // cannot report a total. A bar that guessed one would jump backwards.
        #expect(ScanProgress(phase: .indexing, filesSeen: 50).fraction == nil)
        #expect(ScanProgress(phase: .hashing, candidates: 0).fraction == nil)
        #expect(ScanProgress(phase: .hashing, candidates: 4, filesHashed: 1).fraction == 0.25)
        #expect(ScanProgress(phase: .probing, candidates: 4, filesProbed: 2).fraction == 0.5)
        // Never above one, even if a counter overshoots.
        #expect(ScanProgress(phase: .hashing, candidates: 2, filesHashed: 5).fraction == 1.0)
    }

    @Test("Is safe to read while many workers write")
    func isSafeUnderConcurrency() async {
        // Relaxed atomics, so this asserts the total is exact rather than merely plausible.
        let counters = ProgressCounters()
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<500 {
                        counters.noteHashed(path: "/w\(worker)/\(index)", bytes: 2)
                    }
                }
            }
            group.addTask {
                for _ in 0..<200 { _ = counters.snapshot() }
            }
        }
        let snapshot = counters.snapshot()
        #expect(snapshot.filesHashed == 4000)
        #expect(snapshot.bytesRead == 8000)
    }
}

@Suite("IOConcurrencyPolicy")
struct IOConcurrencyPolicyTests {
    @Test("Caps an external volume at two readers")
    func capsExternalVolumes() {
        // Concurrent readers on a spinning disk turn sequential reads into a seek storm and throughput
        // collapses by an order of magnitude. This is the case that matters for this app: the real
        // corpus lives on an external volume.
        let external = VolumeTraits(isLocal: true, isInternal: false, isRemovable: true)
        #expect(IOConcurrencyPolicy.recommended(for: external, processorCount: 16) == 2)
        #expect(IOConcurrencyPolicy.recommended(for: external, processorCount: 2) == 2)
    }

    @Test("Caps a network volume at two readers")
    func capsNetworkVolumes() {
        let network = VolumeTraits(isLocal: false)
        #expect(IOConcurrencyPolicy.recommended(for: network, processorCount: 16) == 2)
    }

    @Test("Leaves two cores free on an internal volume, and never exceeds eight")
    func scalesInternalVolumes() {
        // Hardware SHA-256 runs slower than an M-series SSD reads, so several hashers are needed just to
        // saturate the device -- but past eight they contend for one device queue.
        let internalVolume = VolumeTraits()
        #expect(IOConcurrencyPolicy.recommended(for: internalVolume, processorCount: 4) == 2)
        #expect(IOConcurrencyPolicy.recommended(for: internalVolume, processorCount: 8) == 6)
        #expect(IOConcurrencyPolicy.recommended(for: internalVolume, processorCount: 10) == 8)
        #expect(IOConcurrencyPolicy.recommended(for: internalVolume, processorCount: 64) == 8)
    }

    @Test("Never returns fewer than two")
    func neverBelowTwo() {
        // A single stalled read must not idle the whole scan.
        #expect(IOConcurrencyPolicy.recommended(for: VolumeTraits(), processorCount: 1) == 2)
        #expect(IOConcurrencyPolicy.recommended(for: VolumeTraits(), processorCount: 0) == 2)
    }

    @Test("Falls back downwards for a volume it cannot read")
    func fallsBackDownwards() {
        // Guessing "internal NVMe" for an unknown volume would put eight concurrent readers on what
        // might be a USB hard disk.
        let width = IOConcurrencyPolicy.recommended(
            forItemAt: "/nonexistent-\(UUID().uuidString)",
            processorCount: 16
        )
        #expect(width == IOConcurrencyPolicy.minimum)
    }

    @Test("Reads the traits of a real volume")
    func readsRealVolumeTraits() throws {
        let traits = try #require(VolumeTraits.forItem(at: NSTemporaryDirectory()))
        #expect(traits.isLocal)
    }
}
