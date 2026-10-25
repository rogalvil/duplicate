import Foundation
import Testing

@testable import DuplicateCore

private func pair(
    _ a: String, _ b: String, _ similarity: Double = 1.0, _ kind: MediaKind = .video
) -> SimilarPair {
    SimilarPair(fileA: a, fileB: b, similarity: similarity, mediaKind: kind)
}

private func scan(_ pairs: [SimilarPair]) -> SimilarScan {
    SimilarScan(
        scanID: "20261025-120000-000000", root: "/r", createdAt: "t",
        imageThreshold: 5, videoThreshold: 0.7, pairs: pairs
    )
}

/// Three copies of one clip, found as the three pairs a scan writes for them.
private let threeCopies = [
    pair("/r/clip.mp4", "/r/clip copy.mp4"),
    pair("/r/clip.mp4", "/r/sub/clip.mp4"),
    pair("/r/clip copy.mp4", "/r/sub/clip.mp4"),
]

@Suite("SimilarGrouping")
struct SimilarGroupingTests {

    @Test("Pairs that share a file are one group, in the order of their first pair")
    func joinsSharedFiles() throws {
        let groups = SimilarGrouping.groups(of: [
            pair("/r/x.jpg", "/r/y.jpg", 0.95, .image),
            pair("/r/a.mp4", "/r/b.mp4"),
            pair("/r/b.mp4", "/r/c.mp4", 0.9),
        ])
        #expect(groups.count == 2)
        #expect(groups[0].files == ["/r/x.jpg", "/r/y.jpg"])
        #expect(groups[0].mediaKind == .image)
        let chain = try #require(groups.last)
        #expect(chain.files == ["/r/a.mp4", "/r/b.mp4", "/r/c.mp4"])
        #expect(chain.pairIndices == [1, 2])
        #expect(chain.lowestSimilarity == 0.9)
        #expect(chain.highestSimilarity == 1.0)
    }

    /// Measured on the real scans: video groups are almost all sets of copies, and some image groups are chains.
    @Test("A group says whether every member was found alike to every other")
    func tellsCopiesFromChains() throws {
        let copies = try #require(SimilarGrouping.groups(of: threeCopies).first)
        #expect(copies.isFullyLinked)
        let chain = try #require(
            SimilarGrouping.groups(of: [pair("/r/a", "/r/b"), pair("/r/b", "/r/c")]).first)
        #expect(!chain.isFullyLinked)
        #expect(chain.neighbours(of: 1) == [0, 2])
        #expect(chain.link(between: 0, and: 2) == nil)
        #expect(chain.link(between: 2, and: 1)?.pairIndex == 1)
    }

    /// **A `String` key would merge these**: Swift compares canonical equivalence, the volume compares bytes.
    @Test("An NFC and an NFD spelling of one name stay two files")
    func keepsNormalisationsApart() throws {
        let composed = "/r/caf\u{00E9}.mp4"
        let decomposed = "/r/cafe\u{0301}.mp4"
        #expect(composed == decomposed)
        let groups = SimilarGrouping.groups(of: [
            pair(composed, "/r/other.mp4"), pair(decomposed, "/r/third.mp4"),
        ])
        #expect(groups.count == 2)
        #expect(groups.map(\.files.count) == [2, 2])
    }
}

@Suite("SimilarReviewState groups")
struct SimilarGroupReviewTests {

    @Test("A set of copies keeps one file, and not the one that looks like a copy")
    func suggestsOneOfCopies() throws {
        let state = SimilarReviewState(scan: scan(threeCopies))
        let group = try #require(state.groups.first)
        #expect(state.groups.count == 1)
        #expect(state.groupState(at: 0) == .undecided)
        let keep = state.suggestedKeep(inGroup: 0)
        #expect(keep.count == 1)
        let kept = try #require(keep.first)
        #expect(!group.files[kept].contains("copy"))
        #expect(state.effectiveKeep(inGroup: 0) == keep)
    }

