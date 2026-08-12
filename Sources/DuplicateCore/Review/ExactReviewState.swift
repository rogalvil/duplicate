import Foundation

/// What the user has said about one group.
///
/// **Three states, not two, and that is the fix for the most dangerous defect in the CLI.**
/// `ReviewState.decisions()` there emits an entry for *every* group, including ones the user never looked
/// at, filled in with the heuristic's guess (`src/rav/core/duplicate_review.py:152-157`). Quit after group
/// 1 of 50 and the file records decisions for 49 groups; apply then acts on all of them. In a terminal that
/// takes a deliberate `q`. In a window, quitting is closing a window.
public enum GroupDecision: Sendable, Equatable {
    /// Never visited. **Not written to the decisions file** -- that is the whole point.
    case undecided
    /// The user chose which files to keep, by index.
    case decided(keep: Set<Int>)
    /// Visited and explicitly passed over. Also not written.
    ///
    /// Distinct from `undecided` so the UI can say "you skipped 12" separately from "you have not looked at
    /// 1,986", and so skipping cannot be mistaken for a decision.
    case skipped
    /// Remove every member of the group.
    case discardAll

    public var isActionable: Bool {
        switch self {
        case .decided, .discardAll: true
        case .undecided, .skipped: false
        }
    }
}

/// What happened when the user confirmed a group.
///
/// Three cases, because the CLI's `confirm_group()` returns a `Bool` that means three different things --
/// "advanced", "that was the last group", and "you kept nothing, try again" -- and the TUI reads any
/// `false` as "we are done" and exits (`src/rav/ui/duplicate_review.py:175-179`). Pressing enter with
/// nothing checked quits the review.
public enum ConfirmOutcome: Sendable, Equatable {
    case advanced
    case finished
    /// Refused: a group must keep at least one file. Not an exit.
    case rejectedNoKeep
}

/// The review of one exact-duplicate scan.
///
/// Pure state with no UI in it, so every rule is testable and the same logic serves a window, a selftest
/// and any future command line.
public struct ExactReviewState: Sendable {
    public let scan: DuplicateScan
    /// The scan root, needed by the keeper heuristic's depth score.
    public let root: String

    public private(set) var groupIndex: Int = 0
    /// Cursor within the current group, for a keyboard-driven review.
    public private(set) var fileIndex: Int = 0
    private var decisions: [Int: GroupDecision]

    /// - Parameter priorDecisions: keep-paths by group key, as read from a decisions document. Rehydrated by
    ///   matching paths back to indices, which is what the CLI does -- and why paths must be compared by
    ///   bytes rather than by `String`, or a decomposed path would fail to match its precomposed twin.
    public init(scan: DuplicateScan, root: String, priorDecisions: [String: [String]] = [:]) {
        self.scan = scan
        self.root = root
        var restored: [Int: GroupDecision] = [:]
        for (index, group) in scan.groups.enumerated() {
            guard let keptPaths = priorDecisions[group.key] else { continue }
            if keptPaths.isEmpty {
                // An empty keep list is how the CLI records "keep none". The app treats it as discard-all;
                // the CLI itself ignores such a group, so it under-acts rather than mis-acting.
                restored[index] = .discardAll
                continue
            }
            let indices = Set(
                keptPaths.compactMap { path in
                    group.files.firstIndex { PathOrder.equal($0, path) }
                }
            )
            // A decision whose paths no longer match this group is not a decision about it.
            restored[index] = indices.isEmpty ? .undecided : .decided(keep: indices)
        }
        decisions = restored
    }

    // MARK: - Reading

    public var groupCount: Int { scan.groups.count }
    public var currentGroup: DuplicateGroup? {
        scan.groups.indices.contains(groupIndex) ? scan.groups[groupIndex] : nil
    }
    public var isOnLastGroup: Bool { groupIndex >= groupCount - 1 }

    public func decision(at index: Int) -> GroupDecision {
        decisions[index] ?? .undecided
    }

    /// The keep set to *show* for a group: the decision when there is one, the heuristic's guess otherwise.
    ///
    /// **The preview is not a decision.** `decisionsForSaving` ignores it entirely. Those two being separate
    /// functions, with separate tests, is the structural guarantee that a glance never becomes an action --
    /// the user sees what the app would suggest without the app having committed to it.
    public func effectiveKeep(at index: Int) -> Set<Int> {
        guard scan.groups.indices.contains(index) else { return [] }
        switch decision(at: index) {
        case .decided(let keep): return keep
        case .discardAll: return []
        case .undecided, .skipped:
            return [KeeperHeuristic.bestIndex(files: scan.groups[index].files, root: root)]
        }
    }

    /// Counts for the UI: how many groups are in each state.
    public var tally: (decided: Int, skipped: Int, undecided: Int) {
        var decided = 0
        var skipped = 0
        for index in scan.groups.indices {
            switch decision(at: index) {
            case .decided, .discardAll: decided += 1
            case .skipped: skipped += 1
            case .undecided: break
            }
        }
        return (decided, skipped, groupCount - decided - skipped)
    }

    // MARK: - Editing

    /// Moves the cursor within the current group.
    public mutating func moveCursor(by delta: Int) {
        guard let group = currentGroup, !group.files.isEmpty else { return }
        fileIndex = min(max(0, fileIndex + delta), group.files.count - 1)
    }

