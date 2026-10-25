import AppKit
import DuplicateCore
import Foundation

// MARK: - ui

extension SelfTest {
    /// The manual pass's eyes, for the part code can see.
    ///
    /// Every window is rendered at the size it opens at, and then at its smallest and at a laptop's if it can be
    /// resized, in the language this process was launched with, over a real tree scanned by the three real
    /// detectors. Each render is swept for text that does not fit, keys that leaked untranslated, panes squeezed to
    /// nothing, controls pushed out of the window, controls drawn over each other and layouts the constraints leave
    /// ambiguous -- and saved as a PNG, for what a sweep cannot judge.
    ///
    /// **Local only.** It is not in `--mode all`, so CI never runs it: it is the check before opening a PR, and
    /// `make ui` runs it once per language.
    ///
    /// **The language is asserted, not assumed.** `make ui` passes `-AppleLanguages (es)` on the command line,
    /// which sets the argument domain of this one process -- unlike `defaults write`, which once changed this
    /// user's whole system. And a run that believes it is in Spanish while drawing English asserts the same thing
    /// twice, which already happened here with three locale identifiers.
    ///
    /// Writes only under `/tmp` and `--output`. **Window frames are neither restored nor autosaved**: this process
    /// runs under the app's own defaults, so a restored frame would render this machine's last size instead of a
    /// first launch's, and shrinking a window to its minimum would open the user's real one at that size.
    ///
    /// Proof of teeth, one break per sweep, each run against the broken version:
    /// - language: drop `-AppleLanguages` from the `ui` target and the run for the language the system does not
    ///   prefer fails on its first line.
    /// - leaked key: misspell `review.warning.preview` at its call site and the review window reports the key.
    /// - cut text: give the scan panel's `rootLabel` `.byClipping` and it reports the path cut at the right.
    /// - squeezed pane: drop the library's `minSize` height to 90 and its table reports 30 points of height.
    /// - overlap: set the scan panel's `optionsStack.spacing` to -14 and every row is reported over the next, at the
    ///   size the panel opens at. With the check off the same run passes: no text is cut and nothing leaves the
    ///   window.
    /// - ambiguous layout: unpin the exact review's header from its pane and every render of the review reports it.
    /// - opening size: rendered first, it found the folder viewer's decision row with an ambiguous width -- shrunk
    ///   from the size it opened at, "Simulate and apply" stayed outside the window. Unpin the row's width to see it.
    /// - the other three were not staged: they caught real defects on their first run. A plural after a count of
    ///   one in four footers, file names cut by the edge of the exact review's list at its smallest size, and the
    ///   folder viewer's detail -- an `NSTextView` holding the pair's differences in zero points of width.
    @MainActor
    static func checkUserInterface(arguments: [String]) async throws {
        let output = try expectSome(
            value(for: "--output", in: arguments), "--output names no directory for the screenshots"
        )
        if let expected = value(for: "--expect-language", in: arguments) {
            let actual = Bundle.main.preferredLocalizations.first ?? "none"
            try expect(
                actual == expected,
                "launched for '\(expected)' and drawing '\(actual)': -AppleLanguages did not reach the process"
            )
        }
        let language = Bundle.main.preferredLocalizations.first ?? "none"

        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        // Only the PNGs this mode writes: a stale render from a window that no longer exists would be reviewed as
        // if it were current.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: output)) ?? []
        where name.hasSuffix(".png") {
            try? FileManager.default.removeItem(atPath: output + "/" + name)
        }

        // A fixed path, not a per-run one: the path is on screen in half the renders, and a random one makes two
        // runs differ where nothing changed, which is the opposite of what a before-and-after is for. And `/tmp`,
        // not the per-user temporary directory, whose name identifies this machine in a capture someone posts.
        let root = "/tmp/duplicate-ui"
        try? FileManager.default.removeItem(atPath: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fixture = try await UIFixture.build(at: root)

        var sweep = UISweep(language: language, output: output)

        let library = LibraryWindowController(stateDirectory: fixture.state, restoresFrame: false)
        defer { library.window?.close() }
        try await waitOnMainActor(
            until: { library.hasFinishedFirstLoad }, what: "the library's first read")
        try expect(
            library.displayedRowCount == 1,
            "the library lists \(library.displayedRowCount) exact scans")
        try await sweep.render(library.window, as: "library-files")
        library.showFolderScansForSelftest()
        try await waitOnMainActor(
            until: { library.folderRowCount == 1 }, what: "the folder scan in the library")
        try await sweep.render(library.window, as: "library-folders")
        library.showSimilarScansForSelftest()
        try await waitOnMainActor(
            until: { library.similarRowCount == 1 }, what: "the perceptual scan in the library")
        try await sweep.render(library.window, as: "library-similar")

        // The first thing a new user sees, and the manual's first picture.
        let emptyState = StateDirectory(
            environment: ["XDG_STATE_HOME": root + "/empty-state"], homePath: root)
        let emptyLibrary = LibraryWindowController(stateDirectory: emptyState, restoresFrame: false)
        defer { emptyLibrary.window?.close() }
        try await waitOnMainActor(
            until: { emptyLibrary.hasFinishedFirstLoad }, what: "the empty library's first read")
        try await sweep.render(emptyLibrary.window, as: "library-empty")

        let panel = ScanPanelController(stateDirectory: fixture.state)
        defer { panel.window?.close() }
        panel.setRootForSelftest(fixture.tree)
        try await sweep.render(panel.window, as: "scan-exact")
        panel.chooseFolderDetectorForSelftest()
        try await sweep.render(panel.window, as: "scan-folders")
        panel.chooseSimilarDetectorForSelftest()
        try await sweep.render(panel.window, as: "scan-similar")

        let review = ReviewWindowController(
            scan: fixture.exact, stateDirectory: fixture.state,
            presenceCacheDirectory: URL(filePath: root + "/presence"), restoresFrame: false)
        defer { review.window?.close() }
        await review.awaitPresenceForSelftest()
        try await sweep.render(review.window, as: "review")

        let folders = FolderPairWindowController(
            scan: fixture.folders, stateDirectory: fixture.state, restoresFrame: false)
        defer { folders.window?.close() }
        folders.selectPairForSelftest(0)
        try await sweep.render(folders.window, as: "folder-pair")

        let similar = SimilarPairWindowController(
            scan: fixture.similar, stateDirectory: fixture.state)
        defer { similar.window?.close() }
        // One render per group, named by its kind: the images are a group of three, the clips a group of two.
        for (row, group) in SimilarGrouping.groups(of: fixture.similar.pairs).enumerated() {
            similar.selectGroupForSelftest(row)
            await similar.awaitFactsForSelftest()
            try await sweep.render(
                similar.window, as: "similar-\(group.mediaKind == .video ? "video" : "image")")
        }

        // **Two sessions, so the history shows rows**: an empty table renders fine and says nothing about the
        // columns. One was put back entirely and one in part, which are the two states a row can describe.
        try writeSessions(into: fixture.state, root: root, scanID: fixture.exact.scanID)
        let history = SessionHistoryWindowController(stateDirectory: fixture.state)
        defer { history.window?.close() }
        try expect(
            history.rowCountForSelftest == 2,
            "the history lists \(history.rowCountForSelftest) of 2")
        try await sweep.render(history.window, as: "history")

        // **The apply sheets, as a dry run shows them** (#180): their lists drew nothing, and no render here had
        // ever opened one. Last, because deciding something to simulate changes the windows above.
        review.confirmGroup(nil)
        review.simulateForSelftest()
        try await sweep.renderAsIs(review.openApplySheet?.window, as: "apply-exact")
        folders.decideForSelftest("keepA", row: 0)
        folders.simulateForSelftest()
        try await sweep.renderAsIs(folders.applySheetForSelftest?.window, as: "apply-folders")
        similar.selectGroupForSelftest(0)
        similar.pressConfirmForSelftest()
        similar.simulateForSelftest()
        try await sweep.renderAsIs(similar.applySheetForSelftest?.window, as: "apply-similar")

        // **And finished**: what someone reads after pressing apply, which no render showed. The real runners, with
        // a disposer that moves into a fake Trash under the fixture -- `CFFIXED_USER_HOME` does not redirect the
        // real one, and a render must not put anything there. The folder pair is refused, because `copia-b` holds a
        // file `copia-a` does not: the containment check doing its job, on screen.
        let fakeTrash = FakeTrashDisposer(directory: root + "/faketrash")
        let finishedAt = ScanIdentifier.Instant(
            year: 2026, month: 10, day: 24, hour: 13, minute: 0, second: 0, microsecond: 0)
        var folderReview = FolderReviewState(scan: fixture.folders)
        folderReview.keep(fixture.folders.pairs[0].folderA)
        let folderReport = try await FolderApplyRunner(
            state: fixture.state, cacheURL: URL(filePath: root + "/f")
        ).run(
            FolderApplyPlan.from(folderReview), sessionID: finishedAt.identifier,
            instant: finishedAt, disposer: fakeTrash)
        try expect(
            folderReport.moved.isEmpty && folderReport.refused.count == 1,
            "the folder apply moved \(folderReport.moved.count) and refused \(folderReport.refused.count)"
        )
        let folderSheet = try expectSome(folders.applySheetForSelftest, "no folder apply sheet")
        folderSheet.finishForSelftest(folderReport)
        try await sweep.renderAsIs(folderSheet.window, as: "apply-folders-done")

        var similarReview = SimilarReviewState(scan: fixture.similar)
        similarReview.confirm(.keepA)
        let similarReport = try await SimilarApplyRunner(state: fixture.state).run(
            SimilarApplyPlan.from(similarReview), sessionID: finishedAt.nextMicrosecond.identifier,
            instant: finishedAt.nextMicrosecond, disposer: fakeTrash)
        try expect(
            similarReport.moved.count == 1,
            "the similar apply moved \(similarReport.moved.count) files, wanted 1")
        let similarSheet = try expectSome(similar.applySheetForSelftest, "no similar apply sheet")
        similarSheet.finishForSelftest(similarReport)
        try await sweep.renderAsIs(similarSheet.window, as: "apply-similar-done")

        print("  \(sweep.renderCount) renders in '\(language)' saved to \(output)")
        for finding in sweep.findings { print("  \(finding)") }
        try expect(
            sweep.findings.isEmpty,
            "\(sweep.findings.count) problems across \(sweep.renderCount) renders, listed above")
    }
}

/// Two journals for the history to list: one session put back entirely, one in part.
///
/// Written straight into the journal rather than by applying, because what the history window shows is what the
/// journal says, and these are the two states a row can be in.
@MainActor
private func writeSessions(into state: StateDirectory, root: String, scanID: String) throws {
    let digest = Digest32(a: 1, b: 2, c: 3, d: 4)
    func entry(_ name: String, at timestamp: String) -> JournalEntry {
        JournalEntry(
            originalPath: root + "/demo/exactos/" + name,
            resultingPath: root + "/faketrash/" + name,
            mechanism: .trash, byteCount: 14, digest: digest, groupKey: "14:" + digest.hexString,
            scanID: scanID, timestamp: timestamp)
    }
    let all = [entry("foto copia.jpg", at: "2026-10-24T12:10:00.000000Z")]
    _ = try MoveJournal.append(all, sessionID: "20261024-121000-000000", in: state)
    for moved in all {
        _ = try MoveJournal.appendRestoration(
            of: moved, at: "2026-10-24T12:15:00.000000Z", sessionID: "20261024-121000-000000",
            in: state)
    }
    let some = ["a.txt", "b.txt", "c.txt"].map { entry($0, at: "2026-10-24T12:20:00.000000Z") }
    _ = try MoveJournal.append(some, sessionID: "20261024-122000-000000", in: state)
    _ = try MoveJournal.appendRestoration(
        of: some[0], at: "2026-10-24T12:25:00.000000Z", sessionID: "20261024-122000-000000",
        in: state)
}

/// Moves into a directory and reports it as the Trash, so a render of a finished apply reads like one.
private struct FakeTrashDisposer: ItemDisposing {
    let directory: String

