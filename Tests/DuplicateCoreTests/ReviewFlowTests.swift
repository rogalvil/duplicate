import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private func plan(_ paths: [String]) -> [(group: DuplicateGroup, paths: [String])] {
    [(DuplicateGroup(size: 1000, digest: digest("a"), files: paths + ["/keep"]), paths)]
}

@Suite("ReviewFlow")
struct ReviewFlowTests {

    @Test("A fresh flow starts at scanned with nothing decided")
    func startsClean() {
        let flow = ReviewFlow()
        #expect(flow.step == .scanned)
        #expect(flow.hasDecisions == false)
        #expect(flow.dryRunFingerprint == nil)
    }

    /// The CLI takes a `has_decisions` parameter into `menu_options` and never reads it, so it offers "ver
    /// decisiones" for a scan with no decisions file. Cheap to get right, and a menu item that opens an
    /// empty view is a bug report waiting to happen.
    @Test("Showing decisions is offered only when decisions exist")
    func hidesDecisionsWhenThereAreNone() {
        var flow = ReviewFlow()
        #expect(flow.isAvailable(.showDecisions) == false)
        #expect(flow.isAvailable(.dryRun) == false)

        flow.decisionsChanged(hasAny: true)
        #expect(flow.isAvailable(.showDecisions))
        #expect(flow.isAvailable(.dryRun))
    }

    @Test("An unavailable action does not move the flow")
    func refusesAnUnavailableAction() {
        var flow = ReviewFlow()
        #expect(flow.advance(.apply) == nil)
        #expect(flow.step == .scanned)
        #expect(flow.advance(.back) == nil)
        #expect(flow.step == .scanned)
    }

    /// **The invariant the type exists for.** Apply is unreachable until a dry run has been produced.
    @Test("Apply is unreachable until a dry run has happened")
    func gatesApplyOnADryRun() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        #expect(flow.isAvailable(.apply) == false)

        _ = flow.advance(.dryRun, fingerprint: "abcd")
        #expect(flow.step == .dryRunDone)
        #expect(flow.isAvailable(.apply))
    }

    /// Advancing to `dryRunDone` without a fingerprint must not authorise anything. A caller that forgot
    /// the argument would otherwise get an apply gated on `step` alone, which is the weaker rule the
    /// fingerprint exists to replace.
    @Test("A dry run with no fingerprint authorises nothing")
    func refusesAFingerprintlessDryRun() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        _ = flow.advance(.dryRun)
        #expect(flow.step == .dryRunDone)
        #expect(flow.isAvailable(.apply) == false)
        #expect(throws: ApplyGateError.noDryRun) {
            try ApplyGate.authorize(flow: flow, fingerprint: "abcd")
        }
    }

    @Test("Editing decisions invalidates the dry run")
    func invalidatesOnEdit() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        _ = flow.advance(.dryRun, fingerprint: "abcd")
        #expect(flow.isAvailable(.apply))

        flow.decisionsChanged(hasAny: true)
        #expect(flow.dryRunFingerprint == nil)
        #expect(flow.isAvailable(.apply) == false)
    }

    @Test("Another round of review invalidates the dry run")
    func invalidatesOnReview() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        _ = flow.advance(.dryRun, fingerprint: "abcd")

        _ = flow.advance(.review)
        #expect(flow.step == .interactiveDone)
        #expect(flow.isAvailable(.apply) == false)
    }

    @Test("Back is offered only from the decisions view")
    func offersBackOnlyFromDecisions() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        #expect(flow.isAvailable(.back) == false)

        _ = flow.advance(.showDecisions)
        #expect(flow.step == .decisionsShown)
        #expect(flow.isAvailable(.back))

        _ = flow.advance(.back)
        #expect(flow.step == .interactiveDone)
        #expect(flow.isAvailable(.back) == false)
    }

    /// After an apply the plan has been carried out, so the same fingerprint must not authorise a second
    /// run over files that are already in the Trash.
    @Test("Applying consumes the authorisation")
    func consumesTheAuthorisation() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        _ = flow.advance(.dryRun, fingerprint: "abcd")
        _ = flow.advance(.apply)

        #expect(flow.step == .scanned)
        #expect(flow.dryRunFingerprint == nil)
        #expect(flow.isAvailable(.apply) == false)
    }

    @Test("A rescan clears the decisions and the dry run")
    func resetsOnRescan() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        _ = flow.advance(.dryRun, fingerprint: "abcd")

        _ = flow.advance(.rescan)
        #expect(flow.step == .scanned)
        #expect(flow.hasDecisions == false)
        #expect(flow.dryRunFingerprint == nil)
    }

    @Test("Review, rescan and exit are always offered")
    func alwaysOffersTheWayOut() {
        for step in FlowStep.allCases {
            for hasDecisions in [true, false] {
                let flow = ReviewFlow(step: step, hasDecisions: hasDecisions)
                #expect(flow.isAvailable(.review))
                #expect(flow.isAvailable(.rescan))
                #expect(flow.isAvailable(.exit))
            }
        }
    }

    @Test("Available actions are listed in menu order")
    func listsActionsInOrder() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        _ = flow.advance(.dryRun, fingerprint: "abcd")
        #expect(
            flow.availableActions == [
                .review, .showReport, .showDecisions, .dryRun, .apply, .rescan, .exit,
            ]
        )
    }
}

