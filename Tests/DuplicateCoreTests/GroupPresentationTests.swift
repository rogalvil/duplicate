import Foundation
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

@Suite("PathElision")
struct PathElisionTests {

    @Test("A short path is returned untouched")
    func leavesShortPathsAlone() {
        #expect(PathElision.elide("/a/b.txt") == "/a/b.txt")
        #expect(PathElision.elide("/a/b/c/d.txt") == "/a/b/c/d.txt")
        #expect(PathElision.elide("b.txt") == "b.txt")
    }

    /// The middle goes, not the end. The tail identifies the file and the head says which volume it is on;
    /// the directory levels in between are what nobody needs.
    @Test("A long path loses its middle")
    func elidesTheMiddle() {
        let elided = PathElision.elide("/Volumes/Externo/Fotos/2019/07/viaje/IMG_1234.jpg")
        #expect(elided == "/Volumes/Externo/\u{2026}/viaje/IMG_1234.jpg")
        // The file name always survives, which is the point.
        #expect(elided.hasSuffix("IMG_1234.jpg"))
    }

    @Test("A relative path stays relative")
    func keepsRelativePathsRelative() {
        let elided = PathElision.elide("a/b/c/d/e/f.txt")
        #expect(!elided.hasPrefix("/"))
        #expect(elided == "a/b/\u{2026}/e/f.txt")
    }

    @Test("Elision widths are honoured")
    func honoursWidths() {
        let path = "/one/two/three/four/five/six.txt"
        #expect(PathElision.elide(path, leading: 1, trailing: 1) == "/one/\u{2026}/six.txt")
        #expect(
            PathElision.elide(path, leading: 3, trailing: 1) == "/one/two/three/\u{2026}/six.txt")
        // A nonsense width returns the path rather than an unreadable fragment.
        #expect(PathElision.elide(path, trailing: 0) == path)
    }

    /// **The case a byte-prefix implementation gets wrong.** `/a/bc/x` and `/a/bd/y` share the byte prefix
    /// `/a/b`, which is not a directory either file is in -- hoisting it into a header would put a path on
    /// screen that does not exist.
    @Test("A common parent is whole components, not a byte prefix")
    func comparesWholeComponents() {
        #expect(PathElision.commonParent(of: ["/a/bc/x", "/a/bd/y"]) == "/a")
        #expect(
            PathElision.commonParent(of: ["/photos/trip/a.jpg", "/photos/trip/b.jpg"])
                == "/photos/trip")
    }

    @Test("A common parent excludes the file name")
    func excludesTheFileName() {
        // Both are in /a/b; /a/b/c is not a directory of the second file.
        #expect(PathElision.commonParent(of: ["/a/b/c", "/a/b/d"]) == "/a/b")
    }

    /// A header reading `/` tells the reader nothing and costs a line.
    @Test("Sharing only the root is not a common parent")
    func rejectsRootOnly() {
        #expect(PathElision.commonParent(of: ["/a/x", "/b/y"]) == nil)
        #expect(PathElision.commonParent(of: ["/x", "/y"]) == nil)
    }

    @Test("One path or none has no common parent")
    func needsTwoPaths() {
        #expect(PathElision.commonParent(of: []) == nil)
        #expect(PathElision.commonParent(of: ["/a/b/c"]) == nil)
    }

    /// A scan can hold relative paths, and a mix cannot be given a common ancestor that names anything.
    @Test("A mix of absolute and relative paths has no common parent")
    func refusesAMix() {
        #expect(PathElision.commonParent(of: ["/a/b/x", "a/b/y"]) == nil)
        #expect(PathElision.commonParent(of: ["a/b/x", "a/b/y"]) == "a/b")
    }

    /// Two spellings of the same accented name are two different directories to the volume this scan came
    /// from, so the comparison has to be byte-wise here as everywhere else.
    @Test("Precomposed and decomposed directory names are not the same parent")
    func comparesByBytes() {
        let precomposed = "/Users/t/Su\u{00E1}rez/a.jpg"
        let decomposed = "/Users/t/Su\u{0061}\u{0301}rez/b.jpg"
        // Swift's own `==` would call these directories equal, which is exactly the trap.
        #expect("Su\u{00E1}rez" == "Su\u{0061}\u{0301}rez")
        #expect(PathElision.commonParent(of: [precomposed, decomposed]) == "/Users/t")
    }

    @Test("A path is made relative to its parent")
    func makesPathsRelative() {
        #expect(PathElision.relative("/a/b/c.txt", to: "/a/b") == "c.txt")
        #expect(PathElision.relative("/a/b/sub/c.txt", to: "/a/b") == "sub/c.txt")
        #expect(PathElision.relative("/a/b/c.txt", to: "/a/b/") == "c.txt")
        // Not inside: returned unchanged rather than mangled.
        #expect(PathElision.relative("/other/c.txt", to: "/a/b") == "/other/c.txt")
        #expect(PathElision.relative("/a/b", to: "/a/b") == "/a/b")
    }
}

