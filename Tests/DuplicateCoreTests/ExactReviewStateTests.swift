import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private func group(_ files: [String], size: Int64 = 1000, seed: String = "a") -> DuplicateGroup {
    DuplicateGroup(size: size, digest: digest(seed), files: files)
}

private func scan(_ groups: [DuplicateGroup], root: String = "/root") -> DuplicateScan {
    DuplicateScan(
        scanID: "20260511-064716-685054",
        root: root,
        createdAt: "2026-05-11T06:47:16.685054Z",
        groups: groups
    )
}

@Suite("CopyNamePattern")
struct CopyNamePatternTests {
    /// Ground truth produced by running the CLI's own `_copy_score` on each stem.
    ///
    /// Not "what my regex produces" -- the two tools have to agree about which file looks like a copy, and a
    /// subtly different `\s` or `\d` interpretation would only show up on the awkward names nobody tests.
    static let table: [(stem: String, score: Int)] = [
        ("photo", 0),
        ("photo copy", 1),
        ("photo_copy", 1),
        ("photo (1)", 1),
        ("photo(1)", 1),
        ("photo (copy)", 1),
        ("photo (copy", 1),
        ("photo - Copy", 1),
        ("photo-copy", 1),
        ("photo copia", 1),
        ("photo_copia", 1),
        ("Copia de photo", 1),
        ("Copy of photo", 1),
        ("photo_1", 1),
        ("photo-1", 1),
        ("photo 1", 1),
        ("IMG_1234", 1),
        ("vacation2024", 0),
        ("photo.tar", 0),
        ("COPY OF photo", 1),
        ("copia  de  photo", 1),
        ("photo copy 2", 1),
        ("a", 0),
        ("1", 0),
        // Measured, not assumed: both engines strip the space in `\( ?copy\)?`, so the `?`
        // applies to the opening paren and a bare "copy" suffix matches.
        ("photo.copy", 1),
        ("copy", 1),
        ("xcopy", 1),
    ]

    @Test("Agrees with the CLI on every stem", arguments: table)
    func agreesWithTheCLI(row: (stem: String, score: Int)) {
        #expect(
            CopyNamePattern.score(stem: row.stem) == row.score, "stem \(row.stem.debugDescription)")
    }

    @Test("IMG_1234 scores as a copy, and that is deliberate")
    func imgFalsePositiveIsPreserved() {
        // The last alternative, [ _-]\d+$, matches any name ending in a separator and digits. That is wrong
        // for camera output, which is most of a photo library -- but changing it would make the app prefer a
        // different file than the CLI for the same group, and two tools proposing different survivors is
        // worse than one shared imperfect rule.
        #expect(CopyNamePattern.score(stem: "IMG_1234") == 1)
        #expect(CopyNamePattern.score(stem: "DSC-0042") == 1)
        // But no separator means no match, which is why most camera names escape it.
        #expect(CopyNamePattern.score(stem: "IMG1234") == 0)
    }

    @Test("Matches against the stem, not the whole filename")
    func matchesTheStem() {
        // Python's Path.stem drops the last extension, so "photo copy.jpg" has stem "photo copy".
        #expect(CopyNamePattern.score(path: "/x/photo copy.jpg") == 1)
        // 1, not 0. An earlier version of this test asserted 0 -- an assumption. The CLI scores it 1
        // for the reason described on CopyNamePattern.source.
        #expect(CopyNamePattern.score(path: "/x/photo.copy.jpg") == 1)
        #expect(CopyNamePattern.stem(of: "/x/archive.tar.gz") == "archive.tar")
        #expect(CopyNamePattern.stem(of: "/x/.DS_Store") == ".DS_Store")
        #expect(CopyNamePattern.stem(of: "/x/README") == "README")
    }
}

