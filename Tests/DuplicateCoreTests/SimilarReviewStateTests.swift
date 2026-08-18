import Foundation
import Testing

@testable import DuplicateCore

private func pair(_ a: String, _ b: String, _ kind: MediaKind = .image) -> SimilarPair {
    SimilarPair(fileA: a, fileB: b, similarity: 1.0, mediaKind: kind)
}

private func scan(_ pairs: [SimilarPair], root: String = "/r") -> SimilarScan {
    SimilarScan(
        scanID: "20260818-120000-000000", root: root, createdAt: "t",
        imageThreshold: 5, videoThreshold: 0.7, pairs: pairs
    )
}

@Suite("SimilarReviewState")
struct SimilarReviewStateTests {

    /// **The defect this type exists to not have.** The CLI fills a default decision for every pair before the
    /// user has seen one, so quitting after the first writes a file that claims all of them were decided.
    @Test("A fresh review has decided nothing, however many pairs it holds")
    func startsUndecided() {
        let state = SimilarReviewState(
            scan: scan((0..<50).map { pair("/r/a\($0).jpg", "/r/b\($0).jpg") }))
        #expect(state.tally == (decided: 0, skipped: 0, undecided: 50))
        #expect(state.decisionsForSaving.count == 0)
        #expect(state.removalPlan.isEmpty)
        #expect(state.actionableCount == 0)
    }

    /// The suggestion is visible and is not a decision. Both halves matter.
    @Test("A suggestion is shown but not saved")
    func separatesSuggestionFromDecision() throws {
        var state = SimilarReviewState(
            scan: scan([pair("/r/photo copy.jpg", "/r/photo.jpg")]))
        // The copy-looking name loses, so the suggestion keeps B.
        #expect(state.effectiveDecision(at: 0) == .keepB)
        #expect(try #require(state.suggestion(at: 0)).ground == .copyName)
        #expect(state.decision(at: 0) == .undecided)
        #expect(state.decisionsForSaving.count == 0)

        // Confirming it is what turns it into one.
        #expect(state.confirmEffective() == .finished)
        #expect(state.decision(at: 0) == .decided(.keepB))
        #expect(state.decisionsForSaving.count == 1)
    }