@Suite("GroupPresentation")
struct GroupPresentationTests {

    private func group(
        files: [String],
        size: Int64 = 1024,
        storage: StoragePartition? = nil
    ) -> DuplicateGroup {
        DuplicateGroup(size: size, digest: digest("a"), files: files, storage: storage)
    }

    @Test("The common parent is hoisted out of every row")
    func hoistsTheCommonParent() {
        let presentation = GroupPresentation(
            group: group(files: ["/photos/trip/a.jpg", "/photos/trip/copy/a.jpg"]),
            keep: [0],
            decision: .decided(keep: [0]),
            root: "/photos"
        )
        #expect(presentation.commonParent == "/photos/trip")
        #expect(presentation.rows.map(\.displayPath) == ["a.jpg", "copy/a.jpg"])
        // The full path is still there: the window needs it to reveal the file.
        #expect(presentation.rows[1].path == "/photos/trip/copy/a.jpg")
    }

    @Test("With no common parent the rows show full paths")
    func fallsBackToFullPaths() {
        let presentation = GroupPresentation(
            group: group(files: ["/a/x.jpg", "/b/y.jpg"]),
            keep: [0],
            decision: .decided(keep: [0]),
            root: "/"
        )
        #expect(presentation.commonParent == nil)
        #expect(presentation.rows.map(\.displayPath) == ["/a/x.jpg", "/b/y.jpg"])
    }

