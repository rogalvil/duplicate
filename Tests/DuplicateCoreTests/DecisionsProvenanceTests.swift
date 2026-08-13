import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

private func scan(groupCount: Int) -> DuplicateScan {
    DuplicateScan(
        scanID: "20260812-120000-000000",
        root: "/r",
        createdAt: "2026-08-12T12:00:00.000000Z",
        groups: (0..<groupCount).map { index in
            DuplicateGroup(
                size: Int64(100 + index),
                digest: digest(String(index % 10)),
                files: ["/r/\(index)/a", "/r/\(index)/b"]
            )
        }
    )
}

@Suite("DecisionsProvenance")
struct DecisionsProvenanceTests {

    @Test("No decisions file is none")
    func reportsNone() {
        #expect(
            DecisionsProvenance.classify(scan: scan(groupCount: 10), priorDecisions: [:]) == .none)
    }

    @Test("A review of some groups is partial")
    func reportsPartial() {
        let subject = scan(groupCount: 10)
        let prior = [subject.groups[0].key: ["/r/0/a"], subject.groups[1].key: ["/r/1/a"]]
        #expect(
            DecisionsProvenance.classify(scan: subject, priorDecisions: prior)
                == .partial(decided: 2, groups: 10)
        )
    }

    /// **What the CLI writes, every time.** Measured on this machine's corpus: 55 of 56 decisions files hold
    /// exactly one decision per group, and the only partial one is the file this app wrote.
    @Test("A decision for every group is flagged")
    func reportsFullCoverage() {
        let subject = scan(groupCount: 10)
        let prior = Dictionary(
            uniqueKeysWithValues: subject.groups.map { ($0.key, ["/r/x/a"]) })
        let provenance = DecisionsProvenance.classify(scan: subject, priorDecisions: prior)
        #expect(provenance == .coversEveryGroup(groups: 10))
        #expect(provenance.deservesAWarning)
        #expect(provenance.decidedCount == 10)
    }

    /// A small scan whose groups really were all reviewed is the honest case, and interrupting for it would
    /// train the user to dismiss the warning.
    @Test("Full coverage of a tiny scan is not worth a warning")
    func staysQuietForTinyScans() {
        let subject = scan(groupCount: 3)
        let prior = Dictionary(
            uniqueKeysWithValues: subject.groups.map { ($0.key, ["/r/x/a"]) })
        let provenance = DecisionsProvenance.classify(scan: subject, priorDecisions: prior)
        #expect(provenance == .coversEveryGroup(groups: 3))
        #expect(provenance.deservesAWarning == false)
    }

    /// A decisions file left over from a different scan of the same folder shares no group keys, so it
    /// contributes nothing -- and must not be read as coverage of this one.
    @Test("Decisions for other groups are not coverage")
    func ignoresForeignKeys() {
        let subject = scan(groupCount: 10)
        let prior = ["999:" + digest("f").hexString: ["/elsewhere/a"]]
        #expect(DecisionsProvenance.classify(scan: subject, priorDecisions: prior) == .none)
    }

    @Test("A mix of matching and foreign keys counts only the matching ones")
    func countsOnlyMatchingKeys() {
        let subject = scan(groupCount: 10)
        var prior = ["999:" + digest("f").hexString: ["/elsewhere/a"]]
        prior[subject.groups[0].key] = ["/r/0/a"]
        #expect(
            DecisionsProvenance.classify(scan: subject, priorDecisions: prior)
                == .partial(decided: 1, groups: 10)
        )
    }

    @Test("An empty scan is none")
    func handlesAnEmptyScan() {
        #expect(
            DecisionsProvenance.classify(
                scan: scan(groupCount: 0), priorDecisions: ["a": ["/x"]]) == .none
        )
    }

    /// The threshold is where "I reviewed them all" stops being the likely explanation.
    @Test("The warning threshold is five groups")
    func warnsFromFiveGroups() {
        for count in 1...8 {
            let subject = scan(groupCount: count)
            let prior = Dictionary(
                uniqueKeysWithValues: subject.groups.map { ($0.key, ["/r/x/a"]) })
            let provenance = DecisionsProvenance.classify(scan: subject, priorDecisions: prior)
            #expect(provenance.deservesAWarning == (count >= 5))
        }
    }
}