    @Test("Skipping is not deciding, and leaves the suggestion alone")
    func skipsWithoutDeciding() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b copy.jpg"), pair("/r/c.jpg", "/r/d.jpg")]))
        let suggested = state.effectiveDecision(at: 0)
        #expect(state.skip() == .advanced)
        #expect(state.decision(at: 0) == .skipped)
        // **The CLI's `skip_group` resets the keep set**; passing over a pair must not change what would happen.
        #expect(state.effectiveDecision(at: 0) == suggested)
        #expect(state.tally == (decided: 0, skipped: 1, undecided: 1))
        #expect(state.decisionsForSaving.count == 0)
    }

    @Test("Confirming the last pair reports finished rather than advancing past the end")
    func reportsFinished() {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        #expect(state.confirm(.keepA) == .finished)
        #expect(state.pairIndex == 0)
    }

    @Test("An empty scan cannot be confirmed into a crash")
    func handlesAnEmptyScan() {
        var state = SimilarReviewState(scan: scan([]))
        #expect(state.confirm(.keepA) == .noSuchPair)
        #expect(state.skip() == .noSuchPair)
        #expect(state.currentPair == nil)
        #expect(state.tally == (decided: 0, skipped: 0, undecided: 0))
    }

    @Test("A decision can be cleared back to undecided")
    func clearsADecision() {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        state.confirm(.keepA)
        state.clearDecision(at: 0)
        #expect(state.decision(at: 0) == .undecided)
        #expect(state.decisionsForSaving.count == 0)
    }

    /// Deciding one pair at a time is not a workflow for 4,771 of them.
    @Test("A shown set can be confirmed at once, without moving the cursor")
    func confirmsManyAtOnce() {
        var state = SimilarReviewState(
            scan: scan((0..<10).map { pair("/r/a\($0).jpg", "/r/b\($0).jpg") }))
        state.confirmAll([2, 4, 6])
        #expect(state.tally.decided == 3)
        #expect(state.pairIndex == 0, "confirming a set moved the cursor")
        #expect(state.decisionsForSaving.count == 3)
        // An explicit decision overrides the suggestion for the whole set.
        state.confirmAll([1, 3], as: .keepBoth)
        #expect(state.decision(at: 1) == .decided(.keepBoth))
        #expect(state.decision(at: 3) == .decided(.keepBoth))
    }

    @Test("keep_both decides the pair and moves nothing")
    func keepBothIsADecisionWithNoAction() {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        state.confirm(.keepBoth)
        #expect(state.tally.decided == 1)
        #expect(state.decisionsForSaving.count == 1)
        #expect(state.removalPlan.isEmpty)
        #expect(state.actionableCount == 0)
    }

    /// The dangerous one: it means both files go.
    @Test("keep_none plans both files")
    func keepNonePlansBoth() throws {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        state.confirm(.keepNone)
        let plan = try #require(state.removalPlan.first)
        #expect(plan.paths == ["/r/a.jpg", "/r/b.jpg"])
        #expect(state.actionableCount == 1)
    }

    @Test("The plan carries only decided pairs, in pair order")
    func plansOnlyDecidedPairs() {
        var state = SimilarReviewState(
            scan: scan([
                pair("/r/a.jpg", "/r/b.jpg"), pair("/r/c.jpg", "/r/d.jpg"),
                pair("/r/e.jpg", "/r/f.jpg"),
            ]))
        state.go(to: 2)
        state.confirm(.keepA)
        state.go(to: 0)
        state.confirm(.keepB)
        let plan = state.removalPlan
        #expect(plan.count == 2)
        #expect(
            plan.map(\.pair.fileA) == ["/r/a.jpg", "/r/e.jpg"], "the plan is not in pair order")
        #expect(plan[0].paths == ["/r/a.jpg"])
        #expect(plan[1].paths == ["/r/f.jpg"])
    }

    /// **One file appears in several pairs, and that is the normal case**: the real corpus has 4,771 pairs over
    /// 2,460 files. A plan that listed a path twice would try to move it twice and report the second failure as
    /// an error for something that worked.
    @Test("A file in two pairs is planned once")
    func deduplicatesRemovals() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg"), pair("/r/b.jpg", "/r/c.jpg")]))
        state.confirmAll([0, 1], as: .keepA)
        // Pair one removes /r/b.jpg; pair two keeps /r/b.jpg and removes /r/c.jpg. That is also a
        // contradiction -- see `reportsContradictionsInAChain` -- but what is under test here is that the two
        // removals come out once each.
        #expect(state.removalPlan.count == 2)
        #expect(state.distinctRemovals == ["/r/b.jpg", "/r/c.jpg"])
    }

    /// **The conflict overlapping pairs make possible**, reported rather than resolved.
    @Test("A path removed by one decision and kept by another is reported")
    func reportsContradictions() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg"), pair("/r/a.jpg", "/r/c.jpg")]))
        // Keep B in the first pair (so A goes) and keep A in the second (so A stays).
        state.confirm(.keepB)
        state.go(to: 1)
        state.confirm(.keepA)
        #expect(state.contradictions == ["/r/a.jpg"])
    }

    /// **A chain of overlapping pairs contradicts itself even when every decision looks the same.** This test
    /// first claimed these agreed, and it was wrong: `keep_a` on (a,b) removes b, while `keep_a` on (b,c) *keeps*
    /// b. Acting on both deletes a file the user chose to keep one pair later.
    ///
    /// Transitively it may even be what they meant -- a ≈ b ≈ c, keep a -- but nobody said "delete b" in the
    /// second pair, and inferring it is exactly the kind of helpfulness a destructive action must not have.
    @Test("A chain of pairs contradicts itself even with the same decision on both")
    func reportsContradictionsInAChain() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg"), pair("/r/b.jpg", "/r/c.jpg")]))
        state.confirmAll([0, 1], as: .keepA)
        #expect(state.contradictions == ["/r/b.jpg"])
    }

    @Test("Disjoint pairs contradict nothing")
    func staysQuietWithoutContradictions() {
        var state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg"), pair("/r/c.jpg", "/r/d.jpg")]))
        state.confirmAll([0, 1], as: .keepA)
        #expect(state.distinctRemovals == ["/r/b.jpg", "/r/d.jpg"])
        #expect(state.contradictions.isEmpty)
    }

    /// **A CLI document decides every pair**, so rehydrating one lights up the whole review. That is the shared
    /// format working as designed, and a caller should say so rather than pretend the user did it.
    @Test("Prior decisions are rehydrated by pair key")
    func rehydratesPriorDecisions() {
        let pairs = [pair("/r/a.jpg", "/r/b.jpg"), pair("/r/c.jpg", "/r/d.jpg")]
        let state = SimilarReviewState(
            scan: scan(pairs),
            priorDecisions: [
                SimilarPairKey.key(for: pairs[0]): .keepB,
                SimilarPairKey.key(for: pairs[1]): .keepNone,
            ]
        )
        #expect(state.tally == (decided: 2, skipped: 0, undecided: 0))
        #expect(state.decision(at: 0) == .decided(.keepB))
        #expect(state.decision(at: 1) == .decided(.keepNone))
        #expect(state.decisionsForSaving.count == 2)
    }

    @Test("A prior decision for a pair this scan does not hold is ignored")
    func ignoresForeignKeys() {
        let state = SimilarReviewState(
            scan: scan([pair("/r/a.jpg", "/r/b.jpg")]),
            priorDecisions: ["/r/x.jpg||/r/y.jpg": .keepA]
        )
        #expect(state.tally == (decided: 0, skipped: 0, undecided: 1))
    }

    /// The advice reaches the suggestion, which is what makes the video case worth anything.
    @Test("Media facts change the suggestion")
    func usesMediaFacts() throws {
        let subject = pair("/r/a.mp4", "/r/b.mp4", .video)
        let facts: [String: MediaFacts] = [
            "/r/a.mp4": MediaFacts(
                path: "/r/a.mp4", byteCount: 1, pixelWidth: 1920, pixelHeight: 1080,
                codec: "h264", isCodecKnown: true, bitrate: 1_000_000, duration: 600),
            "/r/b.mp4": MediaFacts(
                path: "/r/b.mp4", byteCount: 1, pixelWidth: 1920, pixelHeight: 1080,
                codec: "hevc", isCodecKnown: true, bitrate: 1_000_000, duration: 600),
        ]
        let state = SimilarReviewState(scan: scan([subject]), facts: facts)
        #expect(state.effectiveDecision(at: 0) == .keepB)
        guard case .advice = try #require(state.suggestion(at: 0)).ground else {
            Issue.record("the advice did not decide the suggestion")
            return
        }
    }

    @Test("Visiting a pair is recorded, so unseen and skipped are different")
    func recordsVisits() {
        var state = SimilarReviewState(
            scan: scan((0..<5).map { pair("/r/a\($0).jpg", "/r/b\($0).jpg") }))
        state.go(to: 3)
        #expect(state.visited.contains(3))
        #expect(!state.visited.contains(4))
        state.retreat()
        #expect(state.pairIndex == 2)
        state.advance()
        #expect(state.pairIndex == 3)
    }

    /// A snapshot is the undo mechanism, so the type has to be a value all the way down.
    @Test("A copy of the state is independent")
    func copiesCleanly() {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        let before = state
        state.confirm(.keepA)
        #expect(before.tally.decided == 0)
        #expect(state.tally.decided == 1)
    }
}