    @Test("Kept files are marked and the rest are removable")
    func marksKeptAndRemovable() {
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b", "/r/c"]),
            keep: [1],
            decision: .decided(keep: [1]),
            root: "/r"
        )
        #expect(presentation.rows.map(\.isKept) == [false, true, false])
        #expect(presentation.rows.map(\.isRemovable) == [true, false, true])
        #expect(presentation.keptCount == 1)
        #expect(presentation.removableCount == 2)
    }

    /// **The number a duplicate finder gets caught lying about.** A hardlink or an APFS clone of the keeper
    /// is the same bytes under another name: trashing it frees nothing, and it must never be offered as if
    /// it would.
    @Test("A file sharing storage with the keeper is not removable")
    func neverOffersTheKeepersOwnStorage() {
        let partition = StoragePartition(
            clusters: [["/r/a", "/r/hardlink"], ["/r/independent"]],
            isExact: true
        )
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/hardlink", "/r/independent"], storage: partition),
            keep: [0],
            decision: .decided(keep: [0]),
            root: "/r"
        )
        #expect(presentation.rows[1].sharesStorageWithKeeper)
        #expect(presentation.rows[1].isRemovable == false)
        #expect(presentation.rows[2].sharesStorageWithKeeper == false)
        #expect(presentation.rows[2].isRemovable)
        #expect(presentation.hasSharedStorage)
        // Three files, two storage classes: keeping one frees one class, not two files.
        #expect(presentation.distinctCopies == 2)
        #expect(presentation.reclaimableBytes == 1024)
    }

    /// The window and the apply run have to agree about which file survives, or the user approves one plan
    /// and another one runs. Both take the lowest kept index.
    @Test("The keeper matches the one the removal plan uses")
    func agreesWithTheRemovalPlan() {
        let subject = group(files: ["/r/a", "/r/b", "/r/c"])
        let scan = DuplicateScan(
            scanID: "20260511-064716-685054", root: "/r",
            createdAt: "2026-05-11T06:47:16.685054Z", groups: [subject]
        )
        var state = ExactReviewState(scan: scan, root: "/r")
        state.go(to: 0)
        // Keep the last two, so the lowest kept index is 1.
        state.moveCursor(by: 1)
        _ = state.toggleCursor()
        state.moveCursor(by: 1)
        _ = state.toggleCursor()

        let keep = state.effectiveKeep(at: 0)
        let presentation = GroupPresentation(
            group: subject, keep: keep, decision: state.decision(at: 0), root: "/r")
        let planned = Set(state.removalPlan.first?.paths ?? [])
        let shown = Set(presentation.rows.filter(\.isRemovable).map(\.path))
        #expect(shown == planned)
    }

    @Test("An undecided group previews the heuristic without claiming a decision")
    func previewsWithoutDeciding() {
        let subject = group(files: ["/r/copia de a.jpg", "/r/deep/nested/a.jpg"])
        let scan = DuplicateScan(
            scanID: "20260511-064716-685054", root: "/r",
            createdAt: "2026-05-11T06:47:16.685054Z", groups: [subject]
        )
        let state = ExactReviewState(scan: scan, root: "/r")
        let presentation = GroupPresentation(
            group: subject,
            keep: state.effectiveKeep(at: 0),
            decision: state.decision(at: 0),
            root: "/r"
        )
        // The deeper, non-copy name wins the preview.
        #expect(presentation.rows[1].isKept)
        #expect(presentation.rows[0].looksLikeCopy)
        #expect(presentation.rows[1].looksLikeCopy == false)
        // But nothing is decided, so nothing would be freed.
        #expect(presentation.decision == .undecided)
        #expect(presentation.reclaimableBytes == 0)
    }

    @Test("A skipped group frees nothing")
    func skippedFreesNothing() {
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b"]),
            keep: [0],
            decision: .skipped,
            root: "/r"
        )
        #expect(presentation.reclaimableBytes == 0)
    }

    /// Discarding the whole group frees every copy's storage, not one fewer.
    @Test("Discarding the group frees every storage class")
    func discardAllFreesEverything() {
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b", "/r/c"], size: 100),
            keep: [],
            decision: .discardAll,
            root: "/r"
        )
        #expect(presentation.reclaimableBytes == 300)
        #expect(presentation.keptCount == 0)
    }

    @Test("Storage clusters are reported per row")
    func reportsClusters() {
        let partition = StoragePartition(
            clusters: [["/r/a", "/r/b"], ["/r/c"]],
            isExact: true
        )
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b", "/r/c"], storage: partition),
            keep: [0],
            decision: .decided(keep: [0]),
            root: "/r"
        )
        #expect(presentation.rows.map(\.storageCluster) == [0, 0, 1])
    }

    /// A scan the CLI wrote records no partition, so nothing is known about sharing and the figure has to
    /// be labelled rather than presented as fact.
    @Test("Without a partition the figure is flagged inexact")
    func flagsAnUnknownPartition() {
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b"]),
            keep: [0],
            decision: .decided(keep: [0]),
            root: "/r"
        )
        #expect(presentation.isReclaimExact == false)
        #expect(presentation.rows.allSatisfy { $0.storageCluster == nil })
    }

    /// **Keeping every file frees nothing, and the header used to say otherwise.**
    ///
    /// The old figure was `distinctCopies - 1` -- the group's own "keep one, drop the rest" -- which does
    /// not read the decision at all. With both files of a pair checked, the window announced a full
    /// copy's worth of savings next to the button that trashes files, while the plan correctly moved
    /// nothing.
    @Test("Keeping every file in a group frees nothing")
    func keepingEverythingFreesNothing() {
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b"], size: 15_300),
            keep: [0, 1],
            decision: .decided(keep: [0, 1]),
            root: "/r"
        )
        #expect(presentation.reclaimableBytes == 0)
        #expect(presentation.removableCount == 0)
        #expect(presentation.rows.allSatisfy { $0.isRemovable == false })
    }

    /// The figure tracks the kept set rather than the file count: three files with two kept leaves one to
    /// move, so one file's worth of bytes and no more.
    @Test("The figure counts what the decision actually removes")
    func countsWhatTheDecisionRemoves() {
        let three = group(files: ["/r/a", "/r/b", "/r/c"], size: 1000)
        let keepOne = GroupPresentation(
            group: three, keep: [0], decision: .decided(keep: [0]), root: "/r")
        #expect(keepOne.reclaimableBytes == 2000)
        #expect(keepOne.removableCount == 2)

        let keepTwo = GroupPresentation(
            group: three, keep: [0, 2], decision: .decided(keep: [0, 2]), root: "/r")
        #expect(keepTwo.reclaimableBytes == 1000)
        #expect(keepTwo.removableCount == 1)
        #expect(keepTwo.rows.map(\.isRemovable) == [false, true, false])
    }

    /// **A clone of a kept file is not removable, whichever name the cluster lists first.**
    ///
    /// The old code excluded the first keeper's cluster and then filtered the kept paths out of the other
    /// representatives, which is not the same rule: here cluster 1 lists `/r/b2` before `/r/b`, so keeping
    /// `/r/b` still offered `/r/b2` -- the same storage under another name. Removing it frees nothing and
    /// takes away a path the user chose to keep.
    @Test("A clone of a kept file is never offered, whatever the cluster order")
    func neverOffersACloneOfAKeptFile() {
        let partition = StoragePartition(
            clusters: [["/r/a"], ["/r/b2", "/r/b"]], isExact: true)
        let presentation = GroupPresentation(
            group: group(files: ["/r/a", "/r/b", "/r/b2"], size: 1000, storage: partition),
            keep: [0, 1],
            decision: .decided(keep: [0, 1]),
            root: "/r"
        )
        #expect(presentation.rows.allSatisfy { $0.isRemovable == false })
        #expect(presentation.reclaimableBytes == 0)
    }
}