    func dispose(path: String) throws -> DisposalOutcome {
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        let destination = directory + "/" + (path as NSString).lastPathComponent
        let size =
            (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            ?? 0
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return DisposalOutcome(
            originalPath: path, resultingPath: destination, mechanism: .trash, byteCount: size)
    }
}

/// A small tree with known answers for each detector, scanned for real into a throwaway state directory.
///
/// The same shapes `scripts/make-demo-tree.py` builds for the manual pass, written from Swift so the mode needs
/// neither Python nor ffmpeg.
@MainActor
private struct UIFixture {
    let tree: String
    let state: StateDirectory
    let exact: DuplicateScan
    let folders: FolderScan
    let similar: SimilarScan

    static func build(at root: String) async throws -> UIFixture {
        let tree = root + "/demo"
        func make(_ relative: String, _ contents: String) throws {
            let path = tree + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: URL(filePath: path))
        }

        // Long names on purpose: the middle of the name is what has to give way in a narrow window.
        let report = String(repeating: "informe trimestral de ventas 2026 ", count: 2)
        try make("exactos/\(report)final.pdf", "report contents")
        try make("exactos/respaldo/\(report)final copia.pdf", "report contents")
        try make("exactos/foto.jpg", "photo contents")
        try make("exactos/foto copia.jpg", "photo contents")

