import Foundation

/// Every apply this app has performed, read back from its journals.
///
/// **The window this is for closes the gap the pruning left visible.** Before it, the only session a user could
/// undo was the last one: apply twice, want the first one back, and there was no way to say so -- even though
/// `UndoCoordinator.undo(sessionID:in:)` has always taken an arbitrary session. The capability was there and
/// nothing named it.
///
/// **One reader, not two.** ``JournalPruner`` classifies from these rows rather than loading every journal a
/// second time: both answers come from the same parse, so they can never disagree about what a session holds.
public enum SessionHistory {

    /// One apply.
    public struct Row: Sendable, Equatable {
        public let sessionID: String
        /// Files the apply moved.
        public let movedCount: Int
        /// How many an undo has already put back.
        public let restoredCount: Int
        /// Bytes the moved files added up to.
        ///
        /// **What the session did, not what its record costs.** The journal's own size is a fact about
        /// bookkeeping; this is the number the user was told when they applied.
        public let movedBytes: Int64
        /// The journal's size on disk, which is what pruning reclaims.
        public let journalBytes: Int64
        /// The scans the moved files came from, in the order first seen. Usually one.
        public let scanIDs: [String]
        /// The timestamp of the first entry, as the journal recorded it. Empty when there are no entries.
        public let firstTimestamp: String
        /// Whether the file could not be read as a journal at all.
        public let isUnreadable: Bool

        public init(
            sessionID: String,
            movedCount: Int,
            restoredCount: Int,
            movedBytes: Int64,
            journalBytes: Int64,
            scanIDs: [String],
            firstTimestamp: String,
            isUnreadable: Bool
        ) {
            self.sessionID = sessionID
            self.movedCount = movedCount
            self.restoredCount = restoredCount
            self.movedBytes = movedBytes
            self.journalBytes = journalBytes
            self.scanIDs = scanIDs
            self.firstTimestamp = firstTimestamp
            self.isUnreadable = isUnreadable
        }

        /// Every file put back, and at least one file to have put back.
        ///
        /// **The empty case is deliberately not "done".** A journal with no entries is either a session that
        /// moved nothing or a file this build could not parse, and calling that finished would offer to delete
        /// the only evidence of the second case.
        public var isFullyRestored: Bool {
            movedCount > 0 && restoredCount >= movedCount
        }

        /// Whether an undo has anything left to attempt.
        ///
        /// Says nothing about whether it would *succeed* -- the Trash may have been emptied, and only
        /// ``UndoPlanner`` can tell. A row that says "1 of 4 back" is the honest invitation to try.
        public var hasWorkLeft: Bool {
            !isUnreadable && movedCount > restoredCount
        }
    }

    /// Reads every journal, newest session first. Never writes.
    public static func rows(in state: StateDirectory) -> [Row] {
        let manager = FileManager.default
        return MoveJournal.sessions(in: state).map { sessionID in
            let path = try? MoveJournal.url(sessionID: sessionID, in: state)
                .path(percentEncoded: false)
            let journalBytes =
                (path.flatMap { try? manager.attributesOfItem(atPath: $0) }?[.size] as? Int64) ?? 0
            guard let loaded = try? MoveJournal.load(sessionID: sessionID, in: state) else {
                return Row(
                    sessionID: sessionID, movedCount: 0, restoredCount: 0, movedBytes: 0,
                    journalBytes: journalBytes, scanIDs: [], firstTimestamp: "",
                    isUnreadable: true)
            }
            // Restorations are counted against this journal's own entries. A record naming a path this journal
            // never moved says the journal is not what it claims to be, and letting it satisfy the count would
            // make a file's only record deletable by an unrelated line.
            let originals = Set(loaded.entries.map(\.originalPath))
            let restored = loaded.restoredPaths.intersection(originals)
            var scans: [String] = []
            for entry in loaded.entries where !scans.contains(entry.scanID) {
                scans.append(entry.scanID)
            }
            return Row(
                sessionID: sessionID,
                movedCount: loaded.entries.count,
                restoredCount: restored.count,
                movedBytes: loaded.entries.reduce(0) { $0 + $1.byteCount },
                journalBytes: journalBytes,
                scanIDs: scans,
                firstTimestamp: loaded.entries.first?.timestamp ?? "",
                isUnreadable: !loaded.isClean && loaded.entries.isEmpty
            )
        }
    }
}