@Suite("ApplyGate")
struct ApplyGateTests {

    @Test("Authorising with no dry run throws noDryRun")
    func refusesWithNoDryRun() {
        let flow = ReviewFlow()
        #expect(throws: ApplyGateError.noDryRun) {
            try ApplyGate.authorize(flow: flow, fingerprint: "abcd")
        }
    }

    @Test("Authorising the plan that was shown succeeds")
    func acceptsTheShownPlan() throws {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        let fingerprint = ApplyGate.fingerprint(of: plan(["/a", "/b"]))
        _ = flow.advance(.dryRun, fingerprint: fingerprint)

        try ApplyGate.authorize(flow: flow, fingerprint: fingerprint)
    }

    /// The refusal that matters: the flow is at the right step and a dry run really happened, but the plan
    /// asking to run is not the plan the user approved.
    @Test("Authorising a different plan throws staleDryRun")
    func refusesADifferentPlan() {
        var flow = ReviewFlow()
        flow.decisionsChanged(hasAny: true)
        let shown = ApplyGate.fingerprint(of: plan(["/a", "/b"]))
        let other = ApplyGate.fingerprint(of: plan(["/a", "/b", "/c"]))
        _ = flow.advance(.dryRun, fingerprint: shown)

        #expect(throws: ApplyGateError.staleDryRun(shown: shown, current: other)) {
            try ApplyGate.authorize(flow: flow, fingerprint: other)
        }
    }

    @Test("A plan touching the same files fingerprints the same")
    func isStableAcrossOrder() {
        let a = ApplyGate.fingerprint(of: plan(["/x/b", "/x/a"]))
        let b = ApplyGate.fingerprint(of: plan(["/x/a", "/x/b"]))
        #expect(a == b)
    }

    /// Two groups swapped between plans must fingerprint alike, because the same files would be touched.
    /// Sorting the whole part list, not just each group's paths, is what makes that true.
    @Test("Group order does not change the fingerprint")
    func isStableAcrossGroupOrder() {
        let first = DuplicateGroup(size: 10, digest: digest("a"), files: ["/a", "/b"])
        let second = DuplicateGroup(size: 20, digest: digest("b"), files: ["/c", "/d"])
        let forward = ApplyGate.fingerprint(of: [(first, ["/b"]), (second, ["/d"])])
        let backward = ApplyGate.fingerprint(of: [(second, ["/d"]), (first, ["/b"])])
        #expect(forward == backward)
    }

    /// One path different has to give a different value, or the gate would authorise a plan that removes
    /// a file the user never saw in the dry run.
    @Test("One extra path changes the fingerprint")
    func changesWithThePlan() {
        #expect(
            ApplyGate.fingerprint(of: plan(["/a"]))
                != ApplyGate.fingerprint(of: plan(["/a", "/b"]))
        )
    }

    /// Same paths, different group: the digests differ, so the plans are not interchangeable.
    @Test("The same paths under a different group differ")
    func separatesGroups() {
        let a = ApplyGate.fingerprint(of: [
            (DuplicateGroup(size: 10, digest: digest("a"), files: ["/a", "/b"]), ["/b"])
        ])
        let b = ApplyGate.fingerprint(of: [
            (DuplicateGroup(size: 10, digest: digest("b"), files: ["/a", "/b"]), ["/b"])
        ])
        #expect(a != b)
    }

    /// A fingerprint outlives the process that made it -- a review can be reopened after a relaunch --
    /// so it cannot come from Swift's per-process-seeded `Hasher`. Pinned to the value FNV-1a defines for
    /// this input, which is what makes that property checkable at all.
    @Test("The fingerprint is a fixed function of the plan")
    func isProcessIndependent() {
        var hasher = FNV1a()
        hasher.combine("")
        #expect(hasher.value == "cbf29ce484222325")
        #expect(ApplyGate.fingerprint(of: []).count == 16)
    }

    @Test("An empty plan fingerprints stably")
    func handlesAnEmptyPlan() {
        #expect(ApplyGate.fingerprint(of: []) == ApplyGate.fingerprint(of: []))
    }
}

