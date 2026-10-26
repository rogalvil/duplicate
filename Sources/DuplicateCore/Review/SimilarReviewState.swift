import Foundation

/// What a review has settled about one similar pair.
///
/// **Three states, not four decisions.** The CLI's `SimilarReviewState.__post_init__`
/// (`similar_review.py:246-251`) fills a default decision for *every* pair before the user has seen one, so
/// quitting after the first pair of 4,771 writes a file that says all 4,771 were decided -- and its apply then
/// acts on all of them. The same defect the exact detector had, in the same shape.
///
/// Here a decision exists only when someone made one. The suggestion is still computed and still shown; it is
/// simply not a decision until confirmed.
public enum PairDecision: Sendable, Equatable {
    /// Never visited. **Not written to the decisions file** -- that is the whole point.
    case undecided
    /// The user chose. Any of the CLI's four values.
    case decided(SimilarDecision)
    /// Visited and explicitly passed over. Also not written.
    ///
    /// Distinct from `undecided` so a window can say "you skipped 12" separately from "you have not looked at
    /// 4,759", and so skipping can never be mistaken for a decision.
    case skipped

    /// Whether this decision would move any file.
    public var isActionable: Bool {
        switch self {
        case .decided(let decision):
            return decision == .keepA || decision == .keepB || decision == .keepNone
        case .undecided, .skipped:
            return false
        }
    }

    public var decision: SimilarDecision? {
        if case .decided(let value) = self { return value }
        return nil
    }
}

/// What a review has settled about one group of alike files (#217), read from the decisions of its pairs.
///
/// **Derived, never stored.** The decisions file is the CLI's map of pairs, so a group's state is whatever its pairs
/// say -- which is also how a file the CLI wrote, or one decided pair by pair, reads as groups.
public enum SimilarGroupState: Sendable, Equatable {
    /// No pair decided.
    case undecided
    /// Every pair passed over.
    case skipped
    /// Every pair decided, and no member is kept by one and removed by another. The positions in the group's
    /// ``SimilarGroup/files`` that survive; empty when every pair said "discard both".
    case decided(keep: Set<Int>)
    /// Some pairs decided and some not, or decisions that contradict each other. Deciding the group replaces them.
    case mixed

    /// Whether the group still needs someone to decide it.
    public var needsDecision: Bool {
        switch self {
        case .undecided, .mixed: return true
        case .skipped, .decided: return false
        }
    }
}

/// The review of one perceptual scan: where the cursor is, what has been decided, and what would be moved.
///
/// A value type, so a window can snapshot it for undo without any bookkeeping -- the same trade the exact
/// review makes, and for the same reason: a few thousand small enums cost less to copy than a delta would cost
/// to maintain, and a snapshot cannot desynchronise from the operation it reverses.
public struct SimilarReviewState: Sendable {

    public let scan: SimilarScan
    /// The suggestion for each pair, by index. Computed once: the facts behind it come from disk.
    public private(set) var suggestions: [SimilarDecisionDefaults.Suggestion]
    private var decisions: [Int: PairDecision] = [:]
    public private(set) var pairIndex: Int = 0
    /// Pairs the user has landed on, so "seen but not decided" is distinguishable from "never reached".
    public private(set) var visited: Set<Int> = []
    /// The scan's pairs joined into groups of alike files.
    public let groups: [SimilarGroup]
    /// Keep sets edited on screen and not yet confirmed, by group. **Not decisions**: nothing here reaches the file.
    private var pendingKeep: [Int: Set<Int>] = [:]
    /// The member whose name a group's one kept file takes (#228), by group.
    ///
    /// **Stored as chosen and checked when read**, so keeping a second file sets the choice aside instead of losing it:
    /// a name only makes sense for a group that keeps one file.
    private var nameSources: [Int: Int] = [:]