    /// Toggles whether the file under the cursor is kept.
    ///
    /// - Returns: `false` when the toggle was refused because it would leave the group with nothing kept.
    ///   A group with no keeper is not a decision, it is a mistake -- discarding a whole group is a separate,
    ///   explicitly named action.
    @discardableResult
    public mutating func toggleCursor() -> Bool {
        guard let group = currentGroup, group.files.indices.contains(fileIndex) else {
            return false
        }
        var keep = effectiveKeep(at: groupIndex)
        if keep.contains(fileIndex) {
            guard keep.count > 1 else { return false }
            keep.remove(fileIndex)
        } else {
            keep.insert(fileIndex)
        }
        decisions[groupIndex] = .decided(keep: keep)
        return true
    }

    /// Keeps every file in the group, so nothing is removed from it.
    public mutating func keepAll() {
        guard let group = currentGroup else { return }
        decisions[groupIndex] = .decided(keep: Set(group.files.indices))
    }

    /// Removes every file in the group.
    ///
    /// Named for what it does. The CLI calls this "Mover todos" and then skips the group at apply time
    /// because its keep list is empty (`src/rav/core/duplicate_review.py:196-197`) -- a labelled destructive
    /// action that silently does nothing.
    public mutating func discardEntireGroup() {
        guard currentGroup != nil else { return }
        decisions[groupIndex] = .discardAll
    }

    /// Accepts the current keep set and moves on.
    public mutating func confirm() -> ConfirmOutcome {
        guard let group = currentGroup else { return .finished }
        let keep = effectiveKeep(at: groupIndex)
        if keep.isEmpty, decision(at: groupIndex) != .discardAll {
            return .rejectedNoKeep
        }
        if case .discardAll = decision(at: groupIndex) {
            // Already recorded.
        } else {
            decisions[groupIndex] = .decided(keep: keep)
        }
        _ = group
        return advance()
    }

    /// Passes over the group without deciding.
    ///
    /// Leaves the heuristic's preview alone. The CLI resets the keep set to index `0`
    /// (`src/rav/core/duplicate_review.py:120-122`), which its own docs contradict -- "skip" should mean
    /// "decide nothing", not "silently pick the lexicographically first file".
    public mutating func skip() -> ConfirmOutcome {
        guard currentGroup != nil else { return .finished }
        decisions[groupIndex] = .skipped
        return advance()
    }

    /// Marks the group undecided again, undoing a decision or a skip.
    public mutating func clearDecision() {
        decisions[groupIndex] = .undecided
    }

    public mutating func previousGroup() {
        groupIndex = max(0, groupIndex - 1)
        fileIndex = 0
    }

    public mutating func go(to index: Int) {
        guard scan.groups.indices.contains(index) else { return }
        groupIndex = index
        fileIndex = 0
    }

    private mutating func advance() -> ConfirmOutcome {
        guard !isOnLastGroup else { return .finished }
        groupIndex += 1
        fileIndex = 0
        return .advanced
    }

    // MARK: - Saving

    /// The decisions to write, keyed by group key, in group order.
    ///
    /// **Only groups the user actually decided.** An undecided or skipped group is absent, and that absence
    /// is the whole fix: the CLI's `_apply_decisions` only overrides keys that are present
    /// (`src/rav/core/duplicate_review.py:76-83`) and `decision_candidates` skips absent ones (`:192-201`),
    /// so a partially reviewed file written by this app makes even the CLI act on exactly the reviewed
    /// groups. Strictly safer in both tools.
    ///
    /// `discardAll` serialises as an empty array, which is byte-identical to what the CLI writes for its own
    /// "keep none" -- and which the CLI then ignores. Asymmetric, but it costs nothing and under-acting is
    /// the right direction for a destructive action.
    public var decisionsForSaving: [(key: String, keptPaths: [String])] {
        var result: [(key: String, keptPaths: [String])] = []
        for (index, group) in scan.groups.enumerated() {
            switch decision(at: index) {
            case .decided(let keep):
                let paths = keep.sorted().compactMap {
                    group.files.indices.contains($0) ? group.files[$0] : nil
                }
                result.append((group.key, PathOrder.sorted(paths)))
            case .discardAll:
                result.append((group.key, []))
            case .undecided, .skipped:
                continue
            }
        }
        return result
    }

    /// Every file the decisions say to remove, with the storage partition honoured.
    ///
    /// One representative per storage cluster, never every other file -- so a hardlink that shares an inode
    /// with the keeper is never proposed. Undecided and skipped groups contribute nothing.
    public var removalPlan: [(group: DuplicateGroup, paths: [String])] {
        var plan: [(group: DuplicateGroup, paths: [String])] = []
        for (index, group) in scan.groups.enumerated() {
            switch decision(at: index) {
            case .decided(let keep):
                guard let first = keep.sorted().first, group.files.indices.contains(first) else {
                    continue
                }
                let keptPaths = Set(
                    keep.compactMap { group.files.indices.contains($0) ? group.files[$0] : nil })
                let candidates = group.removalCandidates(keeping: group.files[first])
                    .filter { candidate in !keptPaths.contains { PathOrder.equal($0, candidate) } }
                if !candidates.isEmpty { plan.append((group, candidates)) }
            case .discardAll:
                plan.append((group, group.files))
            case .undecided, .skipped:
                continue
            }
        }
        return plan
    }

    /// Total bytes the plan would free, counting storage rather than files.
    public var plannedReclaimBytes: Int64 {
        removalPlan.reduce(0) { total, item in
            switch decision(at: scan.groups.firstIndex(of: item.group) ?? 0) {
            case .discardAll: total + item.group.size * Int64(item.paths.count)
            default: total + item.group.reclaimableBytes
            }
        }
    }
}
