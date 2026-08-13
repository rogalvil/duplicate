import Foundation

/// Which groups a review is showing.
///
/// **880 groups cannot be reviewed one at a time, and the answer is not a button that decides them all.**
/// That button is the CLI's defect: it writes a decision for every group including the unopened ones, which
/// is why this app tracks a tri-state at all.
///
/// The honest answer is that most of those 880 do not deserve a decision. In this user's real scan the
/// groups run from 20.5 MB down to 346 B, and the tail is where the count lives: deciding the biggest
/// twenty recovers nearly all the space, and the rest can stay undecided forever without costing anything.
/// So the review lets you narrow to the ones worth your attention, and leaves the others exactly as they
/// were -- undecided, unwritten, unacted on.
public struct GroupFilter: Sendable, Equatable {
    /// Smallest group worth showing, in bytes per file.
    public var minimumSize: Int64
    /// Show only groups with no decision yet.
    public var onlyUndecided: Bool
    /// Hide groups that no longer have at least two files on disk.
    ///
    /// Costs a `stat` per file, so the caller supplies the answer rather than this recomputing it.
    public var onlyStillDuplicates: Bool

    public init(
        minimumSize: Int64 = 0,
        onlyUndecided: Bool = false,
        onlyStillDuplicates: Bool = false
    ) {
        self.minimumSize = minimumSize
        self.onlyUndecided = onlyUndecided
        self.onlyStillDuplicates = onlyStillDuplicates
    }

    /// The sizes offered in a menu, in bytes.
    ///
    /// Round numbers a person recognises, not percentiles: "at least 1 MB" is a decision somebody can make
    /// about their own disk, and "the top 12%" is not.
    public static let sizeChoices: [Int64] = [0, 100_000, 1_000_000, 10_000_000, 100_000_000]

    public var isNarrowing: Bool {
        minimumSize > 0 || onlyUndecided || onlyStillDuplicates
    }

    /// The indices of the groups this filter keeps, in scan order.
    ///
    /// - Parameter stillDuplicate: whether a group still has two or more files on disk, by index. A group
    ///   missing from the map is treated as still a duplicate: not yet checked is not the same as gone, and
    ///   hiding a group because nobody has looked at the disk yet would lose it silently.
    public func matchingIndices(
        in scan: DuplicateScan,
        decision: (Int) -> GroupDecision,
        stillDuplicate: [Int: Bool] = [:]
    ) -> [Int] {
        scan.groups.indices.filter { index in
            let group = scan.groups[index]
            if group.size < minimumSize { return false }
            if onlyUndecided, decision(index) != .undecided { return false }
            if onlyStillDuplicates, stillDuplicate[index] == false { return false }
            return true
        }
    }
}

extension ExactReviewState {
    /// Accepts the shown keep set for several groups at once.
    ///
    /// **The bulk action, and the line it does not cross.** It records what is *on screen* for groups the
    /// user picked -- which is the heuristic's suggestion for any group they have not touched. That is a
    /// decision they are making, deliberately, about a set they selected and can see the size of.
    ///
    /// What it is not is the CLI's behaviour: there, every group gets a decision as a side effect of
    /// quitting, with nothing asked and nothing shown. The difference is not the outcome for one group, it
    /// is that this one is an act.
    ///
    /// A group whose keep set would be empty is skipped rather than decided, for the same reason a single
    /// confirm refuses it: a group with no keeper is a mistake, not a choice.
    ///
    /// - Returns: how many groups were actually decided.
    @discardableResult
    public mutating func confirmAll(_ indices: [Int]) -> Int {
        var decided = 0
        let previousGroup = groupIndex
        for index in indices where scan.groups.indices.contains(index) {
            let keep = effectiveKeep(at: index)
            guard !keep.isEmpty else { continue }
            go(to: index)
            if case .discardAll = decision(at: index) { continue }
            _ = confirmInPlace(keep: keep)
            decided += 1
        }
        go(to: previousGroup)
        return decided
    }

    /// Records `keep` for the current group without moving on.
    ///
    /// `confirm()` advances, which is right for one group at a time and wrong for a batch: advancing 800
    /// times would leave the cursor somewhere nobody asked for.
    private mutating func confirmInPlace(keep: Set<Int>) -> Bool {
        setDecision(.decided(keep: keep), at: groupIndex)
        return true
    }
}