    /// Builds a review, optionally rehydrating decisions already on disk.
    ///
    /// - Parameter facts: metadata by path, when a caller has probed it. Absent facts mean the suggestion falls
    ///   through to the parts of the chain that do not need them.
    ///
    /// - Parameter priorRenames: names chosen in an earlier session (#228). One whose files are no longer members of a
    ///   single group of this scan is dropped.
    public init(
        scan: SimilarScan,
        priorDecisions: [String: SimilarDecision] = [:],
        facts: [String: MediaFacts] = [:],
        priorRenames: [SimilarRename] = []
    ) {
        self.scan = scan
        self.groups = SimilarGrouping.groups(of: scan.pairs)
        self.suggestions = scan.pairs.map { pair in
            SimilarDecisionDefaults.suggestion(
                for: pair, root: scan.root, factsA: facts[pair.fileA], factsB: facts[pair.fileB])
        }
        if !priorRenames.isEmpty {
            // By bytes: a `String` key would put an NFC and an NFD spelling of two files in one slot.
            var member: [[UInt8]: (group: Int, file: Int)] = [:]
            for (group, members) in groups.enumerated() {
                for (file, path) in members.files.enumerated() {
                    member[Array(path.utf8)] = (group, file)
                }
            }
            for rename in priorRenames {
                guard let kept = member[Array(rename.keptPath.utf8)],
                    let source = member[Array(rename.nameFromPath.utf8)],
                    kept.group == source.group, kept.file != source.file
                else { continue }
                nameSources[kept.group] = source.file
            }
        }
        guard !priorDecisions.isEmpty else { return }
        for (index, pair) in scan.pairs.enumerated() {
            if let known = priorDecisions[SimilarPairKey.key(for: pair)] {
                decisions[index] = .decided(known)
                visited.insert(index)
            }
        }
    }

    // MARK: - Reading

    public var pairCount: Int { scan.pairs.count }
    public var currentPair: SimilarPair? {
        scan.pairs.indices.contains(pairIndex) ? scan.pairs[pairIndex] : nil
    }
    public var isOnLastPair: Bool { pairIndex >= pairCount - 1 }

    public func decision(at index: Int) -> PairDecision {
        decisions[index] ?? .undecided
    }

    /// What the UI should show selected: the decision if there is one, otherwise the suggestion.
    ///
    /// **The distinction the file depends on.** This is what the window highlights; ``decisionsForSaving`` is
    /// what reaches disk, and a suggestion never does.
    public func effectiveDecision(at index: Int) -> SimilarDecision {
        if let made = decisions[index]?.decision { return made }
        guard suggestions.indices.contains(index) else { return .keepA }
        return suggestions[index].decision
    }

    public func suggestion(at index: Int) -> SimilarDecisionDefaults.Suggestion? {
        suggestions.indices.contains(index) ? suggestions[index] : nil
    }

    public var tally: (decided: Int, skipped: Int, undecided: Int) {
        var decided = 0
        var skipped = 0
        for index in 0..<pairCount {
            switch decision(at: index) {
            case .decided: decided += 1
            case .skipped: skipped += 1
            case .undecided: break
            }
        }
        return (decided, skipped, pairCount - decided - skipped)
    }

    /// How many decided pairs would remove each file count -- one, two, or none.
    public var actionableCount: Int {
        (0..<pairCount).count { decision(at: $0).isActionable }
    }

    // MARK: - Deciding

    public mutating func go(to index: Int) {
        guard scan.pairs.indices.contains(index) else { return }
        pairIndex = index
        visited.insert(index)
    }

    public mutating func advance() {
        go(to: min(pairIndex + 1, max(0, pairCount - 1)))
    }

    public mutating func retreat() {
        go(to: max(pairIndex - 1, 0))
    }

    /// What a confirmation did, so a caller does not have to infer it from a `Bool`.
    ///
    /// Three outcomes, because the CLI packed them into one and its Enter-with-nothing-kept case fell through
    /// into "quit".
    public enum ConfirmOutcome: Sendable, Equatable {
        case advanced
        case finished
        /// The pair index was out of range -- an empty scan, or a stale index.
        case noSuchPair
    }