        // Five files in common and one only in the second: 2*5/11 = 90.9%.
        for index in 1...5 {
            for folder in ["copia-a", "copia-b"] {
                try make("\(folder)/nota-\(index).txt", "note \(index)")
            }
        }
        try make("copia-b/solo-aqui.txt", "only here")

        let media = tree + "/parecidas"
        try FileManager.default.createDirectory(atPath: media, withIntermediateDirectories: true)
        try SyntheticImage.write(
            .rampWithCorner, width: 320, height: 240, format: .png, to: media + "/foto.png")
        try SyntheticImage.write(
            .rampWithCorner, width: 320, height: 240, format: .jpeg(quality: 0.6),
            to: media + "/foto chica.jpg")
        // A third copy, so the perceptual review shows a group rather than a pair (#217).
        try SyntheticImage.write(
            .rampWithCorner, width: 320, height: 240, format: .jpeg(quality: 0.85),
            to: media + "/foto mediana.jpg")
        let clip = SyntheticMovie.Specification(seconds: 6, pattern: .movingBlock)
        try await SyntheticMovie.write(clip, to: media + "/clip.mp4")
        try await SyntheticMovie.write(clip, to: media + "/clip recodificado.mp4")

        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)
        let trash = FixedTrashRootResolver([root + "/faketrash"])
        let instant = ScanIdentifier.Instant(
            year: 2026, month: 10, day: 24, hour: 12, minute: 0, second: 0, microsecond: 0)