@Suite("SimilarReviewState lazy facts")
struct SimilarReviewStateFactsTests {

    /// Probing every pair before the window can draw would repeat a large part of the scan, so facts arrive for
    /// the pair being looked at.
    @Test("Facts arriving later refine the suggestion")
    func refinesASuggestion() {
        let subject = pair("/r/a.mp4", "/r/b.mp4", .video)
        var state = SimilarReviewState(scan: scan([subject]))
        // With no facts, the chain falls through to depth: both are one level down, so A wins.
        #expect(state.suggestion(at: 0)?.ground == .depth)

        state.updateSuggestion(
            at: 0,
            factsA: MediaFacts(
                path: "/r/a.mp4", byteCount: 1, pixelWidth: 1920, pixelHeight: 1080,
                codec: "h264", isCodecKnown: true, bitrate: 1_000_000, duration: 600),
            factsB: MediaFacts(
                path: "/r/b.mp4", byteCount: 1, pixelWidth: 1920, pixelHeight: 1080,
                codec: "av1", isCodecKnown: true, bitrate: 1_000_000, duration: 600)
        )
        #expect(state.effectiveDecision(at: 0) == .keepB)
        guard case .advice = state.suggestion(at: 0)?.ground else {
            Issue.record("the advice did not take over")
            return
        }
    }

    /// **A decision is not a suggestion, and facts must not quietly move it.**
    @Test("Facts do not overwrite a decision already made")
    func leavesDecisionsAlone() {
        let subject = pair("/r/a.mp4", "/r/b.mp4", .video)
        var state = SimilarReviewState(scan: scan([subject]))
        state.confirm(.keepA)
        state.updateSuggestion(
            at: 0,
            factsA: MediaFacts(
                path: "/r/a.mp4", byteCount: 1, pixelWidth: 100, pixelHeight: 100,
                codec: "h264", isCodecKnown: true, bitrate: 1, duration: 600),
            factsB: MediaFacts(
                path: "/r/b.mp4", byteCount: 1, pixelWidth: 4000, pixelHeight: 2000,
                codec: "av1", isCodecKnown: true, bitrate: 9_000_000, duration: 600)
        )
        #expect(state.decision(at: 0) == .decided(.keepA))
        #expect(state.effectiveDecision(at: 0) == .keepA)
    }

    @Test("An index out of range is ignored")
    func ignoresBadIndices() {
        var state = SimilarReviewState(scan: scan([pair("/r/a.jpg", "/r/b.jpg")]))
        state.updateSuggestion(at: 9, factsA: nil, factsB: nil)
        #expect(state.suggestions.count == 1)
    }
}