    /// Records a decision for the current pair and moves on.
    @discardableResult
    public mutating func confirm(_ decision: SimilarDecision) -> ConfirmOutcome {
        guard scan.pairs.indices.contains(pairIndex) else { return .noSuchPair }
        decisions[pairIndex] = .decided(decision)
        visited.insert(pairIndex)
        if isOnLastPair { return .finished }
        advance()
        return .advanced
    }

    /// Accepts whatever is currently effective -- the suggestion, if nothing was chosen.
    ///
    /// This is the one place a suggestion becomes a decision, and it takes an explicit call to get here.
    @discardableResult
    public mutating func confirmEffective() -> ConfirmOutcome {
        confirm(effectiveDecision(at: pairIndex))
    }

    /// Passes over the current pair without deciding it.
    ///
    /// **Skipping leaves the suggestion alone.** The CLI's `skip_group` resets the keep set to the first file,
    /// so passing over a pair silently changed what would happen to it.
    @discardableResult
    public mutating func skip() -> ConfirmOutcome {
        guard scan.pairs.indices.contains(pairIndex) else { return .noSuchPair }
        decisions[pairIndex] = .skipped
        visited.insert(pairIndex)
        if isOnLastPair { return .finished }
        advance()
        return .advanced
    }

    /// Returns a pair to undecided, so a misclick is recoverable without reopening the scan.
    public mutating func clearDecision(at index: Int? = nil) {
        let target = index ?? pairIndex
        guard scan.pairs.indices.contains(target) else { return }
        decisions.removeValue(forKey: target)
    }

    /// Decides a set of pairs at once, without moving the cursor.
    ///
    /// For a scan with thousands of pairs, deciding one at a time is not a workflow. **Every pair named here is
    /// one the caller showed**, which is the invariant that keeps this from becoming the "apply the heuristic to
    /// everything" button this app deliberately does not have.
    public mutating func confirmAll(_ indices: [Int], as decision: SimilarDecision? = nil) {
        for index in indices where scan.pairs.indices.contains(index) {
            decisions[index] = .decided(decision ?? effectiveDecision(at: index))
            visited.insert(index)
        }
    }

    /// Recomputes one pair's suggestion once its files have been probed.
    ///
    /// **Lazily, because probing every pair up front is not affordable.** A suggestion needs pixel dimensions and
    /// -- for video -- codec and bitrate, which means opening the file; a scan of 4,771 pairs covers 2,460 files,
    /// and reading all of them before the window can draw would repeat a large part of the scan.
    ///
    /// So the state starts with suggestions computed from what needs no file (the copy-looking name, the depth),
    /// and a window fills in the rest for the pair the user is looking at. **A decision already made is left
    /// alone**: the facts refine a suggestion, and a suggestion is not a decision.
    public mutating func updateSuggestion(at index: Int, factsA: MediaFacts?, factsB: MediaFacts?) {
        guard scan.pairs.indices.contains(index) else { return }
        suggestions[index] = SimilarDecisionDefaults.suggestion(
            for: scan.pairs[index], root: scan.root, factsA: factsA, factsB: factsB)
    }

    // MARK: - Groups

    /// What the pairs of a group say about it.
    public func groupState(at index: Int) -> SimilarGroupState {
        guard groups.indices.contains(index) else { return .undecided }
        let group = groups[index]
        var decided = 0
        var skipped = 0
        var kept = Set<Int>()
        var removed = Set<Int>()
        for link in group.links {
            switch decision(at: link.pairIndex) {
            case .decided(let choice):
                decided += 1
                switch choice {
                case .keepA:
                    kept.insert(link.a)
                    removed.insert(link.b)
                case .keepB:
                    kept.insert(link.b)
                    removed.insert(link.a)
                case .keepBoth:
                    kept.formUnion([link.a, link.b])
                case .keepNone:
                    removed.formUnion([link.a, link.b])
                }
            case .skipped: skipped += 1
            case .undecided: break
            }
        }
        if decided == 0 { return skipped == group.links.count ? .skipped : .undecided }
        if decided < group.links.count || !kept.isDisjoint(with: removed) { return .mixed }
        return .decided(keep: kept)
    }