        let exact = try await ScanSession(
            store: store, trashResolver: trash, cacheURL: URL(filePath: root + "/h")
        )
        .run(ScanSession.Request(root: tree), instant: instant)
        let folders = try await FolderScanSession(
            store: store, trashResolver: trash, cacheURL: URL(filePath: root + "/f")
        )
        .run(
            FolderScanSession.Request(root: tree, threshold: 0.9), instant: instant.nextMicrosecond)
        let similar = try await SimilarScanSession(
            store: store, trashResolver: trash, cacheURL: URL(filePath: root + "/p")
        )
        .run(
            SimilarScanSession.Request(root: tree), instant: instant.nextMicrosecond.nextMicrosecond
        )

        // An empty window renders fine and proves nothing, so the fixture has to have produced what it promises.
        try SelfTest.expect(exact.saveFailure == nil, "the exact scan could not be saved")
        try SelfTest.expect(folders.saveFailure == nil, "the folder scan could not be saved")
        try SelfTest.expect(similar.saveFailure == nil, "the perceptual scan could not be saved")
        try SelfTest.expect(exact.scan.groups.count >= 2, "\(exact.scan.groups.count) exact groups")
        try SelfTest.expect(
            folders.scan.pairs.count == 1, "\(folders.scan.pairs.count) folder pairs, wanted 1")
        try SelfTest.expect(
            similar.scan.pairCount(of: .image) == 3 && similar.scan.pairCount(of: .video) == 1,
            "the perceptual scan found \(similar.scan.pairs.count) pairs, wanted three image and one video"
        )

        return UIFixture(
            tree: tree, state: state, exact: exact.scan, folders: folders.scan,
            similar: similar.scan)
    }
}

/// Renders windows and collects what is wrong with them, without stopping at the first one: a run that names
/// three cut labels at once is one fix, three runs is three.
@MainActor
private struct UISweep {
    let language: String
    let output: String
    private(set) var findings: [String] = []
    private(set) var renderCount = 0

    /// Every key of every table, so a key on screen is caught whichever table it was missing from.
    private let keys: [String] = {
        var all = Set<String>()
        for localization in ["en", "es"] {
            if let table = Strings.table(localization: localization) { all.formUnion(table.keys) }
            if let plurals = Strings.plurals(localization: localization) {
                all.formUnion(plurals.keys)
            }
        }
        // Only dotted ones: a key like `ok` would match ordinary words.
        return all.filter { $0.contains(".") }.sorted()
    }()

