import Foundation

/// What a review has settled about one folder pair.
public enum FolderDecision: Sendable, Equatable {
    /// Never visited. **Not written, and not acted on.**
    case undecided
    /// The user chose which folders to keep. One, or both.
    case decided(keep: [String])
    /// Visited and passed over.
    case skipped

    public var keptPaths: [String]? {
        if case .decided(let keep) = self { return keep }
        return nil
    }
}

/// The review of one folder scan.
///
/// **The CLI's default here is the most dangerous of the three.** `_folders_to_move`
/// (`folder_duplicates.py:250-259`) reads `decisions.get(key, [str(folder_a)])`: a pair the decisions file does
/// not mention is treated as "keep folder_a", so **`folders-move` on an unreviewed scan moves `folder_b` of every
/// pair it found**. For files that meant deleting copies; for folders it means deleting trees.
///
/// Here an undecided pair is not acted on, and the suggestion -- keep the first, which is the byte-smaller path --
/// is shown and not saved.
public struct FolderReviewState: Sendable {
    public let scan: FolderScan
    private var decisions: [Int: FolderDecision] = [:]
    public private(set) var pairIndex: Int = 0

    public init(scan: FolderScan, priorDecisions: [String: [String]] = [:]) {
        self.scan = scan
        guard !priorDecisions.isEmpty else { return }
        for (index, pair) in scan.pairs.enumerated() {
            if let kept = priorDecisions[FolderApplyPlan.folderPairKey(pair)] {
                decisions[index] = .decided(keep: kept)
            }
        }
    }

    public var pairCount: Int { scan.pairs.count }
    public var currentPair: FolderPair? {
        scan.pairs.indices.contains(pairIndex) ? scan.pairs[pairIndex] : nil
    }

    public func decision(at index: Int) -> FolderDecision {
        decisions[index] ?? .undecided
    }

    /// What the UI shows selected: the decision, or the CLI's default of keeping the first folder.
    public func effectiveKeep(at index: Int) -> [String] {
        if let kept = decisions[index]?.keptPaths { return kept }
        guard scan.pairs.indices.contains(index) else { return [] }
        return [scan.pairs[index].folderA]
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

    public mutating func go(to index: Int) {
        guard scan.pairs.indices.contains(index) else { return }
        pairIndex = index
    }

    /// Keeps one side of the pair, which moves the other.
    public mutating func keep(_ path: String, at index: Int? = nil) {
        let target = index ?? pairIndex
        guard scan.pairs.indices.contains(target) else { return }
        decisions[target] = .decided(keep: [path])
    }

    /// Keeps both, which moves neither. A real decision -- it is how a user says "these are not copies".
    public mutating func keepBoth(at index: Int? = nil) {
        let target = index ?? pairIndex
        guard scan.pairs.indices.contains(target) else { return }
        let pair = scan.pairs[target]
        decisions[target] = .decided(keep: [pair.folderA, pair.folderB])
    }

    public mutating func skip(at index: Int? = nil) {
        let target = index ?? pairIndex
        guard scan.pairs.indices.contains(target) else { return }
        decisions[target] = .skipped
    }

    public mutating func clearDecision(at index: Int? = nil) {
        decisions.removeValue(forKey: index ?? pairIndex)
    }

    /// What belongs in `folder-decisions/<scan_id>.json`: **only decided pairs**.
    public func decisionsForSaving(instant: ScanIdentifier.Instant) -> FolderDecisionsDocument {
        var entries: [(key: String, keptPaths: [String])] = []
        for (index, pair) in scan.pairs.enumerated() {
            guard let kept = decisions[index]?.keptPaths else { continue }
            entries.append((FolderApplyPlan.folderPairKey(pair), kept))
        }
        return FolderDecisionsDocument(
            scanID: scan.scanID, createdAt: instant.timestamp, decisions: entries)
    }
}
