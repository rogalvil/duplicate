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

    /// Builds a review, optionally rehydrating decisions already on disk.
    ///
    /// - Parameter facts: metadata by path, when a caller has probed it. Absent facts mean the suggestion falls
    ///   through to the parts of the chain that do not need them.
    public init(
        scan: SimilarScan,
        priorDecisions: [String: SimilarDecision] = [:],
        facts: [String: MediaFacts] = [:]
    ) {
        self.scan = scan
        self.suggestions = scan.pairs.map { pair in
            SimilarDecisionDefaults.suggestion(
                for: pair, root: scan.root, factsA: facts[pair.fileA], factsB: facts[pair.fileB])
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
    public var contradictions: [String] {
        var kept: Set<String> = []
        for (index, pair) in scan.pairs.enumerated() {
            guard let decision = decisions[index]?.decision else { continue }
            for path in decision.kept(in: pair) { kept.insert(path) }
        }
        return distinctRemovals.filter { kept.contains($0) }
    }
}