    init(language: String, output: String) {
        self.language = language
        self.output = output
    }

    /// After the size a window opens at, two more: the smallest it allows, which is where text runs out of room,
    /// and a 13-inch laptop's, which is how most people first see it.
    private static let laptop = NSSize(width: 1280, height: 800)

    /// The size each window had the first time it came here, before any render resized it.
    private var openingSizes: [ObjectIdentifier: NSSize] = [:]

    /// A window with a size of its own -- a sheet -- rendered once, as it is.
    mutating func renderAsIs(_ window: NSWindow?, as name: String) async throws {
        let window = try SelfTest.expectSome(window, "\(name) has no window")
        try? await Task.sleep(for: .milliseconds(300))
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let frameView = content.superview ?? content
        frameView.displayIfNeeded()
        let place = "\(name) @ \(Int(window.frame.width))x\(Int(window.frame.height))"
        inspect(frameView, content: content, window: window, place: place)
        inspectOverlaps(in: content, place: place)
        try save(frameView, as: name)
        renderCount += 1
    }

    mutating func render(_ window: NSWindow?, as name: String) async throws {
        let window = try SelfTest.expectSome(window, "\(name) has no window")
        // Before any resize: the autosaved frame is the user's, and a resize here would be written back to it.
        window.setFrameAutosaveName("")
        // **The size it opens at is the first one anyone sees** (#211), and a window that cannot be resized has no
        // other: the scan panel rendered at a laptop's showed a gap between its rows that nobody can ever see. Going
        // first also means the other two are reached from a window already laid out, as they are by anyone who
        // resizes one -- which is how the folder viewer's decision row turned out to have no width of its own.
        // The window lays itself out before its size is taken: it grows to fit its content, as it does on screen.
        window.layoutIfNeeded()
        let opening = openingSizes[ObjectIdentifier(window)] ?? window.frame.size
        openingSizes[ObjectIdentifier(window)] = opening
        let sizes =
            window.styleMask.contains(.resizable)
            ? [("open", opening), ("min", window.minSize), ("laptop", Self.laptop)]
            : [("open", opening)]
        for (label, size) in sizes {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            // Thumbnails and the probes behind them arrive a beat after the layout.
            try? await Task.sleep(for: .milliseconds(300))
            guard let content = window.contentView else { continue }
            content.layoutSubtreeIfNeeded()
            let frameView = content.superview ?? content
            frameView.layoutSubtreeIfNeeded()
            frameView.displayIfNeeded()

            let place = "\(name) @ \(label) \(Int(window.frame.width))x\(Int(window.frame.height))"
            inspect(frameView, content: content, window: window, place: place)
            inspectOverlaps(in: content, place: place)
            if let problem = Self.unformatted(window.title) ?? leakedKey(in: window.title) {
                findings.append("\(place): window title \(problem)")
            }
            try save(frameView, as: "\(name)-\(label)")
            renderCount += 1
        }
    }