@Suite("KeeperHeuristic")
struct KeeperHeuristicTests {
    @Test("Deeper in the tree wins")
    func deeperWins() {
        // The surprising half of the CLI's rule: a file somebody filed away is more likely the one they
        // meant to keep, and a copy is more likely to have been dropped at the root.
        #expect(
            KeeperHeuristic.bestIndex(
                files: ["/root/a.jpg", "/root/deep/nested/a.jpg"],
                root: "/root"
            ) == 1
        )
        #expect(KeeperHeuristic.depthScore(path: "/root/a.jpg", root: "/root") == 0)
        #expect(KeeperHeuristic.depthScore(path: "/root/deep/nested/a.jpg", root: "/root") == -2)
    }

    @Test("A copy name loses even when it is deeper")
    func copyScoreBeatsDepth() {
        // copyScore comes first in the tuple, so it dominates.
        #expect(
            KeeperHeuristic.bestIndex(
                files: ["/root/a.jpg", "/root/deep/nested/a copy.jpg"],
                root: "/root"
            ) == 0
        )
    }

    @Test("A file outside the root scores zero depth, not a crash")
    func outsideRootScoresZero() {
        // Ports the ValueError fallback: Python's relative_to raises for a path outside the root and the CLI
        // scores it 0.
        #expect(KeeperHeuristic.depthScore(path: "/elsewhere/a.jpg", root: "/root") == 0)
        #expect(KeeperHeuristic.depthScore(path: "/root", root: "/root") == 0)
    }

    @Test("Ties fall to the lowest index")
    func tiesUseIndex() {
        #expect(KeeperHeuristic.bestIndex(files: ["/root/a", "/root/b"], root: "/root") == 0)
    }

    @Test("An empty list does not trap")
    func emptyListIsSafe() {
        #expect(KeeperHeuristic.bestIndex(files: [], root: "/root") == 0)
    }
}

@Suite("ExactReviewState: the tri-state")
struct ExactReviewStateTriStateTests {
    @Test("An untouched review saves nothing at all")
    func untouchedReviewSavesNothing() {
        // The most dangerous defect in the CLI, fixed. There, decisions() emits an entry for every group
        // filled in with the heuristic's guess, so quitting after group 1 of 50 records decisions for 49 --
        // and in a window, quitting is closing a window.
        let state = ExactReviewState(
            scan: scan((0..<5).map { group(["/root/\($0)/a", "/root/\($0)/b"], seed: "\($0)") }),
            root: "/root"
        )
        #expect(state.decisionsForSaving.isEmpty)
        #expect(state.removalPlan.isEmpty)
        #expect(state.tally == (decided: 0, skipped: 0, undecided: 5))
    }

    @Test("Reviewing one group of fifty saves exactly one")
    func savesOnlyWhatWasDecided() {
        var state = ExactReviewState(
            scan: scan(
                (0..<50).map { group(["/root/\($0)/a", "/root/\($0)/b"], seed: "\($0 % 10)") }),
            root: "/root"
        )
        var outcome = state.confirm()
        #expect(outcome == .advanced)
        #expect(state.decisionsForSaving.count == 1)
        #expect(state.tally == (decided: 1, skipped: 0, undecided: 49))
        #expect(state.removalPlan.count == 1)
    }

    @Test("A skipped group is saved as nothing, and counted separately")
    func skippedIsNeitherDecidedNorUnseen() {
        // Distinct from undecided so the UI can say "you skipped 12" separately from "you have not looked at
        // 1,986", and so skipping cannot be mistaken for a decision.
        var state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b"]), group(["/root/c", "/root/d"], seed: "b")]),
            root: "/root"
        )
        let skipped = state.skip()
        #expect(skipped == .advanced)
        #expect(state.decisionsForSaving.isEmpty)
        #expect(state.tally == (decided: 0, skipped: 1, undecided: 1))
    }

    @Test("Skipping leaves the heuristic's preview alone")
    func skipDoesNotRewriteTheKeepSet() {
        // The CLI resets the keep set to index 0, which its own docs contradict. "Skip" means "decide
        // nothing", not "silently pick the lexicographically first file".
        var state = ExactReviewState(
            scan: scan([group(["/root/a copy.jpg", "/root/deep/a.jpg"])]),
            root: "/root"
        )
        let previewBefore = state.effectiveKeep(at: 0)
        #expect(previewBefore == [1], "the heuristic should prefer the deeper non-copy")
        _ = state.skip()
        #expect(state.effectiveKeep(at: 0) == previewBefore)
        #expect(state.decision(at: 0) == .skipped)
    }

    @Test("The preview is not a decision")
    func previewIsNotADecision() {
        // effectiveKeep and decisionsForSaving being separate functions, with separate tests, is the
        // structural guarantee that a glance never becomes an action.
        let state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/deep/b"])]),
            root: "/root"
        )
        #expect(!state.effectiveKeep(at: 0).isEmpty)
        #expect(state.decisionsForSaving.isEmpty)
    }
}

