import Foundation

/// Decides which session journals can be deleted without losing the ability to undo.
///
/// **A journal is the only record of where a file went.** It lives in the shared state directory and grows by
/// one file per apply, forever, and nothing ever removed one -- so the question is not whether to prune but
/// what rule is safe enough to prune by. Measured on this machine today: two sessions, 8 KB. The size is not
/// the reason to build this; the reason is that "we never clean up" is a decision nobody made.
///
/// **The rule is narrow on purpose: a session is prunable only when every file it moved has already been put
/// back.** That is provable rather than probable -- the journal's own `undone_at` records say so, the undo has
/// already run, and deleting the file loses nothing that could still be used.
///
/// **Two wider rules were considered and rejected.** "Prune sessions whose Trash items are gone" would read an
/// unmounted external volume as an emptied Trash and delete the one record of where those files went -- and
/// this user's corpus lives on an external disk, which is exactly the case that would misfire. "Prune anything
/// older than N days" trades a real capability for disk space that is measured in kilobytes. Neither is worth
/// it, and both are written down here so the next person does not have to re-derive the objection.
public enum JournalPruner {

    /// What a session's journal holds, from the point of view of deleting it.
    public struct Session: Sendable, Equatable {
        public let sessionID: String
        /// Files the apply moved.
        public let movedCount: Int
        /// How many of those an undo has already put back.
        public let restoredCount: Int
        /// The journal's size on disk.
        public let byteCount: Int64
        /// Whether the file could not be read as a journal at all.
        public let isUnreadable: Bool

        public init(
            sessionID: String, movedCount: Int, restoredCount: Int, byteCount: Int64,
            isUnreadable: Bool = false
        ) {
            self.sessionID = sessionID
            self.movedCount = movedCount
            self.restoredCount = restoredCount
            self.byteCount = byteCount
            self.isUnreadable = isUnreadable
        }

        /// Every file put back, and at least one file to have put back.
        ///
        /// **The empty case is deliberately not prunable.** A journal with no entries is either a session that
        /// moved nothing or a file this build could not parse, and neither is a session whose undo is done.
        /// Deleting it would gain nothing and cost the only evidence of the second case.
        public var isFullyRestored: Bool {
            movedCount > 0 && restoredCount >= movedCount
        }
    }

    /// A survey of every journal, and the subset that is safe to delete.
    public struct Plan: Sendable, Equatable {
        public let sessions: [Session]

        public init(sessions: [Session]) {
            self.sessions = sessions
        }

        public var prunable: [Session] { sessions.filter(\.isFullyRestored) }
        public var reclaimableBytes: Int64 { prunable.reduce(0) { $0 + $1.byteCount } }
        /// Sessions holding at least one file that has not been put back. Never touched.
        public var stillUndoable: [Session] {
            sessions.filter { !$0.isFullyRestored && !$0.isUnreadable && $0.movedCount > 0 }
        }
        public var unreadable: [Session] { sessions.filter(\.isUnreadable) }
        public var isEmpty: Bool { prunable.isEmpty }
    }

    /// Reads every journal and classifies it. Never writes.
    ///
    /// **Built on ``SessionHistory/rows(in:)`` rather than on its own parse.** The history window and this
    /// answer the same question about the same files; two readers is two chances to disagree about whether a
    /// session is done, and one of those answers deletes a file.
    public static func plan(in state: StateDirectory) -> Plan {
        Plan(
            sessions: SessionHistory.rows(in: state).map {
                Session(
                    sessionID: $0.sessionID, movedCount: $0.movedCount,
                    restoredCount: $0.restoredCount, byteCount: $0.journalBytes,
                    isUnreadable: $0.isUnreadable)
            })
    }

    /// Deletes the journals of fully restored sessions.
    ///
    /// Takes a plan rather than re-deriving one, so what gets deleted is what a caller showed the user. Each
    /// session is re-checked against disk first: the plan may have been on screen for minutes, and a session
    /// that gained an entry since then is no longer done.
    ///
    /// - Returns: the sessions actually removed.
    @discardableResult
    public static func prune(_ plan: Plan, in state: StateDirectory) -> [Session] {
        var removed: [Session] = []
        for session in plan.prunable {
            guard
                let fresh = Self.plan(in: state).sessions.first(where: {
                    $0.sessionID == session.sessionID
                }), fresh.isFullyRestored
            else { continue }
            guard let url = try? MoveJournal.url(sessionID: session.sessionID, in: state) else {
                continue
            }
            guard (try? FileManager.default.removeItem(at: url)) != nil else { continue }
            removed.append(session)
        }
        return removed
    }
}