    private mutating func inspect(_ view: NSView, content: NSView, window: NSWindow, place: String)
    {
        guard !view.isHidden else { return }
        // Before the visibility guard, because this is the case it would skip: a text view with something to say
        // and no width draws nothing, while every check that reads its `string` passes.
        if let text = view as? NSTextView, !text.string.isEmpty, text.frame.width < 20 {
            findings.append(
                "\(place): an NSTextView holds \(text.string.count) characters in "
                    + "\(Int(text.frame.width)) points of width, so it draws nothing")
        }
        guard !view.visibleRect.isEmpty else { return }
        let what = Self.describe(view)

        for text in Self.texts(of: view) {
            if let problem = Self.unformatted(text) ?? leakedKey(in: text)
                ?? Self.pluralAfterOne(text)
            {
                findings.append("\(place): \(what) \(problem)")
            }
        }
        if let cut = Self.clipping(of: view) {
            findings.append("\(place): \(what) is cut \(cut)")
        }
        // **Ambiguous: more than one layout satisfies the constraints** (#214), so what is drawn depends on what was
        // drawn before -- a row that kept its last width, a gap that landed between a checkbox and its explanation.
        // The views TextKit puts inside a text view are AppKit's, and theirs to settle.
        if view.hasAmbiguousLayout, !(view.superview is NSTextView) {
            findings.append("\(place): \(what) has an ambiguous layout")
        }
        // Cut by the edge of its list: a cell wider than what its scroll view shows loses its end with no ellipsis,
        // because the cell truncates to its own width and not to the part of it on screen.
        if let field = view as? NSTextField, field.enclosingScrollView != nil,
            !field.stringValue.isEmpty,
            let cell = field.cell
        {
            let drawn = min(cell.cellSize.width, field.bounds.width)
            let shown = field.visibleRect.width
            if shown + 1 < drawn {
                findings.append(
                    "\(place): \(what) is cut by the edge of its list, \(Int(shown)) of \(Int(drawn)) points shown"
                )
            }
        }
        if view is NSScrollView, view.bounds.width < 60 || view.bounds.height < 40 {
            findings.append(
                "\(place): \(what) is squeezed to \(Int(view.bounds.width))x\(Int(view.bounds.height))"
            )
        }
        // Pushed out: a control that sits past the window's edge is one the user cannot reach. Content inside a
        // scroll view is allowed to extend, which is what scrolling is for.
        // The alignment rect, not the frame: a text field's frame carries padding past the text it draws.
        if view is NSControl, view.isDescendant(of: content), view.enclosingScrollView == nil,
            let parent = view.superview
        {
            let rect = parent.convert(view.alignmentRect(forFrame: view.frame), to: content)
            if !content.bounds.insetBy(dx: -1, dy: -1).contains(rect) {
                findings.append(
                    "\(place): \(what) falls outside the window, at \(Self.describe(rect))")
            }
        }

        if let table = view as? NSTableView {
            for problem in Self.misalignedColumns(in: table) {
                findings.append("\(place): \(problem)")
            }
        }

        for subview in view.subviews {
            inspect(subview, content: content, window: window, place: place)
        }
    }

    /// Controls drawn over each other (#211): one row laid on top of the next cuts no text and leaves nothing outside
    /// the window, so every other check passes. Compared across the whole window, not between siblings, because two
    /// rows of a stack are cousins. Lists are left out, since what a table lays out and scrolls is the table's
    /// business, and so are a control's own subviews: a button's title is a text field inside it.
    private mutating func inspectOverlaps(in content: NSView, place: String) {
        var controls: [(view: NSView, rect: NSRect)] = []
        func collect(_ view: NSView) {
            guard !view.isHidden, !(view is NSScrollView) else { return }
            guard view is NSControl else {
                view.subviews.forEach(collect)
                return
            }
            // The alignment rect, as for "pushed out", and one point in from it: two controls that touch are laid
            // out edge to edge, not over each other.
            if !view.visibleRect.isEmpty, let parent = view.superview {
                let rect = parent.convert(view.alignmentRect(forFrame: view.frame), to: content)
                    .insetBy(dx: 1, dy: 1)
                if !rect.isEmpty { controls.append((view, rect)) }
            }
        }
        collect(content)
        for (index, first) in controls.enumerated() {
            for second in controls[(index + 1)...] {
                let shared = first.rect.intersection(second.rect)
                guard !shared.isEmpty else { continue }
                findings.append(
                    "\(place): \(Self.describe(first.view)) and \(Self.describe(second.view)) overlap by "
                        + "\(Int(shared.width.rounded(.up)))x\(Int(shared.height.rounded(.up))) points"
                )
            }
        }
    }

    private func save(_ view: NSView, as name: String) throws {
        let path = "\(output)/\(name).png"
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SelfTestFailure("\(name): no bitmap to render into")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try SelfTest.expectSome(
            bitmap.representation(using: .png, properties: [:]),
            "\(name): the render did not encode")
        try png.write(to: URL(filePath: path))
    }

    private func leakedKey(in text: String) -> String? {
        keys.first { text.contains($0) }.map { "shows the raw key '\($0)'" }
    }

    /// Columns whose cells line up differently from their header: a count sitting on the left under a
    /// right-aligned header reads as belonging to the column beside it.
    private static func misalignedColumns(in table: NSTableView) -> [String] {
        func side(_ alignment: NSTextAlignment) -> NSTextAlignment {
            alignment == .natural || alignment == .justified ? .left : alignment
        }
        return table.tableColumns.enumerated().compactMap { index, column in
            guard !column.isHidden, table.numberOfRows > 0,
                let field =
                    (table.view(atColumn: index, row: 0, makeIfNecessary: false) as? NSTableCellView)?
                    .textField,
                side(field.alignment) != side(column.headerCell.alignment)
            else { return nil }
            return
                "column '\(column.headerCell.stringValue)' aligns its header and its cells differently"
        }
    }