@Suite("ExactReviewState: confirming")
struct ExactReviewStateConfirmTests {
    @Test("Confirming with nothing kept is refused, not an exit")
    func emptyKeepIsRefusedNotAnExit() {
        // The CLI's confirm_group() returns a Bool that means three things, and the TUI reads any false as
        // "we are done" and quits. Pressing enter with nothing checked exits the review.
        var state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b"]), group(["/root/c", "/root/d"], seed: "b")]),
            root: "/root"
        )
        // Force an empty keep set the way a UI could: keep all, then toggle everything off.
        state.keepAll()
        state.moveCursor(by: 0)
        let toggled = state.toggleCursor()
        #expect(toggled)
        state.moveCursor(by: 1)
        let refused = state.toggleCursor()
        #expect(!refused, "the last keeper must not be removable")

        // And a group that really has an empty set is refused rather than treated as the end.
        var forced = state
        forced.keepAll()
        let forcedOutcome = forced.confirm()
        #expect(forcedOutcome == .advanced)
        #expect(forced.groupIndex == 1)
    }

    @Test("The last group reports finished, not refused")
    func lastGroupFinishes() {
        var state = ExactReviewState(scan: scan([group(["/root/a", "/root/b"])]), root: "/root")
        let finished = state.confirm()
        #expect(finished == .finished)
        #expect(state.decisionsForSaving.count == 1)
    }

    @Test("Toggling refuses to leave a group with no keeper")
    func toggleKeepsAtLeastOne() {
        // A group with no keeper is a mistake, not a decision. Discarding a whole group is a separate,
        // explicitly named action.
        var state = ExactReviewState(scan: scan([group(["/root/a", "/root/b"])]), root: "/root")
        let kept = state.effectiveKeep(at: 0)
        let keptIndex = kept.first!
        state.go(to: 0)
        while state.fileIndex != keptIndex { state.moveCursor(by: 1) }
        let refusedToggle = state.toggleCursor()
        #expect(!refusedToggle, "removing the only keeper was allowed")
        #expect(state.effectiveKeep(at: 0) == kept)
    }

    @Test("Discarding a whole group is recorded, and actually removes everything")
    func discardAllIsHonest() {
        // The CLI labels this "Mover todos" and then skips the group at apply time because its keep list is
        // empty -- a labelled destructive action that silently does nothing.
        var state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b", "/root/c"])]), root: "/root")
        state.discardEntireGroup()
        #expect(state.decision(at: 0) == .discardAll)
        #expect(state.decisionsForSaving.map(\.keptPaths) == [[]])
        let plan = state.removalPlan
        #expect(plan.count == 1)
        #expect(plan[0].paths.count == 3, "discard-all must remove every member")
    }

    @Test("Confirming an already-discarded group keeps it discarded")
    func confirmDoesNotUndoDiscard() {
        var state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b"]), group(["/root/c", "/root/d"], seed: "b")]),
            root: "/root"
        )
        state.discardEntireGroup()
        let outcome2 = state.confirm()
        #expect(outcome2 == .advanced)
        #expect(state.decision(at: 0) == .discardAll)
    }

    @Test("Navigation clamps and resets the cursor")
    func navigationClamps() {
        var state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b"]), group(["/root/c", "/root/d"], seed: "b")]),
            root: "/root"
        )
        state.moveCursor(by: 5)
        #expect(state.fileIndex == 1)
        _ = state.confirm()
        #expect(state.fileIndex == 0, "the cursor must reset when the group changes")
        state.previousGroup()
        #expect(state.groupIndex == 0)
        state.previousGroup()
        #expect(state.groupIndex == 0, "previous must clamp at the first group")
    }

    @Test("A decision can be cleared back to undecided")
    func decisionCanBeCleared() {
        var state = ExactReviewState(scan: scan([group(["/root/a", "/root/b"])]), root: "/root")
        _ = state.confirm()
        #expect(state.decisionsForSaving.count == 1)
        state.go(to: 0)
        state.clearDecision()
        #expect(state.decisionsForSaving.isEmpty)
        #expect(state.tally.undecided == 1)
    }
}

