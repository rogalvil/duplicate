import Foundation

/// What can be done about one journal entry.
public enum UndoStep: Hashable, Sendable {
    /// Move it back from where it went to where it came from.
    case restore(JournalEntry)
    /// Its original path already holds byte-identical content. Nothing to do, and not an error.
    case alreadyRestored(JournalEntry)
    /// Cannot be put back, with the reason.
    case blocked(JournalEntry, UndoObstacle)
}

/// Why an entry cannot be put back.
public enum UndoObstacle: String, Hashable, Sendable {
    /// The file is no longer where it was moved to. The Trash was emptied, or someone moved it.
    case movedFileMissing
    /// Something else occupies the original path, and it is not the same content.
    case originalPathOccupied
    /// The original path's parent directory no longer exists.
    case parentMissing
    /// A directory now stands where the file used to be.
    case originalPathIsDirectory
    /// The moved file no longer hashes to what the journal recorded.
    case contentChanged
}

/// A plan for undoing one session.
public struct UndoPlan: Sendable {
    public let sessionID: String
    public let steps: [UndoStep]

    public init(sessionID: String, steps: [UndoStep]) {
        self.sessionID = sessionID
        self.steps = steps
    }

    public var restorable: [JournalEntry] {
        steps.compactMap { if case .restore(let entry) = $0 { entry } else { nil } }
    }

    public var alreadyRestored: [JournalEntry] {
        steps.compactMap { if case .alreadyRestored(let entry) = $0 { entry } else { nil } }
    }

    public var blocked: [(entry: JournalEntry, obstacle: UndoObstacle)] {
        steps.compactMap {
            if case .blocked(let entry, let obstacle) = $0 { (entry, obstacle) } else { nil }
        }
    }

    /// Bytes that would come back.
    public var restorableBytes: Int64 {
        restorable.reduce(0) { $0 + $1.byteCount }
    }

    /// How many entries are blocked, by reason, for a report that groups rather than lists 4,000 rows.
    public var obstacleCounts: [UndoObstacle: Int] {
        blocked.reduce(into: [:]) { counts, item in counts[item.obstacle, default: 0] += 1 }
    }

    /// Whether running this plan would do nothing at all.
    ///
    /// The UI must not offer a Restore button that cannot restore anything. When the Trash has been
    /// emptied, every entry is `movedFileMissing` and the honest answer is one sentence and a Close
    /// button -- not a hopeful dialog.
    public var isNoOp: Bool { restorable.isEmpty }
}

/// Decides what can be put back, without touching anything.
///
/// Pure apart from the filesystem questions it asks through injected closures, so every branch is testable
/// without staging a real Trash.
///
/// **The rule that matters: an occupied original path is never overwritten.** A user who undoes a session
/// after saving new work at one of those paths must not lose it. Byte-identical content counts as *already
/// restored* rather than as a conflict -- putting the same bytes back over themselves is not a restore, and
/// reporting it as one would inflate the count the UI shows.
public enum UndoPlanner {
    /// The filesystem questions the planner needs answered.
    public struct Environment: Sendable {
        public var exists: @Sendable (String) -> Bool
        public var isDirectory: @Sendable (String) -> Bool
        /// The digest of a file, or `nil` when it cannot be read.
        public var digest: @Sendable (String) -> Digest32?

        public init(
            exists: @escaping @Sendable (String) -> Bool,
            isDirectory: @escaping @Sendable (String) -> Bool,
            digest: @escaping @Sendable (String) -> Digest32?
        ) {
            self.exists = exists
            self.isDirectory = isDirectory
            self.digest = digest
        }

