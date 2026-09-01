import AppKit
import DuplicateCore

/// Puts back what a session moved.
///
/// **Not ⌘Z.** Undoing a checkbox and undoing four thousand files moved to the Trash are not the same kind
/// of act, and every other Mac app has taught the user that ⌘Z means "the thing I just typed". A user
/// pressing ⌘Z to untick a box and instead moving 4,000 files back would be a catastrophe. So this lives in
/// a `Sessions` menu with **no key equivalent**, and ⌘Z stays on the review's own `NSUndoManager`.
@MainActor
enum UndoCoordinator {

    /// What an undo came to, already turned into text the window can show.
    struct Outcome: Sendable {
        let restoredCount: Int
        let restoredBytes: Int64
        let summary: String
        let detail: String
    }

    /// The most recent session with a journal, or `nil` when none exists.
    static func latestSession(in state: StateDirectory) -> String? {
        let directory = state.path(for: .journal)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return nil
        }
        return
            names
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(6)) }
            .filter(ScanIdentifier.isValid)
            .max()
    }

    /// Plans and runs an undo for one session.
    ///
    /// **The plan is re-checked immediately before each move**, inside `UndoRunner`, because it may have
    /// been shown to a user minutes ago and something could have appeared at the original path since.
    /// **`async` because of the folder case.** A directory has no digest of its own, so verifying one means
    /// rebuilding its manifest -- and doing that from the planner's synchronous environment meant hashing the
    /// whole folder on the main thread with no cache: measured, 33.8 seconds of frozen window for a 10,506-file
    /// photo folder, right after the apply that put those very digests in the cache. The manifests are built
    /// first, by ``UndoPreflight``, which can await it.
    static func undo(
        sessionID: String, in state: StateDirectory, cacheURL: URL? = nil
    ) async -> Outcome {
        guard let loaded = try? MoveJournal.load(sessionID: sessionID, in: state) else {
            return Outcome(
                restoredCount: 0, restoredBytes: 0,
                summary: Strings.string("undo.noJournal"), detail: ""
            )
        }
        let hasher = ContentHasher()
        let cache = HashCache(url: cacheURL ?? HashCache.defaultURL())
        await cache.loadAndRepair()
        let directoryDigests = await UndoPreflight.directoryDigests(
            for: loaded.entries, hasher: hasher, cache: cache)
        _ = try? await cache.persist()
        let plan = UndoPlanner.plan(
            sessionID: sessionID,
            entries: loaded.entries,
            restoredPaths: loaded.restoredPaths,
            environment: .live(hasher: hasher, directoryDigests: directoryDigests)
        )

        // **Never show a Restore button that will do nothing.** An emptied Trash makes every entry
        // unrestorable, and the honest answer is one line, not a plan with zero steps in it.
        guard !plan.isNoOp else {
            return Outcome(
                restoredCount: 0, restoredBytes: 0,
                summary: obstacleSummary(plan), detail: obstacleDetail(plan)
            )
        }

        let report = UndoRunner().run(plan)

        // Appended, never a rewrite of the original line: the journal stays a truthful log of what happened
        // in order rather than a mutable summary of the current state. One line per restored file, because a
        // restoration is an event per file.
        //
        // **And the ones somebody put back themselves count too.** `UndoPlanner` classifies an entry as
        // `.alreadyRestored` only after checking that the original path holds the same bytes, so the fact the
        // line records -- this file is home -- is established either way. Writing it for the moves alone left
        // a session where Finder had returned one file permanently short of `restoredCount >= movedCount`, so
        // `JournalPruner` never called it finished and Clean stayed grey forever. Reported from real use, and
        // the apply sheet is the thing that suggests using Finder in the first place.
        let stamp = ScanIdentifier.timestamp(from: Date())
        for entry in report.restored + plan.alreadyRestored {
            _ = try? MoveJournal.appendRestoration(
                of: entry, at: stamp, sessionID: sessionID, in: state)
        }

        var notes: [String] = []
        if !report.failed.isEmpty {
            notes.append(String(format: Strings.string("undo.failed"), report.failed.count))
        }
        let blocked = plan.blocked.count
        if blocked > 0 {
            notes.append(String(format: Strings.string("undo.blocked"), blocked))
        }
        if plan.alreadyRestored.count > 0 {
            notes.append(
                String(
                    format: Strings.string("undo.alreadyRestored"), plan.alreadyRestored.count))
        }

        var detail = report.restored.map(\.originalPath).joined(separator: "\n")
        if !plan.blocked.isEmpty {
            detail +=
                "\n"
                + plan.blocked.map {
                    "\($0.entry.originalPath)  \u{2014}  \(obstacleText($0.obstacle))"
                }
                .joined(separator: "\n")
        }

        return Outcome(
            restoredCount: report.restored.count,
            restoredBytes: report.restoredBytes,
            summary: notes.isEmpty ? Strings.string("undo.clean") : notes.joined(separator: " "),
            detail: detail
        )
    }

    /// Why one file cannot be put back, in the user's language.
    ///
    /// **This list was printing Swift.** An obstacle came out as `originalPathOccupied`, which names a case of
    /// an enum rather than telling someone that their own newer file is sitting where the old one would go --
    /// and that distinction is the difference between "the app is broken" and "the app declined to overwrite my
    /// work".
    static func obstacleText(_ obstacle: UndoObstacle) -> String {
        switch obstacle {
        case .movedFileMissing: return Strings.string("undo.obstacle.movedFileMissing")
        case .originalPathOccupied: return Strings.string("undo.obstacle.originalPathOccupied")
        case .parentMissing: return Strings.string("undo.obstacle.parentMissing")
        case .originalPathIsDirectory:
            return Strings.string("undo.obstacle.originalPathIsDirectory")
        case .contentChanged: return Strings.string("undo.obstacle.contentChanged")
        case .unverifiable: return Strings.string("undo.obstacle.unverifiable")
        }
    }

    private static func obstacleSummary(_ plan: UndoPlan) -> String {
        if plan.alreadyRestored.count == plan.steps.count, !plan.steps.isEmpty {
            return Strings.string("undo.allRestored")
        }
        if !plan.blocked.isEmpty {
            return String(format: Strings.string("undo.blocked"), plan.blocked.count)
        }
        return Strings.string("undo.nothingToDo")
    }

    private static func obstacleDetail(_ plan: UndoPlan) -> String {
        plan.blocked.map { "\($0.entry.originalPath)  \u{2014}  \(obstacleText($0.obstacle))" }
            .joined(separator: "\n")
    }
}