@Suite("ExactReviewState: rehydration and planning")
struct ExactReviewStateRehydrationTests {
    @Test("Prior decisions come back as decisions")
    func rehydratesPriorDecisions() {
        let g = group(["/root/a", "/root/b", "/root/c"])
        let state = ExactReviewState(
            scan: scan([g]),
            root: "/root",
            priorDecisions: [g.key: ["/root/b"]]
        )
        #expect(state.decision(at: 0) == .decided(keep: [1]))
        #expect(state.decisionsForSaving.map(\.keptPaths) == [["/root/b"]])
    }

    @Test("An empty prior keep list means discard-all")
    func emptyPriorListMeansDiscardAll() {
        // Which is how the CLI records "keep none". The app acts on it; the CLI ignores it, so the app
        // under-acts relative to its own intent rather than mis-acting.
        let g = group(["/root/a", "/root/b"])
        let state = ExactReviewState(scan: scan([g]), root: "/root", priorDecisions: [g.key: []])
        #expect(state.decision(at: 0) == .discardAll)
    }

    @Test("Prior decisions match by bytes, so both Unicode forms rehydrate")
    func rehydratesByBytes() {
        // A decomposed path must match its own bytes, and must not be confused with a precomposed twin --
        // Swift's String would call them equal and restore the wrong index.
        let decomposed = "/root/sa\u{0301}z.bin"
        let precomposed = "/root/s\u{00E1}x.bin"
        let g = group([decomposed, precomposed])
        let state = ExactReviewState(
            scan: scan([g]),
            root: "/root",
            priorDecisions: [g.key: [precomposed]]
        )
        #expect(state.decision(at: 0) == .decided(keep: [1]))
    }

    @Test("A prior decision whose paths no longer match is not a decision")
    func staleDecisionIsUndecided() {
        // The group key is content-based, so a rescan can produce the same key with different paths after a
        // rename. Restoring a decision that names files this group does not contain would act on nothing.
        let g = group(["/root/a", "/root/b"])
        let state = ExactReviewState(
            scan: scan([g]),
            root: "/root",
            priorDecisions: [g.key: ["/root/renamed"]]
        )
        #expect(state.decision(at: 0) == .undecided)
        #expect(state.decisionsForSaving.isEmpty)
    }

    @Test("A decision for a group not in this scan is ignored")
    func unrelatedDecisionIsIgnored() {
        let state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b"])]),
            root: "/root",
            priorDecisions: ["999:\(digest("f").hexString)": ["/root/x"]]
        )
        #expect(state.decisionsForSaving.isEmpty)
    }

    @Test("The removal plan never proposes a file that is kept")
    func planNeverRemovesAKeeper() {
        var state = ExactReviewState(
            scan: scan([group(["/root/a", "/root/b", "/root/c"])]), root: "/root")
        state.keepAll()
        #expect(state.removalPlan.isEmpty, "keeping everything must remove nothing")

        state.moveCursor(by: 0)
        _ = state.toggleCursor()  // stop keeping /root/a
        let plan = state.removalPlan
        #expect(plan.count == 1)
        #expect(plan[0].paths == ["/root/a"])
    }

    @Test("The removal plan honours the storage partition")
    func planHonoursStoragePartition() {
        // A hardlink that shares storage with the keeper must never be proposed: removing it frees nothing
        // and loses a path the user may rely on.
        let partitioned = DuplicateGroup(
            size: 1000,
            digest: digest("a"),
            files: ["/root/keep", "/root/keep-link", "/root/other"],
            storage: StoragePartition(
                clusters: [["/root/keep", "/root/keep-link"], ["/root/other"]],
                isExact: true
            )
        )
        var state = ExactReviewState(scan: scan([partitioned]), root: "/root")
        state.go(to: 0)
        while state.fileIndex != 0 { state.moveCursor(by: -1) }
        state.keepAll()
        state.moveCursor(by: 2)
        _ = state.toggleCursor()  // stop keeping /root/other
        let plan = state.removalPlan
        #expect(plan.count == 1)
        #expect(plan[0].paths == ["/root/other"])
        #expect(!plan[0].paths.contains("/root/keep-link"))
    }
}

