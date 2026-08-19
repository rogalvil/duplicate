import Foundation
import Testing

@testable import DuplicateCore

private func pair(
    _ similarity: Double, _ kind: MediaKind = .image, _ index: Int = 0
)
    -> SimilarPair
{
    SimilarPair(
        fileA: "/r/a\(index).jpg", fileB: "/r/b\(index).jpg", similarity: similarity,
        mediaKind: kind)
}

@Suite("PairFilter")
struct PairFilterTests {

    private let pairs: [SimilarPair] = [
        pair(1.0, .image, 0),
        pair(0.9375, .image, 1),
        pair(1.0, .video, 2),
        pair(0.75, .video, 3),
    ]

    @Test("An empty filter shows everything and is not narrowing")
    func showsEverything() {
        let filter = PairFilter()
        #expect(filter.isNarrowing == false)
        #expect(filter.matchingIndices(in: pairs, decision: { _ in .undecided }) == [0, 1, 2, 3])
    }

    /// **1.0 is its own choice**, and on the real scan it selects 2,106 of 4,771.
    @Test("A similarity floor keeps only the pairs at or above it")
    func filtersBySimilarity() {
        #expect(
            PairFilter(minimumSimilarity: 1.0)
                .matchingIndices(in: pairs, decision: { _ in .undecided }) == [0, 2])
        #expect(
            PairFilter(minimumSimilarity: 0.9)
                .matchingIndices(in: pairs, decision: { _ in .undecided }) == [0, 1, 2])
    }

    @Test("A kind filter separates image from video")
    func filtersByKind() {
        #expect(
            PairFilter(kind: .video).matchingIndices(in: pairs, decision: { _ in .undecided })
                == [2, 3])
        #expect(
            PairFilter(kind: .image).matchingIndices(in: pairs, decision: { _ in .undecided })
                == [0, 1])
    }

    /// **Narrowing decides nothing**, so a decided pair leaving the list is the filter working, not a mutation.
    @Test("Only-undecided hides what has been decided or skipped")
    func filtersByDecision() {
        let filter = PairFilter(onlyUndecided: true)
        let shown = filter.matchingIndices(in: pairs) { index in
            switch index {
            case 0: return .decided(.keepA)
            case 1: return .skipped
            default: return .undecided
            }
        }
        #expect(shown == [2, 3])
    }

    @Test("The filters combine")
    func combinesFilters() {
        let filter = PairFilter(minimumSimilarity: 1.0, kind: .video, onlyUndecided: true)
        #expect(filter.isNarrowing)
        #expect(filter.matchingIndices(in: pairs, decision: { _ in .undecided }) == [2])
    }

    @Test("The menu offers 1.0 as its own choice")
    func offersIdenticalAsAChoice() {
        #expect(PairFilter.similarityChoices.contains(1.0))
        #expect(PairFilter.similarityChoices.first == 0)
    }

    @Test("An empty scan matches nothing without failing")
    func handlesAnEmptyScan() {
        #expect(PairFilter().matchingIndices(in: [], decision: { _ in .undecided }).isEmpty)
    }
}