    /// The members of a group from most to least worth keeping, by how many of their pairs' suggestions keep them.
    ///
    /// **Counted from the pair suggestions** -- copy-looking name, then the media advice, then pixels and bytes, then
    /// depth -- so the group and its pairs never disagree about which of two files is better. Ties go to byte order.
    public func rankedFiles(inGroup index: Int) -> [Int] {
        guard groups.indices.contains(index) else { return [] }
        let group = groups[index]
        var wins = Array(repeating: 0, count: group.files.count)
        for link in group.links {
            let keepsB =
                suggestions.indices.contains(link.pairIndex)
                && suggestions[link.pairIndex].decision == .keepB
            wins[keepsB ? link.b : link.a] += 1
        }
        return group.files.indices.sorted {
            wins[$0] != wins[$1] ? wins[$0] > wins[$1] : $0 < $1
        }
    }

    /// What a group would keep before anyone touched it.
    ///
    /// The best member, then every member alike to none of those already kept. For a set of copies that is one file;
    /// **for a chain it keeps more**, because discarding a file is only safe next to a kept file it was found alike
    /// to -- the same rule ``confirmGroup(_:keep:)`` enforces.
    public func suggestedKeep(inGroup index: Int) -> Set<Int> {
        guard groups.indices.contains(index) else { return [] }
        let group = groups[index]
        var keep = Set<Int>()
        for file in rankedFiles(inGroup: index)
        where group.neighbours(of: file).isDisjoint(with: keep) {
            keep.insert(file)
        }
        return keep
    }

    /// What the window shows checked: an edit not yet confirmed, then the decision, then the suggestion.
    public func effectiveKeep(inGroup index: Int) -> Set<Int> {
        if let pending = pendingKeep[index] { return pending }
        if case .decided(let keep) = groupState(at: index) { return keep }
        return suggestedKeep(inGroup: index)
    }

    /// Members a keep set would discard although none of their pairs is with a kept file.
    ///
    /// **The safety rule of a group.** In a chain A~B~C, keeping only A discards C on the strength of B, which is
    /// being discarded too: nothing that stays was ever found alike to C. And the apply checks each file against a
    /// counterpart before moving it, so C would have nothing to be checked against.
    public func unmatched(keep: Set<Int>, inGroup index: Int) -> [Int] {
        guard groups.indices.contains(index) else { return [] }
        let group = groups[index]
        return group.files.indices.filter { file in
            !keep.contains(file) && group.neighbours(of: file).isDisjoint(with: keep)
        }
    }

    /// Checks or unchecks one member, without deciding anything.
    ///
    /// - Returns: `false`, and nothing changes, when it would uncheck the last kept member: a group with nothing kept
    ///   is a mistake, not a choice -- the same refusal the exact review makes.
    @discardableResult
    public mutating func toggleKeep(_ file: Int, inGroup index: Int) -> Bool {
        guard groups.indices.contains(index), groups[index].files.indices.contains(file) else {
            return false
        }
        var keep = effectiveKeep(inGroup: index)
        if keep.contains(file) {
            guard keep.count > 1 else { return false }
            keep.remove(file)
        } else {
            keep.insert(file)
        }
        pendingKeep[index] = keep
        return true
    }

    /// Why a group confirmation did not happen, so a caller does not have to infer it.
    public enum GroupConfirmOutcome: Sendable, Equatable {
        case confirmed
        case nothingKept
        /// Members that would be discarded with no kept file they were found alike to.
        case unmatched([Int])
        case noSuchGroup
    }