        /// The real filesystem.
        ///
        /// `any FileHashing` rather than `some`: the closure below has to be `@Sendable`, and an opaque
        /// generic parameter is not known to be `Sendable` at the point it is captured even when every
        /// conformer is. The existential carries the constraint.
        public static func live(hasher: any FileHashing) -> Environment {
            let hash: @Sendable (String) -> Digest32? = { path in
                try? hasher.fullDigest(atPath: path).digest
            }
            return Environment(
                exists: { path in
                    FileManager.default.fileExists(atPath: path)
                },
                isDirectory: { path in
                    var isDirectory: ObjCBool = false
                    let found = FileManager.default.fileExists(
                        atPath: path,
                        isDirectory: &isDirectory
                    )
                    return found && isDirectory.boolValue
                },
                digest: hash
            )
        }
    }

    /// Builds a plan for a session's entries.
    ///
    /// - Parameter restoredPaths: original paths a later `undone_at` record already marked as put back.
    public static func plan(
        sessionID: String,
        entries: [JournalEntry],
        restoredPaths: Set<String> = [],
        environment: Environment
    ) -> UndoPlan {
        var steps: [UndoStep] = []
        for entry in entries {
            steps.append(step(for: entry, restoredPaths: restoredPaths, environment: environment))
        }
        return UndoPlan(sessionID: sessionID, steps: steps)
    }

    private static func step(
        for entry: JournalEntry,
        restoredPaths: Set<String>,
        environment: Environment
    ) -> UndoStep {
        // An entry the journal already says was put back, and whose original is there: nothing to do.
        if restoredPaths.contains(entry.originalPath), environment.exists(entry.originalPath) {
            return .alreadyRestored(entry)
        }

        // The original path is occupied. Byte-identical content means the restore already happened --
        // possibly by Finder's own Put Back, which the app cannot see. Anything else is a conflict, and a
        // conflict is never resolved by overwriting.
        if environment.exists(entry.originalPath) {
            if environment.isDirectory(entry.originalPath) {
                return .blocked(entry, .originalPathIsDirectory)
            }
            if environment.digest(entry.originalPath) == entry.digest {
                return .alreadyRestored(entry)
            }
            return .blocked(entry, .originalPathOccupied)
        }

        guard environment.exists(entry.resultingPath) else {
            return .blocked(entry, .movedFileMissing)
        }
        // The parent has to exist, or the move fails with a message that points at the wrong thing.
        let parent = (entry.originalPath as NSString).deletingLastPathComponent
        guard parent.isEmpty || environment.exists(parent) else {
            return .blocked(entry, .parentMissing)
        }
        // What is in the Trash must still be what was put there. A user who edited a file inside the Trash
        // and then undid the session would otherwise get those edits written over their original path.
        guard environment.digest(entry.resultingPath) == entry.digest else {
            return .blocked(entry, .contentChanged)
        }
        return .restore(entry)
    }
}

/// Carries out an undo plan.
///
/// Separate from the planner so the decision and the mutation can be reviewed independently, and so a UI
/// can show the plan before anything moves.
public struct UndoRunner: Sendable {
    /// What happened.
    public struct Report: Sendable {
        public var restored: [JournalEntry] = []
        public var failed: [(entry: JournalEntry, reason: String)] = []
        public var restoredBytes: Int64 {
            restored.reduce(0) { $0 + $1.byteCount }
        }
    }

    public init() {}

    /// Moves every restorable entry back.
    ///
    /// Never overwrites: the destination is re-checked immediately before the move, because the plan may
    /// have been shown to a user minutes ago and something could have appeared there since.
    public func run(_ plan: UndoPlan) -> Report {
        var report = Report()
        let manager = FileManager.default
        for entry in plan.restorable {
            guard !manager.fileExists(atPath: entry.originalPath) else {
                // Appeared between planning and running. Refusing is the only safe answer.
                report.failed.append((entry, "the original path is occupied"))
                continue
            }
            do {
                try manager.moveItem(atPath: entry.resultingPath, toPath: entry.originalPath)
                report.restored.append(entry)
            } catch {
                report.failed.append((entry, (error as NSError).localizedDescription))
            }
        }
        return report
    }
}