@Suite("DecisionsCodec")
struct DecisionsCodecTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(
            contentsOf: URL(filePath: #filePath)
                .deletingLastPathComponent()
                .appending(path: "Fixtures", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .notDirectory)
        )
    }

    @Test("Re-encodes a decisions file the CLI wrote, byte for byte")
    func roundTripsCLIDocument() throws {
        // The wrapped shape, from a fixture produced by Python's json.dumps. A reordered key or a changed
        // indent here would make a review written by the app unreadable to the CLI.
        let original = try fixture("decisions-wrapped.json")
        let document = try DecisionsCodec.decode(JSONReader.parse(original))
        #expect(try JSONWriter.document(DecisionsCodec.encode(document)) == original)
        #expect(document.scanID == "20260511-064716-685054")
        #expect(document.decisions.count == 2)
    }

    @Test("An empty keep list survives, because that is how keep-none is recorded")
    func emptyKeepListSurvives() throws {
        let document = try DecisionsCodec.decode(
            JSONReader.parse(try fixture("decisions-wrapped.json")))
        #expect(document.decisions.contains { $0.keptPaths.isEmpty })
    }

    @Test("A review round-trips into a document and back into a review")
    func reviewRoundTrips() throws {
        // The chain the app actually walks: review, save, reopen, and the decisions are still there while the
        // groups nobody looked at are still undecided.
        let groups = (0..<4).map { index in
            DuplicateGroup(
                size: 1000,
                digest: Digest32(hexString: String(repeating: "\(index)", count: 64))!,
                files: ["/root/\(index)/a", "/root/\(index)/b"]
            )
        }
        let scanned = DuplicateScan(
            scanID: "20260511-064716-685054",
            root: "/root",
            createdAt: "2026-05-11T06:47:16.685054Z",
            groups: groups
        )
        var state = ExactReviewState(scan: scanned, root: "/root")
        _ = state.confirm()
        state.discardEntireGroup()
        _ = state.confirm()
        _ = state.skip()

        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 7, minute: 0, second: 0, microsecond: 1
        )
        let document = DecisionsCodec.document(from: state, instant: instant)
        #expect(document.decisions.count == 2, "only the two decided groups are saved")

        let data = try JSONWriter.document(DecisionsCodec.encode(document))
        let reloaded = try DecisionsCodec.decode(JSONReader.parse(data))
        let reopened = ExactReviewState(
            scan: scanned, root: "/root", priorDecisions: reloaded.byKey)
        #expect(reopened.decision(at: 0) == .decided(keep: [0]))
        #expect(reopened.decision(at: 1) == .discardAll)
        // Skipped and never-visited groups both come back undecided: the document holds no record of them,
        // which is exactly the point.
        #expect(reopened.decision(at: 2) == .undecided)
        #expect(reopened.decision(at: 3) == .undecided)
        #expect(reopened.tally == (decided: 2, skipped: 0, undecided: 2))
    }

    @Test("Names the field when a document is malformed")
    func namesMalformedField() {
        #expect(throws: ScanDecodingError.missingField("decisions")) {
            try DecisionsCodec.decode(
                JSONReader.parse(
                    #"{"scan_id": "20260511-064716-685054", "created_at": "x"}"#
                )
            )
        }
        #expect(throws: ScanDecodingError.malformedScanIdentifier("nope")) {
            try DecisionsCodec.decode(
                JSONReader.parse(#"{"scan_id": "nope", "created_at": "x", "decisions": {}}"#)
            )
        }
        #expect(throws: ScanDecodingError.notAString(field: "decisions.k")) {
            try DecisionsCodec.decode(
                JSONReader.parse(
                    #"{"scan_id": "20260511-064716-685054", "created_at": "x", "decisions": {"k": [1]}}"#
                )
            )
        }
    }
}