    /// **The safety rule.** In A~B~C, keeping A alone would discard C on the strength of B, which goes too.
    @Test("A chain keeps every file alike to nothing kept")
    func suggestsSafelyForChains() {
        let state = SimilarReviewState(scan: scan([pair("/r/a", "/r/b"), pair("/r/b", "/r/c")]))
        let keep = state.suggestedKeep(inGroup: 0)
        #expect(state.unmatched(keep: keep, inGroup: 0).isEmpty)
        #expect(keep == [0, 2] || keep == [1])
    }

    @Test("Confirming a group decides each of its pairs, with no contradiction")
    func confirmsIntoPairs() {
        var state = SimilarReviewState(scan: scan(threeCopies))
        // Files in byte order: "/r/clip copy.mp4", "/r/clip.mp4", "/r/sub/clip.mp4". Keep the second.
        #expect(state.confirmGroup(0, keep: [1]) == .confirmed)
        #expect(state.decision(at: 0) == .decided(.keepA))
        #expect(state.decision(at: 1) == .decided(.keepA))
        #expect(state.decision(at: 2) == .decided(.keepNone))
        #expect(state.contradictions.isEmpty)
        #expect(state.groupState(at: 0) == .decided(keep: [1]))
        #expect(state.decisionsForSaving.count == 3)
        #expect(state.groupTally == (decided: 1, skipped: 0, undecided: 0))
    }

    @Test("A group with nothing kept, or with a file alike to nothing kept, is refused")
    func refusesUnsafeKeepSets() {
        var state = SimilarReviewState(scan: scan([pair("/r/a", "/r/b"), pair("/r/b", "/r/c")]))
        #expect(state.confirmGroup(0, keep: []) == .nothingKept)
        #expect(state.confirmGroup(0, keep: [0]) == .unmatched([2]))
        #expect(state.decisionsForSaving.count == 0)
        #expect(state.confirmGroup(0, keep: [0, 2]) == .confirmed)
        #expect(state.decision(at: 0) == .decided(.keepA))
        #expect(state.decision(at: 1) == .decided(.keepB))
    }

    @Test("Toggling edits what is shown, refuses to uncheck the last file, and decides nothing")
    func togglesWithoutDeciding() {
        var state = SimilarReviewState(scan: scan(threeCopies))
        let suggested = state.suggestedKeep(inGroup: 0)
        let only = suggested.first ?? 0
        let refused = state.toggleKeep(only, inGroup: 0)
        #expect(!refused)
        let other = (only + 1) % 3
        let accepted = state.toggleKeep(other, inGroup: 0)
        #expect(accepted)
        #expect(state.effectiveKeep(inGroup: 0) == suggested.union([other]))
        #expect(state.groupState(at: 0) == .undecided)
        #expect(state.decisionsForSaving.count == 0)
        // Confirming takes what is shown.
        #expect(state.confirmGroup(0) == .confirmed)
        #expect(state.groupState(at: 0) == .decided(keep: suggested.union([other])))
    }

    /// A file the CLI wrote decides every pair; one decided pair by pair can contradict itself.
    @Test(
        "Pair decisions read back as a group: decided, mixed when partial or contradictory, skipped"
    )
    func derivesStateFromPairs() {
        let key = { (index: Int) in SimilarPairKey.key(for: threeCopies[index]) }
        let consistent = SimilarReviewState(
            scan: scan(threeCopies),
            priorDecisions: [key(0): .keepA, key(1): .keepA, key(2): .keepNone])
        #expect(consistent.groupState(at: 0) == .decided(keep: [1]))

        // The case this feature exists for: A kept over B and over C, then B kept over C.
        let contradictory = SimilarReviewState(
            scan: scan(threeCopies),
            priorDecisions: [key(0): .keepA, key(1): .keepA, key(2): .keepA])
        #expect(contradictory.groupState(at: 0) == .mixed)
        #expect(contradictory.groupState(at: 0).needsDecision)

        let partial = SimilarReviewState(
            scan: scan(threeCopies), priorDecisions: [key(0): .keepA])
        #expect(partial.groupState(at: 0) == .mixed)

        var skipped = SimilarReviewState(scan: scan(threeCopies))
        skipped.skipGroup(0)
        #expect(skipped.groupState(at: 0) == .skipped)
        #expect(skipped.groupTally == (decided: 0, skipped: 1, undecided: 0))
    }