    /// Decides a group: every one of its pairs gets the decision the keep set implies.
    ///
    /// Both kept is `keep_both`, one kept is `keep_a` or `keep_b`, neither is `keep_none` -- so the file stays the
    /// CLI's map of pairs, and **no member can be kept by one pair and removed by another**.
    @discardableResult
    public mutating func confirmGroup(_ index: Int, keep: Set<Int>? = nil) -> GroupConfirmOutcome {
        guard groups.indices.contains(index) else { return .noSuchGroup }
        let keep = keep ?? effectiveKeep(inGroup: index)
        guard !keep.isEmpty else { return .nothingKept }
        let lonely = unmatched(keep: keep, inGroup: index)
        guard lonely.isEmpty else { return .unmatched(lonely) }
        for link in groups[index].links {
            let decision: SimilarDecision
            switch (keep.contains(link.a), keep.contains(link.b)) {
            case (true, true): decision = .keepBoth
            case (true, false): decision = .keepA
            case (false, true): decision = .keepB
            case (false, false): decision = .keepNone
            }
            decisions[link.pairIndex] = .decided(decision)
            visited.insert(link.pairIndex)
        }
        pendingKeep[index] = nil
        return .confirmed
    }

    /// The member whose name the group's kept file takes, or `nil` for its own name.
    ///
    /// Only while the group keeps exactly one file, and only when the name would change: two files with one name and
    /// one extension in one folder leave nothing to rename.
    public func nameSource(inGroup index: Int) -> Int? {
        rename(inGroup: index).flatMap { _ in nameSources[index] }
    }

    /// The rename the group would carry with what is shown checked.
    public func rename(inGroup index: Int) -> SimilarRename? {
        rename(inGroup: index, keep: effectiveKeep(inGroup: index))
    }

    private func rename(inGroup index: Int, keep: Set<Int>) -> SimilarRename? {
        guard let source = nameSources[index], keep.count == 1, let kept = keep.first,
            kept != source, groups.indices.contains(index)
        else { return nil }
        let files = groups[index].files
        let rename = SimilarRename(keptPath: files[kept], nameFromPath: files[source])
        return rename.isNoOp ? nil : rename
    }

    /// Chooses whose name the kept file takes. `nil`, or the kept file itself, means its own name.
    ///
    /// - Returns: `false`, and nothing changes, when the group does not keep exactly one file: with two kept, "the
    ///   file of one under the name of another" names no file.
    @discardableResult
    public mutating func setNameSource(_ file: Int?, inGroup index: Int) -> Bool {
        guard groups.indices.contains(index) else { return false }
        let keep = effectiveKeep(inGroup: index)
        guard let file, !keep.contains(file) else {
            nameSources[index] = nil
            return true
        }
        guard keep.count == 1, groups[index].files.indices.contains(file) else { return false }
        nameSources[index] = file
        return true
    }

    /// Passes over a group: every pair is skipped, and an unconfirmed edit is dropped.
    public mutating func skipGroup(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        for link in groups[index].links {
            decisions[link.pairIndex] = .skipped
            visited.insert(link.pairIndex)
        }
        pendingKeep[index] = nil
    }

    /// Confirms what is shown for each listed group that nobody has decided.
    ///
    /// **Only `undecided` groups.** A skipped group was passed over on purpose, a decided one carries a choice, and
    /// a mixed one holds pair decisions somebody made: accepting a suggestion over any of them would undo a choice.
    ///
    /// - Returns: how many groups were decided.
    @discardableResult
    public mutating func confirmGroups(_ indices: [Int]) -> Int {
        var decided = 0
        for index in indices where groupState(at: index) == .undecided {
            if confirmGroup(index) == .confirmed { decided += 1 }
        }
        return decided
    }

    /// Groups by state, with mixed ones counted as undecided: they still need someone to decide them.
    public var groupTally: (decided: Int, skipped: Int, undecided: Int) {
        var decided = 0
        var skipped = 0
        for index in groups.indices {
            switch groupState(at: index) {
            case .decided: decided += 1
            case .skipped: skipped += 1
            case .undecided, .mixed: break
            }
        }
        return (decided, skipped, groups.count - decided - skipped)
    }

    // MARK: - Output

    /// What belongs in `similar-decisions/<scan_id>.json`, in pair order.
    ///
    /// **Only decided pairs.** An undecided or skipped pair has no entry, and the absence of the key is the
    /// contract both tools respect: the CLI's reader only overwrites keys that are present.
    public var decisionsForSaving: SimilarDecisionsDocument {
        var entries: [(key: String, decision: SimilarDecision)] = []
        for (index, pair) in scan.pairs.enumerated() {
            guard let decision = decisions[index]?.decision else { continue }
            entries.append((SimilarPairKey.key(for: pair), decision))
        }
        return SimilarDecisionsDocument(entries: entries)
    }