    /// A count of one with a plural after it: "1 pares", "1 scans". The singular is a different string, and a call
    /// site that formats every count into the plural one never asks for it.
    private static func pluralAfterOne(_ text: String) -> String? {
        let pattern = #"(?:^|[^0-9.,])1 (\p{Ll}{2,}s)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        let word = String(text[range])
        // Singular words that end in s.
        guard !["mes", "análisis", "lunes", "martes", "jueves", "viernes"].contains(word) else {
            return nil
        }
        return "says '1 \(word)', a plural after a count of one"
    }

    /// A format the code never filled in: `%@` on screen is a missing `String(format:)`.
    private static func unformatted(_ text: String) -> String? {
        ["%@", "%d", "%ld", "%lld", "%1$", "%2$"].first { text.contains($0) }.map {
            "shows '\($0)' unformatted"
        }
    }

    /// The strings a view puts in front of the user, tooltips included: a key in a tooltip is still a key.
    private static func texts(of view: NSView) -> [String] {
        var texts: [String] = []
        switch view {
        case let field as NSTextField:
            texts.append(field.stringValue)
            if let placeholder = field.placeholderString { texts.append(placeholder) }
        case let popup as NSPopUpButton:
            texts += popup.itemTitles
        case let button as NSButton:
            texts += [button.title, button.alternateTitle]
        case let segmented as NSSegmentedControl:
            texts += (0..<segmented.segmentCount).compactMap { segmented.label(forSegment: $0) }
        case let table as NSTableView:
            texts += table.tableColumns.map(\.headerCell.stringValue)
        default:
            break
        }
        if let tip = view.toolTip { texts.append(tip) }
        return texts.filter { !$0.isEmpty }
    }

    /// Text that needs more room than it has and has no ellipsis to say so. A truncating label is not cut: the
    /// ellipsis is the design, and the middle truncation of a path is what keeps both of its ends visible.
    private static func clipping(of view: NSView) -> String? {
        let bounds = view.bounds
        switch view {
        case let field as NSTextField:
            guard let cell = field.cell, !field.stringValue.isEmpty, !field.isEditable else {
                return nil
            }
            let truncating: Set<NSLineBreakMode> = [
                .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail,
            ]
            guard !truncating.contains(cell.lineBreakMode), !cell.truncatesLastVisibleLine else {
                return nil
            }
            if cell.wraps {
                let needed = cell.cellSize(
                    forBounds: NSRect(
                        x: 0, y: 0, width: bounds.width, height: .greatestFiniteMagnitude)
                ).height
                return needed > bounds.height + 1
                    ? "at the bottom: needs \(Int(needed.rounded(.up))) points of height, has \(Int(bounds.height))"
                    : nil
            }
            let needed = cell.cellSize.width
            return needed > bounds.width + 1
                ? "at the right: needs \(Int(needed.rounded(.up))) points, has \(Int(bounds.width))"
                : nil
        case is NSPopUpButton:
            // A pop-up truncates its own title with an ellipsis.
            return nil
        case let button as NSButton:
            guard !button.title.isEmpty, let cell = button.cell else { return nil }
            let needed = cell.cellSize.width
            return needed > bounds.width + 1
                ? "at the right: needs \(Int(needed.rounded(.up))) points, has \(Int(bounds.width))"
                : nil
        case let segmented as NSSegmentedControl:
            let needed = segmented.intrinsicContentSize.width
            return needed > bounds.width + 1
                ? "at the right: needs \(Int(needed.rounded(.up))) points, has \(Int(bounds.width))"
                : nil
        default:
            return nil
        }
    }

    /// Names a view by what it says, which is what someone reading a finding can find on screen.
    private static func describe(_ view: NSView) -> String {
        let kind = String(describing: type(of: view))
        let text: String? =
            switch view {
            case let field as NSTextField:
                field.stringValue.isEmpty ? field.placeholderString : field.stringValue
            case let button as NSButton: button.title
            default: nil
            }
        guard let text, !text.isEmpty else { return kind }
        let short = text.count > 50 ? String(text.prefix(47)) + "..." : text
        return "\(kind) '\(short)'"
    }

    private static func describe(_ rect: NSRect) -> String {
        "x \(Int(rect.minX))...\(Int(rect.maxX)), y \(Int(rect.minY))...\(Int(rect.maxY))"
    }
}