@Suite("ReviewFlow and ExactReviewState together")
struct ReviewFlowIntegrationTests {

    private func scan() -> DuplicateScan {
        DuplicateScan(
            scanID: "20260511-064716-685054",
            root: "/root",
            createdAt: "2026-05-11T06:47:16.685054Z",
            groups: (0..<3).map { index in
                DuplicateGroup(
                    size: 1000,
                    digest: digest("\(index)"),
                    files: ["/root/\(index)/a.bin", "/root/\(index)/b.bin"]
                )
            }
        )
    }

    /// The whole point, end to end: deciding, simulating, then editing one group has to send the user back
    /// through a fresh dry run.
    @Test("Editing one group after the dry run withdraws the approval")
    func withdrawsApprovalAfterAnEdit() throws {
        var state = ExactReviewState(scan: scan(), root: "/root")
        var flow = ReviewFlow()

        _ = state.confirm()
        flow.decisionsChanged(hasAny: !state.decisionsForSaving.isEmpty)
        let approved = ApplyGate.fingerprint(of: state.removalPlan)
        _ = flow.advance(.dryRun, fingerprint: approved)
        try ApplyGate.authorize(flow: flow, fingerprint: approved)

        state.go(to: 1)
        state.discardEntireGroup()
        flow.decisionsChanged(hasAny: true)

        let current = ApplyGate.fingerprint(of: state.removalPlan)
        #expect(current != approved)
        #expect(throws: ApplyGateError.noDryRun) {
            try ApplyGate.authorize(flow: flow, fingerprint: current)
        }
    }

    /// Skipping is not deciding, so it must not open the dry run. The CLI's skip writes a keep list, which
    /// is exactly the confusion this separation removes.
    @Test("Skipping every group leaves nothing to simulate")
    func skippingIsNotDeciding() {
        var state = ExactReviewState(scan: scan(), root: "/root")
        var flow = ReviewFlow()
        for _ in 0..<3 { _ = state.skip() }

        flow.decisionsChanged(hasAny: !state.decisionsForSaving.isEmpty)
        #expect(state.decisionsForSaving.isEmpty)
        #expect(state.removalPlan.isEmpty)
        #expect(flow.isAvailable(.dryRun) == false)
        #expect(flow.isAvailable(.apply) == false)
    }
}