    /// What belongs in `similar-renames/<scan_id>.json`: every name chosen for what is shown, in group order.
    ///
    /// **Not only decided groups**, unlike the decisions: a name is not a decision until its group is one, and
    /// ``renamePlan`` is what acts. Saved so a chosen name survives closing the window.
    public var renamesForSaving: SimilarRenamesDocument {
        SimilarRenamesDocument(renames: groups.indices.compactMap { rename(inGroup: $0) })
    }

    /// The renames an apply would carry out: only groups decided to keep one file.
    ///
    /// Taken from the decision, not from what is shown: an edit not yet confirmed changes neither what is moved nor
    /// what is renamed.
    public var renamePlan: [SimilarRename] {
        groups.indices.compactMap { index in
            guard case .decided(let keep) = groupState(at: index) else { return nil }
            return rename(inGroup: index, keep: keep)
        }
    }

    /// The files a decided review would move, in pair order, with the pair they came from.
    ///
    /// **Only decided pairs reach this**, so a review of 40 pairs out of 4,771 plans 40 pairs' worth of work and
    /// the rest are reported as unreviewed rather than acted on.
    public var removalPlan: [(pair: SimilarPair, paths: [String])] {
        var plan: [(pair: SimilarPair, paths: [String])] = []
        for (index, pair) in scan.pairs.enumerated() {
            guard let decision = decisions[index]?.decision else { continue }
            let paths = decision.removed(in: pair)
            guard !paths.isEmpty else { continue }
            plan.append((pair, paths))
        }
        return plan
    }

    /// Every distinct path the plan would move.
    ///
    /// **Distinct, because one file can appear in several pairs**, and a plan that listed it twice would try to
    /// move it twice -- the second attempt failing on a file that is already in the Trash, reported as an error
    /// for something that worked. Measured on the real corpus: 4,771 pairs cover 2,460 files, so overlap is the
    /// normal case rather than an edge one.
    public var distinctRemovals: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in removalPlan {
            for path in entry.paths where seen.insert(path).inserted {
                ordered.append(path)
            }
        }
        return ordered
    }

    /// Paths a decision would remove that another decision says to keep.
    ///
    /// **The conflict overlapping pairs make possible.** With A~B keeping A and B~C keeping C, B is removed by
    /// the first and kept by neither -- fine. But A~B keeping A and A~C keeping C says remove A and keep A, and
    /// acting on both would delete a file the user chose to keep in another pair. Reported so the UI can refuse
    /// or ask, never resolved silently.
    /// Decided pairs whose key cannot be parsed back apart.
    ///
    /// **The hole in the CLI's key format, surfaced where it can still be acted on.** A decision is stored
    /// against `"a||b"` with no escaping, so a path containing `||` produces a key that splits into the wrong
    /// pair -- and the file it names is one that gets deleted. Measured, no path in this user's corpus contains
    /// it, which is exactly why this has to be reported rather than trusted: the day one does, the failure is a
    /// deletion attributed to the wrong pair, and nothing else in either tool would notice.
    ///
    /// Only decided pairs are listed. An undecided pair writes no key, so its ambiguity costs nothing.
    public var ambiguousKeys: [String] {
        scan.pairs.enumerated().compactMap { index, pair in
            guard decisions[index]?.decision != nil, SimilarPairKey.isAmbiguous(pair) else {
                return nil
            }
            return SimilarPairKey.key(for: pair)
        }
    }

    public var contradictions: [String] {
        var kept: Set<String> = []
        for (index, pair) in scan.pairs.enumerated() {
            guard let decision = decisions[index]?.decision else { continue }
            for path in decision.kept(in: pair) { kept.insert(path) }
        }
        return distinctRemovals.filter { kept.contains($0) }
    }
}
