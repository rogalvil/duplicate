import Foundation

/// What a decisions file read from disk looks like next to the scan it belongs to.
///
/// **This exists because of what the CLI writes.** `ReviewState.decisions()` emits an entry for *every*
/// group, including the ones the user never opened, filled in with the heuristic's guess. Quit after group
/// 1 of 1,099 and the file records 1,099 decisions.
///
/// Measured on this machine's corpus: **55 of 56 decisions files hold exactly one decision per group.** The
/// only partial one is the file this app wrote.
///
/// The app rehydrates those files faithfully -- it has to, they are the shared format -- and then every
/// group shows as decided. That is accurate about the file and misleading about the user: it looks like a
/// review that happened. Somebody opening an old scan, seeing 1,099 check marks and pressing Simulate would
/// get a plan over groups nobody ever looked at.
///
/// So the app classifies what it imported and says so. It does not refuse to load it, and it does not
/// discard it silently: both would be the app deciding for the user in the other direction.
public enum DecisionsProvenance: Sendable, Equatable {
    /// No decisions file, or one with nothing usable in it.
    case none
    /// Some groups decided, some not -- what a review in this app produces.
    case partial(decided: Int, groups: Int)
    /// Every group has a decision.
    ///
    /// Possible from an honest review of a small scan, and the normal output of the CLI for any scan. The
    /// distinction cannot be recovered from the file, so the user is asked rather than guessed at.
    case coversEveryGroup(groups: Int)

    /// Whether this is worth interrupting the user about.
    ///
    /// A one-group scan whose single group is decided covers every group and means nothing; the threshold
    /// is where "I reviewed them all" stops being the likely explanation.
    public var deservesAWarning: Bool {
        switch self {
        case .coversEveryGroup(let groups): groups >= 5
        case .none, .partial: false
        }
    }

    public var decidedCount: Int {
        switch self {
        case .none: 0
        case .partial(let decided, _): decided
        case .coversEveryGroup(let groups): groups
        }
    }

    /// Classifies what was loaded.
    ///
    /// - Parameter priorDecisions: keep-paths by group key, as ``ScanStore/priorDecisions(scanID:)`` returns.
    ///   Only keys that match a group in this scan count: a decisions file left over from a different scan
    ///   of the same folder contributes nothing and must not be read as coverage.
    public static func classify(
        scan: DuplicateScan,
        priorDecisions: [String: [String]]
    ) -> DecisionsProvenance {
        guard !priorDecisions.isEmpty, !scan.groups.isEmpty else { return .none }
        let keys = Set(scan.groups.map(\.key))
        let matching = priorDecisions.keys.filter { keys.contains($0) }.count
        guard matching > 0 else { return .none }
        return matching >= scan.groups.count
            ? .coversEveryGroup(groups: scan.groups.count)
            : .partial(decided: matching, groups: scan.groups.count)
    }
}
