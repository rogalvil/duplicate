import Synchronization

/// Which stage a scan is in.
///
/// `indexing` has no total: the walk does not know how many files exist until it finishes, exactly as
/// the CLI's `on_file` hook cannot report one (`src/rav/core/duplicates.py:62`). Everything after it
/// does, which is why the UI shows an indeterminate bar and then a determinate one.
public enum ScanPhase: Int, Sendable, CaseIterable {
    case idle = 0
    case indexing
    case probing
    case hashing
    case grouping
    case finished
    case cancelled

    /// Whether this phase can report a meaningful total.
    public var isDeterminate: Bool {
        switch self {
        case .idle, .indexing, .finished, .cancelled: false
        case .probing, .hashing, .grouping: true
        }
    }
}

/// A point-in-time reading of a scan's counters.
public struct ScanProgress: Sendable, Equatable {
    public let phase: ScanPhase
    /// Files the walk has accepted so far. No total during `indexing`.
    public let filesSeen: Int
    /// Files that share a size with another, and so are worth hashing. The denominator for `hashing`.
    public let candidates: Int
    /// Candidates whose prefix has been probed.
    public let filesProbed: Int
    /// Candidates fully hashed.
    public let filesHashed: Int
    /// Bytes read from disk by the hasher.
    public let bytesRead: Int64
    /// The most recently sampled path. Sampled, never accumulated.
    public let currentPath: String

    public init(
        phase: ScanPhase,
        filesSeen: Int = 0,
        candidates: Int = 0,
        filesProbed: Int = 0,
        filesHashed: Int = 0,
        bytesRead: Int64 = 0,
        currentPath: String = ""
    ) {
        self.phase = phase
        self.filesSeen = filesSeen
        self.candidates = candidates
        self.filesProbed = filesProbed
        self.filesHashed = filesHashed
        self.bytesRead = bytesRead
        self.currentPath = currentPath
    }

    /// Completion of the current phase in `0...1`, or `nil` when the phase has no total.
    public var fraction: Double? {
        guard phase.isDeterminate, candidates > 0 else { return nil }
        let done = phase == .probing ? filesProbed : filesHashed
        return min(1.0, Double(done) / Double(candidates))
    }
}

/// Counters shared by every worker in a scan.
///
/// **Pull, not push.** The CLI's hooks fire once per file (`src/rav/core/duplicates.py:60-63`). At
/// 800,000 files, an actor hop or an `AsyncStream` yield per file is both an overhead and a flood: the
/// UI would spend its time coalescing updates nobody can read. Instead every worker bumps a relaxed
/// atomic, and the UI reads ``snapshot()`` on a timer -- ten reads a second instead of 800,000 writes
/// to the main actor.
///
/// The current path is **sampled, never accumulated**. Storing it per file would allocate 800,000
/// strings for a label nobody reads more than ten times a second.
///
/// `Atomic` and `Mutex` are why the package's floor is macOS 15.
public final class ProgressCounters: Sendable {
    /// One in how many files updates the sampled path. A power of two so the test is a mask.
    public static let pathSampleInterval = 64

    private let phaseStorage = Atomic<Int>(ScanPhase.idle.rawValue)
    private let filesSeenStorage = Atomic<Int>(0)
    private let candidatesStorage = Atomic<Int>(0)
    private let filesProbedStorage = Atomic<Int>(0)
    private let filesHashedStorage = Atomic<Int>(0)
    private let bytesReadStorage = Atomic<Int64>(0)
    private let currentPath = Mutex<String>("")

    public init() {}

    public func setPhase(_ phase: ScanPhase) {
        phaseStorage.store(phase.rawValue, ordering: .relaxed)
    }

    public func setCandidates(_ count: Int) {
        candidatesStorage.store(count, ordering: .relaxed)
    }

    /// Records one accepted file, sampling its path every ``pathSampleInterval`` calls.
    public func noteFileSeen(path: String) {
        let (seen, _) = filesSeenStorage.add(1, ordering: .relaxed)
        if seen & (Self.pathSampleInterval - 1) == 0 {
            currentPath.withLock { $0 = path }
        }
    }

    public func noteProbed(path: String) {
        let (probed, _) = filesProbedStorage.add(1, ordering: .relaxed)
        if probed & (Self.pathSampleInterval - 1) == 0 {
            currentPath.withLock { $0 = path }
        }
    }

    /// Records one fully hashed file. Always samples the path: hashing is slow enough per file that a
    /// stale label would look frozen.
    public func noteHashed(path: String, bytes: Int64) {
        filesHashedStorage.add(1, ordering: .relaxed)
        bytesReadStorage.add(bytes, ordering: .relaxed)
        currentPath.withLock { $0 = path }
    }

    /// One relaxed load per field. Safe to call from any thread, at any rate.
    public func snapshot() -> ScanProgress {
        ScanProgress(
            phase: ScanPhase(rawValue: phaseStorage.load(ordering: .relaxed)) ?? .idle,
            filesSeen: filesSeenStorage.load(ordering: .relaxed),
            candidates: candidatesStorage.load(ordering: .relaxed),
            filesProbed: filesProbedStorage.load(ordering: .relaxed),
            filesHashed: filesHashedStorage.load(ordering: .relaxed),
            bytesRead: bytesReadStorage.load(ordering: .relaxed),
            currentPath: currentPath.withLock { $0 }
        )
    }
}