    @Test("Deciding a mixed group replaces its contradiction")
    func replacesMixedDecisions() {
        let key = { (index: Int) in SimilarPairKey.key(for: threeCopies[index]) }
        var state = SimilarReviewState(
            scan: scan(threeCopies),
            priorDecisions: [key(0): .keepA, key(1): .keepA, key(2): .keepA])
        #expect(!state.contradictions.isEmpty)
        #expect(state.confirmGroup(0, keep: [1]) == .confirmed)
        #expect(state.contradictions.isEmpty)
    }

    @Test("Accepting the shown groups decides only the undecided ones")
    func acceptsOnlyUndecided() {
        let key = { (pairs: [SimilarPair], index: Int) in SimilarPairKey.key(for: pairs[index]) }
        let pairs = [
            pair("/r/a1", "/r/a2"), pair("/r/b1", "/r/b2"), pair("/r/c1", "/r/c2"),
            pair("/r/d1", "/r/d2"), pair("/r/d2", "/r/d3"),
        ]
        var state = SimilarReviewState(
            scan: scan(pairs), priorDecisions: [key(pairs, 3): .keepA])
        state.skipGroup(1)
        #expect(state.groupState(at: 3) == .mixed)
        // Group 2 is not among the shown ones.
        #expect(state.confirmGroups([0, 1, 3]) == 1)
        #expect(state.groupState(at: 0) != .undecided)
        #expect(state.groupState(at: 1) == .skipped)
        #expect(state.groupState(at: 2) == .undecided)
        #expect(state.groupState(at: 3) == .mixed)
    }
}

@Suite("PairFilter groups")
struct PairFilterGroupTests {

    @Test("A group passes on its weakest pair, its kind, and whether it still needs deciding")
    func filtersGroups() {
        let state = SimilarReviewState(
            scan: scan([
                pair("/r/a", "/r/b", 1.0), pair("/r/b", "/r/c", 0.91),
                pair("/r/x.jpg", "/r/y.jpg", 1.0, .image),
            ]))
        let all = PairFilter().matchingGroupIndices(in: state.groups) { state.groupState(at: $0) }
        #expect(all == [0, 1])
        let identical = PairFilter(minimumSimilarity: 1.0)
            .matchingGroupIndices(in: state.groups) { state.groupState(at: $0) }
        #expect(identical == [1])
        let videos = PairFilter(kind: .video)
            .matchingGroupIndices(in: state.groups) { state.groupState(at: $0) }
        #expect(videos == [0])
        let undecided = PairFilter(onlyUndecided: true)
            .matchingGroupIndices(in: state.groups) { _ in .mixed }
        #expect(undecided == [0, 1])
    }
}

@Suite("SimilarApplyPlan counterparts")
struct SimilarApplyPlanCounterpartTests {

    /// **The pair order that used to break it**: the discarded pair first, so the first counterpart found for each
    /// file was the other discarded file -- already in the Trash when its turn came.
    @Test("A file is checked against a file that stays, whatever the pair order")
    func prefersKeptCounterparts() throws {
        let pairs = [
            pair("/r/b.mp4", "/r/c.mp4"), pair("/r/a.mp4", "/r/b.mp4"),
            pair("/r/a.mp4", "/r/c.mp4"),
        ]
        var state = SimilarReviewState(scan: scan(pairs))
        let group = try #require(state.groups.first)
        let keeper = try #require(group.files.firstIndex(of: "/r/a.mp4"))
        #expect(state.confirmGroup(0, keep: [keeper]) == .confirmed)
        let plan = SimilarApplyPlan.from(state)
        #expect(plan.items.map(\.path) == ["/r/b.mp4", "/r/c.mp4"])
        #expect(plan.items.allSatisfy { $0.counterpart == "/r/a.mp4" })
        #expect(plan.contradicted.isEmpty)
    }
}
