import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

/// Sizes chosen to straddle the filter's own choices.
private func scan(sizes: [Int64]) -> DuplicateScan {
    DuplicateScan(
        scanID: "20260812-120000-000000",
        root: "/r",
        createdAt: "2026-08-12T12:00:00.000000Z",
        groups: sizes.enumerated().map { index, size in
            DuplicateGroup(
                size: size,
                digest: digest(String(index % 10)),
                files: ["/r/\(index)/keep.bin", "/r/\(index)/copy.bin"]
            )
        }
    )
}

@Suite("GroupFilter")
struct GroupFilterTests {

    @Test("The default filter keeps everything")
    func keepsEverythingByDefault() {
        let subject = scan(sizes: [10, 1_000, 5_000_000])
        let filter = GroupFilter()
        #expect(filter.isNarrowing == false)
        #expect(filter.matchingIndices(in: subject, decision: { _ in .undecided }) == [0, 1, 2])
    }

    /// **The point of the whole thing.** In the real scan the groups run from 20.5 MB to 346 B, and the tail
    /// is where the count lives: deciding the biggest few recovers nearly all the space.
    @Test("A minimum size cuts the tail")
    func filtersBySize() {
        let subject = scan(sizes: [20_000_000, 5_000_000, 900_000, 346])
        var filter = GroupFilter()
        filter.minimumSize = 1_000_000
        #expect(filter.isNarrowing)
        #expect(filter.matchingIndices(in: subject, decision: { _ in .undecided }) == [0, 1])
    }

    @Test("The size is compared per file, not per group")
    func comparesPerFile() {
        // Two files of 600 KB each is 1.2 MB of files and a 600 KB group: the threshold is about the file
        // the user would look at, not the sum.
        let subject = scan(sizes: [600_000])
        var filter = GroupFilter()
        filter.minimumSize = 1_000_000
        #expect(filter.matchingIndices(in: subject, decision: { _ in .undecided }).isEmpty)
    }

    @Test("Only-undecided hides everything already decided")
    func filtersByDecision() {
        let subject = scan(sizes: [10, 20, 30, 40])
        var filter = GroupFilter()
        filter.onlyUndecided = true
        let decisions: [Int: GroupDecision] = [
            0: .decided(keep: [0]), 1: .skipped, 2: .undecided, 3: .discardAll,
        ]
        #expect(
            filter.matchingIndices(in: subject, decision: { decisions[$0] ?? .undecided }) == [2]
        )
    }

    /// A group nobody has checked on disk is **not** hidden: not yet checked and gone are different, and
    /// hiding the first would lose a group silently.
    @Test("A group with no presence answer yet is kept")
    func keepsUncheckedGroups() {
        let subject = scan(sizes: [10, 20, 30])
        var filter = GroupFilter()
        filter.onlyStillDuplicates = true
        #expect(
            filter.matchingIndices(
                in: subject, decision: { _ in .undecided }, stillDuplicate: [1: false])
                == [0, 2]
        )
    }

    @Test("Filters combine")
    func combinesFilters() {
        let subject = scan(sizes: [20_000_000, 5_000_000, 100])
        var filter = GroupFilter()
        filter.minimumSize = 1_000_000
        filter.onlyUndecided = true
        let decisions: [Int: GroupDecision] = [0: .decided(keep: [0])]
        #expect(
            filter.matchingIndices(in: subject, decision: { decisions[$0] ?? .undecided }) == [1]
        )
    }

    @Test("The size choices are round numbers a person recognises")
    func offersRoundSizes() {
        #expect(GroupFilter.sizeChoices.first == 0)
        #expect(GroupFilter.sizeChoices.contains(1_000_000))
        #expect(GroupFilter.sizeChoices == GroupFilter.sizeChoices.sorted())
    }
}

@Suite("ExactReviewState.confirmAll")
struct BulkConfirmTests {

    @Test("Confirming a set decides exactly that set")
    func decidesTheSelection() {
        var state = ExactReviewState(scan: scan(sizes: [10, 20, 30, 40]), root: "/r")
        #expect(state.confirmAll([0, 2]) == 2)

        #expect(state.decision(at: 0).isActionable)
        #expect(state.decision(at: 1) == .undecided)
        #expect(state.decision(at: 2).isActionable)
        #expect(state.decision(at: 3) == .undecided)
        #expect(state.tally.decided == 2)
    }

    /// **What it records is what was on screen.** For a group nobody touched that is the heuristic's
    /// suggestion -- which is the whole reason this is an explicit act on a set the user selected, and not
    /// something that happens when a window closes.
    @Test("It records the suggestion that was shown")
    func recordsTheShownKeepSet() {
        var state = ExactReviewState(scan: scan(sizes: [10]), root: "/r")
        let shown = state.effectiveKeep(at: 0)
        #expect(state.confirmAll([0]) == 1)

        if case .decided(let keep) = state.decision(at: 0) {
            #expect(keep == shown)
        } else {
            Issue.record("group 0 is not decided")
        }
    }

    @Test("The cursor stays where it was")
    func leavesTheCursorAlone() {
        var state = ExactReviewState(scan: scan(sizes: [10, 20, 30]), root: "/r")
        state.go(to: 1)
        _ = state.confirmAll([0, 1, 2])
        // Advancing 800 times would leave the cursor somewhere nobody asked for.
        #expect(state.groupIndex == 1)
    }

    @Test("An out-of-range index is ignored")
    func ignoresBadIndices() {
        var state = ExactReviewState(scan: scan(sizes: [10]), root: "/r")
        #expect(state.confirmAll([0, 7, -1]) == 1)
        #expect(state.tally.decided == 1)
    }

    /// A group already marked discard-all is left alone: the bulk action accepts what is shown, and what is
    /// shown for that group is "remove everything", which somebody already chose deliberately.
    @Test("A discard-all group is not overwritten")
    func leavesDiscardAllAlone() {
        var state = ExactReviewState(scan: scan(sizes: [10, 20]), root: "/r")
        state.go(to: 0)
        state.discardEntireGroup()
        _ = state.confirmAll([0, 1])
        #expect(state.decision(at: 0) == .discardAll)
        #expect(state.decision(at: 1).isActionable)
    }

    @Test("Confirming nothing decides nothing")
    func handlesAnEmptySelection() {
        var state = ExactReviewState(scan: scan(sizes: [10, 20]), root: "/r")
        #expect(state.confirmAll([]) == 0)
        #expect(state.tally.decided == 0)
    }

    /// The bulk path and the one-at-a-time path have to agree, or a review done two ways would produce two
    /// different files.
    @Test("Bulk and single confirm produce the same decisions")
    func agreesWithSingleConfirm() {
        let subject = scan(sizes: [10, 20, 30])
        var single = ExactReviewState(scan: subject, root: "/r")
        for _ in 0..<3 { _ = single.confirm() }

        var bulk = ExactReviewState(scan: subject, root: "/r")
        _ = bulk.confirmAll([0, 1, 2])

        #expect(single.decisionsForSaving.map(\.key) == bulk.decisionsForSaving.map(\.key))
        #expect(
            single.decisionsForSaving.map(\.keptPaths) == bulk.decisionsForSaving.map(\.keptPaths))
    }
}
