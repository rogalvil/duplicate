import AppKit
import DuplicateCore
@preconcurrency import Quartz

/// Shows the pairs of one perceptual scan, side by side.
///
/// **Two thumbnails, not a list of paths, because that is the only way to judge this detector.** An exact
/// duplicate can be decided from its digest; a perceptual pair cannot. The app is claiming two files *look*
/// alike, and the user is the only one who can say whether that is true -- so the two pictures have to be on
/// screen next to each other, at the same size.
///
/// **It decides, and it does not delete.** A pair at distance 5 can be two genuinely different photographs -- a
/// burst of the same scene, two frames of one video, the same product on two backgrounds -- so the four choices
/// here are recorded in `similar-decisions` and nothing is moved. Applying them is its own change, with the same
/// dry-run gate, journal and re-hash-before-moving the exact detector has.
///
/// **The suggestion is shown selected and is never saved on its own.** The CLI fills a default decision for every
/// pair before anyone has seen one; here the highlight is a proposal and the file only carries what was
/// confirmed.
///
/// It shows video pairs too, even though this build cannot produce them: a scan written by `rav duplicate
/// similar` carries them, and refusing to display what the document holds would be its own kind of lie.
@MainActor
final class SimilarPairWindowController: NSWindowController, NSWindowDelegate {

    private let scan: SimilarScan
    private let allPairs: [SimilarPair]
    /// The indices currently on screen, in scan order. **Narrowing decides nothing** -- this is the only thing a
    /// filter changes.
    private var visible: [Int] = []
    private var filter = PairFilter()
    private let similarityPopup = NSPopUpButton()
    private let kindPopup = NSPopUpButton()
    private let undecidedToggle = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let confirmShownButton = NSButton()
    private let stateDirectory: StateDirectory
    private var review: SimilarReviewState
    /// Facts already probed, by path. Filled for the pair being looked at, never for all of them.
    private var facts: [String: MediaFacts] = [:]
    private var probeGeneration = 0
    private let probe = MediaProbe()
    private let table = NSTableView()
    private let thumbnailer = QuickLookThumbnailer()
    private let leftPane = SimilarSidePane()
    private let quickLook = QuickLookCoordinator()
    private let rightPane = SimilarSidePane()
    private let headerLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let adviceLabel = NSTextField(labelWithString: "")
    private let tallyLabel = NSTextField(labelWithString: "")
    private var decisionButtons: [SimilarDecision: NSButton] = [:]
    private let skipButton = NSButton()
    private let applyButton = NSButton()
    private var flow = ReviewFlow()
    private var applySheet: SimilarApplySheetController?
    private var savedCount = 0
    private var saveFailure: String?
    private let undo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()

    init(scan: SimilarScan, stateDirectory: StateDirectory = StateDirectory.current()) {
        self.scan = scan
        self.allPairs = scan.pairs
        self.stateDirectory = stateDirectory
        // Rehydrated from disk, so reopening a scan shows what was already decided -- including a document the
        // CLI wrote, which decides every pair.
        self.review = SimilarReviewState(
            scan: scan,
            priorDecisions: ScanStore(state: stateDirectory)
                .priorSimilarDecisions(scanID: scan.scanID)
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: Strings.string("similar.window.title"), scan.scanID)
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        window.delegate = self
        build()
        refreshDetail()
        rebuildVisible()
        if !visible.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// **Where ⌘Z arrives.** AppKit asks the window's delegate for the undo manager, and without this the Edit
    /// menu's `undo:` reaches nothing and the menu item is disabled -- a review with a perfectly working undo that
    /// is invisible, which is worse than not having one.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func build() {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(revealSelected(_:))

        for (identifier, key, width) in [
            ("similarity", "similar.column.similarity", 74.0),
            ("kind", "similar.column.kind", 70.0),
            ("decision", "similar.column.decision", 120.0),
            ("a", "similar.column.a", 260.0),
            ("b", "similar.column.b", 260.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = Strings.string(key)
            column.width = width
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // A table reports the sum of its columns as its intrinsic width, and through a scroll view that
        // becomes a floor on the window. A scroll view exists to be narrower than its content.
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for label in [headerLabel, footerLabel, adviceLabel, tallyLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingMiddle
        }
        footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        adviceLabel.font = .systemFont(ofSize: 11)
        adviceLabel.textColor = .secondaryLabelColor
        adviceLabel.maximumNumberOfLines = 2
        tallyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tallyLabel.textColor = .secondaryLabelColor

        // The four decisions, in the order a person reads them, plus skip.
        let decisionRow = NSStackView()
        decisionRow.orientation = .horizontal
        decisionRow.spacing = 8
        decisionRow.translatesAutoresizingMaskIntoConstraints = false
        for decision in [
            SimilarDecision.keepA, .keepB, .keepBoth, .keepNone,
        ] {
            let button = NSButton()
            button.title = SimilarAdviceText.label(for: decision)
            button.bezelStyle = .rounded
            button.setButtonType(.pushOnPushOff)
            button.target = self
            button.action = #selector(decisionChosen(_:))
            button.tag =
                [SimilarDecision.keepA, .keepB, .keepBoth, .keepNone]
                .firstIndex(of: decision) ?? 0
            // **"Discard both" is the dangerous one and it looks like it.** It is the only choice here that can
            // remove two files at once, and the CLI's own corpus used it exactly once in 943 decisions.
            if decision == .keepNone { button.contentTintColor = .systemRed }
            decisionButtons[decision] = button
            decisionRow.addView(button, in: .leading)
        }
        skipButton.title = Strings.string("similar.decision.skip")
        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipPair(_:))
        decisionRow.addView(skipButton, in: .leading)

        similarityPopup.target = self
        similarityPopup.action = #selector(filterChanged(_:))
        for value in PairFilter.similarityChoices {
            let title: String
            if value == 0 {
                title = Strings.string("similar.filter.similarity.any")
            } else if value == 1.0 {
                title = Strings.string("similar.filter.identical")
            } else {
                title = String(
                    format: Strings.string("similar.filter.similarity.value"), Int(value * 100))
            }
            similarityPopup.addItem(withTitle: title)
            similarityPopup.lastItem?.representedObject = value
        }
        similarityPopup.selectItem(at: 0)

        kindPopup.target = self
        kindPopup.action = #selector(filterChanged(_:))
        for (key, kind) in [
            ("similar.filter.kind.any", nil), ("similar.filter.kind.image", MediaKind.image),
            ("similar.filter.kind.video", MediaKind.video),
        ] as [(String, MediaKind?)] {
            kindPopup.addItem(withTitle: Strings.string(key))
            kindPopup.lastItem?.representedObject = kind?.rawValue
        }
        kindPopup.selectItem(at: 0)

        undecidedToggle.setButtonType(.switch)
        undecidedToggle.title = Strings.string("similar.filter.undecided")
        undecidedToggle.target = self
        undecidedToggle.action = #selector(filterChanged(_:))

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        confirmShownButton.bezelStyle = .rounded
        confirmShownButton.target = self
        confirmShownButton.action = #selector(confirmShown(_:))

        let filterRow = NSStackView(views: [
            NSTextField(labelWithString: Strings.string("similar.filter.similarity")),
            similarityPopup, kindPopup, undecidedToggle, countLabel,
        ])
        filterRow.orientation = .horizontal
        filterRow.spacing = 8
        filterRow.translatesAutoresizingMaskIntoConstraints = false
        filterRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // **A button, not only a menu item.** The last time an action of this app lived behind a keyboard
        // shortcut alone, nothing on screen said a review could be applied at all.
        applyButton.title = Strings.string("similar.review.apply")
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(simulateAndApply(_:))
        decisionRow.addView(applyButton, in: .trailing)

        let panes = NSStackView(views: [leftPane, rightPane])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 12
        panes.translatesAutoresizingMaskIntoConstraints = false

        decisionRow.addView(confirmShownButton, in: .trailing)

        let content = NSStackView(views: [
            filterRow, scroll, headerLabel, panes, adviceLabel, decisionRow, tallyLabel,
            footerLabel,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            filterRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            filterRow.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            // **A cap, not a minimum.** Without it the table takes every extra point of height and the two
            // pictures stay at their 220-point floor -- which is what shipped: a full-width window with a
            // thumbnail the size of a postage stamp under it. The comparison is the reason this window
            // exists, so the list is the part that gets bounded.
            scroll.heightAnchor.constraint(
                lessThanOrEqualTo: container.heightAnchor, multiplier: 0.42),
            panes.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            panes.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            panes.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        window?.contentView = container
    }

    /// The pairs on screen, in scan order. Every row index in this window is an index into this.
    private var pairs: [SimilarPair] { visible.map { allPairs[$0] } }

    /// The scan index behind a row, because a decision belongs to the pair and not to the row.
    private func scanIndex(forRow row: Int) -> Int? {
        visible.indices.contains(row) ? visible[row] : nil
    }

    private func rebuildVisible() {
        let selected = scanIndex(forRow: table.selectedRow)
        visible = filter.matchingIndices(in: allPairs) { review.decision(at: $0) }
        table.reloadData()
        countLabel.stringValue = String(
            format: Strings.string("similar.filter.count"), visible.count, allPairs.count)
        confirmShownButton.title = String(
            format: Strings.string("similar.confirmShown"), visible.count)
        confirmShownButton.isEnabled = !visible.isEmpty
        // The selection follows the pair, not the row: a filter that removes rows above it would otherwise move
        // the selection to a different pair without saying so.
        if let selected, let row = visible.firstIndex(of: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else if !visible.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        refreshDetail()
    }

    private var selectedRow: Int {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return row
    }

    private var selectedPair: SimilarPair? {
        pairs.indices.contains(selectedRow) ? pairs[selectedRow] : nil
    }

    private func refreshDetail() {
        footerLabel.stringValue = footerString()
        guard let pair = selectedPair else {
            headerLabel.stringValue = Strings.string("similar.empty")
            leftPane.showEmpty()
            rightPane.showEmpty()
            return
        }
        // Two decimals, for the same reason as folders: 0.95 and 0.9473 are different answers and rounding
        // both to 95% hides one of them.
        //
        // **And the second number is not the same quantity for the two kinds.** An image similarity is
        // `1 - hamming/64`, so bits are the honest unit. A video similarity is the *fraction of sampled frames
        // that matched* -- there is no 64-bit distance behind it, and printing "0 of 64 bits differ" under a
        // video pair, which is what shipped a moment ago, states a measurement that was never taken.
        headerLabel.stringValue = similarHeaderText(
            pair: pair, durationA: facts[pair.fileA]?.duration,
            durationB: facts[pair.fileB]?.duration)
        leftPane.show(path: pair.fileA, thumbnailer: thumbnailer)
        rightPane.show(path: pair.fileB, thumbnailer: thumbnailer)
        // **Everything below is keyed on the scan index, not the row.** A filter makes those different numbers,
        // and a decision belongs to the pair.
        guard let index = scanIndex(forRow: selectedRow) else { return }
        refreshAdvice(row: index, pair: pair)
        refreshDecisionButtons(row: index)
        probeFactsIfNeeded(row: index, pair: pair)
    }

    /// The suggestion and its reason, or the decision already made.
    private func refreshAdvice(row: Int, pair: SimilarPair) {
        let effective = review.effectiveDecision(at: row)
        switch review.decision(at: row) {
        case .decided:
            adviceLabel.stringValue = SimilarAdviceText.label(for: effective)
        case .skipped:
            adviceLabel.stringValue = Strings.string("similar.state.skipped")
        case .undecided:
            let why = review.suggestion(at: row).map {
                SimilarAdviceText.explanation(for: $0.ground)
            }
            let label = SimilarAdviceText.label(for: effective)
            adviceLabel.stringValue = String(
                format: Strings.string("similar.suggested"),
                why.map { "\(label) - \($0)" } ?? label)
        }
        let tally = review.tally
        tallyLabel.stringValue = String(
            format: Strings.string("similar.tally"), tally.decided, tally.skipped, tally.undecided)
    }

    /// The button of the effective decision is pushed in, so the suggestion is visible as a selection.
    private func refreshDecisionButtons(row: Int) {
        let effective = review.effectiveDecision(at: row)
        let isDecided = review.decision(at: row).decision != nil
        for (decision, button) in decisionButtons {
            // Only a real decision shows as pressed. A suggestion is drawn as the *default* -- keyboard focus --
            // rather than as something already chosen, or the two would look identical and the file would be the
            // only place that knew the difference.
            button.state = isDecided && decision == effective ? .on : .off
            button.keyEquivalent = !isDecided && decision == effective ? "\r" : ""
        }
    }

    /// Probes the two files of the pair being looked at, then refines its suggestion.
    ///
    /// **Lazily and cancellably.** Probing all 2,460 files of a real scan up front would repeat a large part of
    /// the scan; the generation counter drops a probe that lands after the selection moved on.
    private func probeFactsIfNeeded(row: Int, pair: SimilarPair) {
        guard facts[pair.fileA] == nil || facts[pair.fileB] == nil else { return }
        probeGeneration += 1
        let generation = probeGeneration
        let kind = pair.mediaKind
        let probe = self.probe
        let paths = (pair.fileA, pair.fileB)
        Task { @MainActor [weak self] in
            let a: MediaFacts?
            let b: MediaFacts?
            switch kind {
            case .image:
                a = probe.facts(ofImage: paths.0)
                b = probe.facts(ofImage: paths.1)
            case .video:
                a = await probe.facts(ofVideo: paths.0)
                b = await probe.facts(ofVideo: paths.1)
            }
            guard let self, generation == self.probeGeneration else { return }
            if let a { self.facts[paths.0] = a }
            if let b { self.facts[paths.1] = b }
            self.review.updateSuggestion(at: row, factsA: a, factsB: b)
            guard self.selectedRow == row else { return }
            self.refreshAdvice(row: row, pair: pair)
            self.refreshDecisionButtons(row: row)
            // The panes and the header both said something narrower before the probe answered: the panes had no
            // resolution and a video header could not say how many frames its verdict rested on.
            self.leftPane.show(facts: a)
            self.rightPane.show(facts: b)
            self.headerLabel.stringValue = similarHeaderText(
                pair: pair, durationA: a?.duration, durationB: b?.duration)
        }
    }

    /// Warns when one file is kept by one pair and discarded by another, or when a saved key cannot be parsed.
    ///
    /// **Shown on close rather than on every click**: the conflict only matters when the set of decisions is done
    /// with, and a sheet after each choice would make deciding impossible.
    func presentContradictionsIfNeeded() {
        presentAmbiguousKeysIfNeeded()
        let conflicting = review.contradictions
        guard let first = conflicting.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("similar.contradiction.title")
        alert.informativeText = String(
            format: Strings.string("similar.contradiction.body"),
            conflicting.count, (first as NSString).lastPathComponent)
        alert.addButton(withTitle: Strings.string("button.close"))
        alert.runModal()
    }

    /// Warns when a decision was saved under a key that cannot be split back apart.
    ///
    /// **The hole in the CLI's key format, said out loud on the one occasion it can still be fixed.** A decision
    /// is stored against `"a||b"` with no escaping, so a path containing `||` yields a key that parses into a
    /// different pair -- and what a wrong pair costs is the wrong file deleted. Measured, no path in this user's
    /// corpus has it; that is the argument for warning rather than for trusting, because the day one appears
    /// nothing else in either tool would notice.
    private func presentAmbiguousKeysIfNeeded() {
        let ambiguous = review.ambiguousKeys
        guard let first = ambiguous.first else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("similar.ambiguousKey.title")
        alert.informativeText = String(
            format: Strings.string("similar.ambiguousKey.body"), ambiguous.count, first)
        alert.addButton(withTitle: Strings.string("button.close"))
        alert.runModal()
    }

    /// The counts, split by kind, and the two thresholds.
    ///
    /// **Split because this build only produces one of the two.** A scan it wrote has no video pairs at all, so
    /// a single total would read as "there is no video here" when it means "this app did not look".
    private func footerString() -> String {
        var text = String(
            format: Strings.string("similar.footer"),
            scan.pairCount(of: .image), scan.imageThreshold,
            scan.pairCount(of: .video), Int(scan.videoThreshold * 100)
        )
        if let saveFailure { return text + "  -  " + saveFailure }
        if savedCount > 0 { text += "  -  " + Strings.string("similar.saved") }
        return text
    }

    private static let decisionOrder: [SimilarDecision] = [.keepA, .keepB, .keepBoth, .keepNone]

    /// The size on disk, or zero when it cannot be read.
    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    @objc private func filterChanged(_ sender: Any?) {
        filter = PairFilter(
            minimumSimilarity: (similarityPopup.selectedItem?.representedObject as? Double) ?? 0,
            kind: (kindPopup.selectedItem?.representedObject as? String).flatMap(
                MediaKind.init(rawValue:)),
            onlyUndecided: undecidedToggle.state == .on
        )
        rebuildVisible()
    }

    /// Accepts the suggestion for every pair currently shown.
    ///
    /// **The sheet names what it will cost before it happens**, and the counts come from the review rather than
    /// from the filter: the files that would move, and any that another decision keeps. Nothing moves here -- this
    /// writes decisions, and applying is still its own step behind its own gate.
    ///
    /// **Only the shown pairs.** That is the invariant that keeps this from becoming the "decide everything"
    /// button the CLI has: every index handed to `confirmAll` is one this window put on screen.
    @objc private func confirmShown(_ sender: Any?) {
        let indices = visible
        guard !indices.isEmpty, let window else { return }

        // What accepting would plan, computed on a copy so the question can be asked before the answer is taken.
        var preview = review
        preview.confirmAll(indices)
        let plan = SimilarApplyPlan.from(preview)
        // **A `stat` per file, and that is the cost of saying the number.** On a batch of 2,106 it is 2,106 calls;
        // the alternative is a sheet that says "some files" and asks for a destructive decision anyway.
        let bytes = plan.items.reduce(Int64(0)) { total, item in
            total + Self.fileSize(item.path)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: Strings.string("similar.confirmShown.title"), indices.count)
        var body = String(
            format: Strings.string("similar.confirmShown.body"),
            plan.items.count, ByteSize.format(bytes))
        if !plan.contradicted.isEmpty {
            body += String(
                format: Strings.string("similar.confirmShown.contradictions"),
                plan.contradicted.count)
        }
        alert.informativeText = body
        alert.addButton(withTitle: Strings.string("button.accept"))
        alert.addButton(withTitle: Strings.string("button.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MainActor.assumeIsolated {
                // One undo step for the whole batch: accepting 2,106 pairs and undoing them one at a time would
                // not be an undo.
                self.mutate { $0.confirmAll(indices) }
            }
        }
    }

    @objc private func decisionChosen(_ sender: Any?) {
        guard let button = sender as? NSButton,
            SimilarPairWindowController.decisionOrder.indices.contains(button.tag),
            pairs.indices.contains(selectedRow)
        else { return }
        let decision = SimilarPairWindowController.decisionOrder[button.tag]
        guard let index = scanIndex(forRow: selectedRow) else { return }
        review.go(to: index)
        review.confirm(decision)
        // Saved as it goes, for the same reason the exact review does: a decision the user made and an app that
        // forgot it are indistinguishable from the outside.
        saveDecisions()
        // **Rebuilt, not reloaded.** With "not decided yet" on, deciding a pair removes it from the list; leaving
        // the row where it was would show a pair the state has already moved past -- which a real screenshot of
        // the exact review caught once, the sidebar highlighting group 31 while the header said 32 of 880.
        if filter.onlyUndecided {
            rebuildVisible()
        } else {
            table.reloadData(forRowIndexes: [selectedRow], columnIndexes: allColumnIndexes)
            advanceSelection()
            refreshDetail()
        }
    }

    @objc private func skipPair(_ sender: Any?) {
        guard pairs.indices.contains(selectedRow) else { return }
        guard let index = scanIndex(forRow: selectedRow) else { return }
        let advancing = !filter.onlyUndecided
        mutate { state in
            state.go(to: index)
            state.skip()
        }
        if advancing { advanceSelection() }
    }

    private var allColumnIndexes: IndexSet {
        IndexSet(integersIn: 0..<table.tableColumns.count)
    }

    /// Moves to the next pair, which is what makes deciding a rhythm rather than a click-and-hunt.
    private func advanceSelection() {
        let next = selectedRow + 1
        guard pairs.indices.contains(next) else { return }
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    /// Applies a change to the review and registers its inverse with the undo manager.
    ///
    /// **The whole state is captured, not a delta** -- the same trade the exact review makes. It is a dictionary of
    /// small enums over at most a few thousand pairs, so a snapshot costs less than the bookkeeping a delta needs,
    /// and an undo that restores a snapshot cannot drift from the operation it reverses.
    ///
    /// **And the undo saves too.** Decisions here are written as they are made, so an undo that only changed memory
    /// would leave the file holding a decision the window no longer shows -- and the CLI reading it.
    private func mutate(_ body: (inout SimilarReviewState) -> Void) {
        // **Grouped explicitly rather than by event, and never while undoing.** `UndoManager` groups every
        // registration made in one turn of the run loop, which is right for typing and wrong for a batch: accepting
        // 2,106 pairs in one call would otherwise be indistinguishable from one decision. And opening a group
        // inside `undo()` breaks the manager's own phase tracking, so the registration an undo makes lands back on
        // the undo stack instead of the redo stack.
        let grouping = !undo.isUndoing && !undo.isRedoing
        if grouping { undo.beginUndoGrouping() }
        defer { if grouping { undo.endUndoGrouping() } }
        let before = review
        body(&review)
        // `MainActor.assumeIsolated` is not decoration: on the macOS 15 SDK that CI compiles against,
        // `registerUndo`'s closure is not `@MainActor`, so this is a hard error there and clean locally. The
        // assumption holds -- `UndoManager` runs the block on the thread that called `undo()`, and the only caller
        // is the Edit menu.
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.mutate { $0 = before } }
        }
        saveDecisions()
        rebuildVisible()
    }

    /// Writes what has been decided, and **only** what has been decided.
    private func saveDecisions() {
        let document = review.decisionsForSaving
        do {
            _ = try ScanStore(state: stateDirectory).save(document, scanID: scan.scanID)
            savedCount = document.count
        } catch {
            // Reported in the footer rather than in a sheet: losing a decision matters, and a modal over every
            // click would make deciding 4,771 pairs impossible.
            saveFailure = String(describing: error)
        }
    }

    /// Simulates, then -- only from the sheet -- applies.
    @objc private func simulateAndApply(_ sender: Any?) {
        let plan = SimilarApplyPlan.from(review)
        // The gate wants a review that decided something and a dry run of *this* plan. Both are established
        // here, in the window that owns the review; the sheet never advances its own flow.
        flow.decisionsChanged(hasAny: review.tally.decided > 0)
        guard flow.advance(.dryRun, fingerprint: plan.fingerprint) != nil else {
            let alert = NSAlert()
            alert.messageText = Strings.string("similar.apply.nothing")
            alert.addButton(withTitle: Strings.string("button.ok"))
            alert.runModal()
            return
        }
        let sheet = SimilarApplySheetController(
            plan: plan, fingerprint: plan.fingerprint, flow: flow,
            stateDirectory: stateDirectory)
        sheet.onApplied = { [weak self] _ in
            // A file that moved is a file the panes must stop showing as if it were there.
            self?.refreshDetail()
        }
        sheet.onUndone = { [weak self] in self?.refreshDetail() }
        applySheet = sheet
        if let window, let sheetWindow = sheet.window {
            window.beginSheet(sheetWindow) { [weak self] _ in self?.applySheet = nil }
        } else {
            sheet.showWindow(nil)
        }
    }

    @objc private func revealSelected(_ sender: Any?) {
        guard let pair = selectedPair else { return }
        Reveal.item(at: pair.fileA)
    }

    /// Opens Quick Look on **both** sides of the pair, or closes it.
    ///
    /// Both, in the window's own order, because the panel's arrow keys then become the comparison: this is the
    /// full-size version of what the two panes are showing side by side, and a panel holding one of the two
    /// would answer half the question.
    @objc func toggleQuickLook(_ sender: Any?) {
        _ = quickLook.toggle(paths: quickLookPaths(), controller: self)
    }

    private func quickLookPaths() -> [String] {
        guard let pair = selectedPair else { return [] }
        return [pair.fileA, pair.fileB]
    }

    /// Shows both files in Finder.
    ///
    /// **Both, and that is the honest answer to an ambiguous request.** A pair has two files and the menu item
    /// says "in Finder"; picking one silently would be picking for the user. Finder selects several items at
    /// once, so this is one action, not a choice they did not ask to make.
    @objc func revealSelectedFile(_ sender: Any?) {
        guard let pair = selectedPair else { return }
        let urls = [pair.fileA, pair.fileB]
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(filePath: $0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// What Quick Look would show for the current selection, without opening a panel.
    ///
    /// Asserted instead of the panel itself: `QLPreviewPanel` is a shared system window, and a mode that opened
    /// it would leave one on screen for the next mode and assert against a window it does not own.
    var quickLookPathsForSelftest: [String] { quickLookPaths() }

    // MARK: - Selftest hooks

    var pairRowCount: Int { table.numberOfRows }
    var headerText: String { headerLabel.stringValue }

    var leftMetadataForSelftest: (text: String, hidden: Bool) { leftPane.metadataForSelftest }
    var rightMetadataForSelftest: (text: String, hidden: Bool) { rightPane.metadataForSelftest }

    /// Waits for the media probe of the selected pair, so an assertion is not a race against a decode.
    ///
    /// Waits for the **resolution**, not for any text: the size and the date come from a `stat` the pane does
    /// itself, so a wait on "not empty" returns immediately and asserts nothing about the probe.
    func awaitFactsForSelftest() async {
        for _ in 0..<200 {
            if leftPane.metadataForSelftest.text.contains("\u{00D7}") { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
    var footerText: String { footerLabel.stringValue }
    var leftPaneText: String { leftPane.pathText }
    var leftStateForSelftest: String { leftPane.stateText }
    var rightPaneText: String { rightPane.pathText }
    var requiredContentSize: NSSize {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.fittingSize ?? .zero
    }

    var adviceText: String { adviceLabel.stringValue }
    var tallyText: String { tallyLabel.stringValue }
    var reviewTallyForSelftest: (decided: Int, skipped: Int, undecided: Int) { review.tally }
    var contradictionsForSelftest: [String] { review.contradictions }

    var ambiguousKeysForSelftest: [String] { review.ambiguousKeys }

    var applySheetForSelftest: SimilarApplySheetController? { applySheet }

    func simulateForSelftest() { simulateAndApply(nil) }

    var shownCountForSelftest: Int { visible.count }
    var countText: String { countLabel.stringValue }

    func setFilterForSelftest(minimumSimilarity: Double = 0, onlyUndecided: Bool = false) {
        filter = PairFilter(minimumSimilarity: minimumSimilarity, onlyUndecided: onlyUndecided)
        rebuildVisible()
    }

    func confirmShownForSelftest() {
        let indices = visible
        mutate { $0.confirmAll(indices) }
    }

    func undoForSelftest() { undo.undo() }
    var canUndoForSelftest: Bool { undo.canUndo }

    func decideForSelftest(_ decision: SimilarDecision, row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        guard let button = decisionButtons[decision] else { return }
        decisionChosen(button)
    }

    func skipForSelftest(row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        skipPair(nil)
    }

    func selectPairForSelftest(_ row: Int) {
        guard pairs.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        refreshDetail()
    }

    func cellTextForSelftest(row: Int, column: String) -> String? {
        guard pairs.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier(column)
        guard let tableColumn = table.tableColumns.first(where: { $0.identifier == identifier })
        else { return nil }
        return text(for: pairs[row], column: tableColumn)
    }

    private func text(for pair: SimilarPair, column: NSTableColumn) -> String {
        switch column.identifier.rawValue {
        case "similarity": return String(format: "%.2f%%", pair.similarity * 100)
        case "kind":
            return Strings.string(
                pair.mediaKind == .image ? "similar.kind.image" : "similar.kind.video")
        case "a": return (pair.fileA as NSString).lastPathComponent
        case "b": return (pair.fileB as NSString).lastPathComponent
        case "decision":
            guard let row = pairs.firstIndex(of: pair), let index = scanIndex(forRow: row) else {
                return ""
            }
            switch review.decision(at: index) {
            case .decided(let decision): return SimilarAdviceText.label(for: decision)
            case .skipped: return Strings.string("similar.state.skipped")
            case .undecided: return Strings.string("similar.state.undecided")
            }
        default: return ""
        }
    }
}

extension SimilarPairWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { pairs.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, pairs.indices.contains(row) else { return nil }
        let identifier = tableColumn.identifier
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let created = NSTableCellView()
                created.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingMiddle
                field.translatesAutoresizingMaskIntoConstraints = false
                created.addSubview(field)
                created.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: created.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: created.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: created.centerYAnchor),
                ])
                return created
            }()
        cell.textField?.stringValue = text(for: pairs[row], column: tableColumn)
        cell.textField?.toolTip =
            identifier.rawValue == "a"
            ? pairs[row].fileA : (identifier.rawValue == "b" ? pairs[row].fileB : nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshDetail()
    }
}

/// One side of the comparison: a thumbnail, the file name and its full path.
@MainActor
final class SimilarSidePane: NSView {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    /// Size, date, and -- once the probe answers -- the resolution, codec and duration.
    ///
    /// **The numbers that decide a perceptual pair, which the app was computing and not showing.** Two photos
    /// that look alike differ in exactly the ways this line names: one is 4032x3024 and the other 1024x768, one
    /// is 8 MB and the other 400 KB, one is from the camera and the other from a chat app. The advice already
    /// read all of it to make a suggestion; the reader was being asked to trust the suggestion without seeing
    /// what it rested on.
    private let metadataLabel = NSTextField(labelWithString: "")
    private var currentPath: String?

    /// Locale-aware, unlike the byte counts, which are pinned to the CLI's format because they are interop.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        // **No height-equals-width constraint.** One of those on a wide pane demanded 1,100 points of height,
        // pushed the rest of the layout off screen and made the window refuse to shrink -- a required
        // constraint is required. The image is scaled proportionally instead.
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        pathLabel.font = .systemFont(ofSize: 10)
        pathLabel.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.textColor = .systemOrange
        stateLabel.isHidden = true
        // Monospaced digits: this line is mostly numbers and it is redrawn on every arrow key, so a
        // proportional numeral makes the whole pane twitch sideways.
        metadataLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.maximumNumberOfLines = 2
        for label in [nameLabel, pathLabel, stateLabel, metadataLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let stack = NSStackView(views: [
            imageView, nameLabel, pathLabel, metadataLabel, stateLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        // The preference reaches panes already on screen, because one that only applied to windows opened
        // later reads as a bug rather than as a setting.
        NotificationCenter.default.addObserver(
            forName: MetadataPreference.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMetadataPreference() }
        }
    }

    var metadataForSelftest: (text: String, hidden: Bool) {
        (metadataLabel.stringValue, metadataLabel.isHidden)
    }

    /// The metadata sentence: size, date, and the media facts when they have arrived.
    ///
    /// **Built here rather than in Core because it is prose**, and `DuplicateCore` never produces prose. The
    /// byte count is the one part that is *not* localised: `512 B`, `1.0 KB`, `3.5 MB` with a dot in both
    /// languages, because that format is pinned by the CLI's own tests and this app matches it on purpose.
    /// Dates are locale-aware, because nothing reads a date across tools.
    static func metadataText(attributes: [FileAttributeKey: Any]?, facts: MediaFacts?) -> String {
        var parts: [String] = []
        if let size = attributes?[.size] as? Int64 {
            parts.append(ByteSize.format(size))
        }
        if let modified = attributes?[.modificationDate] as? Date {
            parts.append(dateFormatter.string(from: modified))
        }
        if let facts, facts.pixelWidth > 0, facts.pixelHeight > 0 {
            parts.append("\(facts.pixelWidth)\u{00D7}\(facts.pixelHeight)")
        }
        if let facts, !facts.codec.isEmpty {
            // An unrecognised codec is marked rather than passed off as H.264, which is what the CLI's
            // `.get(codec, 1.0)` does silently -- a guess capable of handing the decision to the wrong file.
            parts.append(facts.isCodecKnown ? facts.codec : facts.codec + "?")
        }
        if let facts, facts.duration > 0 {
            let total = Int(facts.duration.rounded())
            parts.append(String(format: "%d:%02d", total / 60, total % 60))
        }
        return parts.joined(separator: "  \u{00B7}  ")
    }

    /// Adds the media facts to the line once the probe has answered.
    ///
    /// Separate from ``show(path:thumbnailer:)`` because probing decodes the file -- about 7 ms for an image and
    /// 300 ms for a video -- and the size and date are known from the `stat` the pane already did. Making the
    /// reader wait on a decode to learn how big a file is would be backwards.
    func show(facts: MediaFacts?) {
        guard let path = currentPath else { return }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        metadataLabel.stringValue = Self.metadataText(attributes: attributes, facts: facts)
        applyMetadataPreference()
    }

    /// Hides or shows the metadata line without losing what it says.
    ///
    /// The text is kept rather than cleared: turning the line back on has to be instant, and re-probing a
    /// video to redraw a line the user just asked for would be absurd.
    private func applyMetadataPreference() {
        metadataLabel.isHidden = !MetadataPreference.isEnabled || metadataLabel.stringValue.isEmpty
    }

    func showEmpty() {
        currentPath = nil
        imageView.image = nil
        nameLabel.stringValue = ""
        pathLabel.stringValue = ""
        stateLabel.stringValue = ""
        stateLabel.isHidden = true
        metadataLabel.stringValue = ""
        metadataLabel.isHidden = true
    }

    func show(path: String, thumbnailer: QuickLookThumbnailer) {
        currentPath = path
        nameLabel.stringValue = (path as NSString).lastPathComponent
        pathLabel.stringValue = path
        pathLabel.toolTip = path

        // **An empty pane is ambiguous and this pane is often empty.** Measured on this machine: of the pairs
        // in the real perceptual scans, one side of the very first one is already gone -- the CLI's May
        // history has expired. Without this line, "the file is missing" and "the thumbnail has not arrived
        // yet" look identical, and the user is left comparing one picture against a blank rectangle.
        // **One `attributesOfItem` instead of a `fileExists`**, which is the same class of call and answers
        // three questions rather than one: whether it is there, how big it is, and when it changed. The size
        // and the date are what a perceptual pair is actually decided on, so paying a second stat for them
        // would be paying twice for one answer.
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let exists = attributes != nil
        stateLabel.stringValue = exists ? "" : Strings.string("similar.state.missing")
        stateLabel.isHidden = exists
        metadataLabel.stringValue = Self.metadataText(attributes: attributes, facts: nil)
        applyMetadataPreference()
        guard exists else {
            imageView.image = nil
            return
        }

        let pixels = ThumbnailPolicy.pixelSize(
            points: Double(max(120, bounds.width)),
            scale: Double(window?.backingScaleFactor ?? 2))
        if let cached = thumbnailer.cached(path: path, pixelSize: pixels) {
            imageView.image = NSImage(cgImage: cached, size: .zero)
            return
        }
        imageView.image = nil
        Task { @MainActor [weak self] in
            let image = await thumbnailer.thumbnail(path: path, pixelSize: pixels)
            // The selection may have moved on while quicklookd was working.
            guard let self, self.currentPath == path else { return }
            if let image { self.imageView.image = NSImage(cgImage: image, size: .zero) }
        }
    }

    var pathText: String { pathLabel.stringValue }
    var stateText: String { stateLabel.stringValue }
    var hasImage: Bool { imageView.image != nil }
}

/// What the number over a pair means, in the user's language.
///
/// **The second number is not the same quantity for the two kinds.** An image similarity is `1 - hamming/64`, so
/// bits are the honest unit. A video similarity is the *fraction of sampled frames that matched* -- there is no
/// 64-bit distance behind it, and printing "0 of 64 bits differ" under a video pair, which is what shipped once,
/// states a measurement that was never taken.
///
/// **And for a video it says how many frames the number rests on, when it is fewer than eight.** The sampler puts
/// frames at `interval·(i+1)` with a floor of 0.1 s, so a short clip has timestamps past its own end: at half a
/// second, four of the eight. The CLI hashes the ones that exist and compares on those, so "83% of sampled frames
/// match" over three frames is a far weaker claim than over eight -- and the reader cannot see the difference
/// unless it is said. Durations are optional because the probe is asynchronous: before it answers, the plain
/// sentence is the honest one.
func similarHeaderText(pair: SimilarPair, durationA: Double?, durationB: Double?) -> String {
    switch pair.mediaKind {
    case .image:
        return String(
            format: Strings.string("similar.header.image"),
            pair.similarity * 100,
            Int(((1.0 - pair.similarity) * 64.0).rounded())
        )
    case .video:
        let total = VideoFrameSampler.defaultFrameCount
        let frames = min(
            VideoFrameSampler.usableCount(duration: durationA ?? 0),
            VideoFrameSampler.usableCount(duration: durationB ?? 0))
        guard frames > 0, frames < total else {
            return String(format: Strings.string("similar.header.video"), pair.similarity * 100)
        }
        return String(
            format: Strings.string("similar.header.video.fewFrames"),
            pair.similarity * 100, frames, total)
    }
}

/// **Quick Look asks the responder chain for permission and then for a data source.** Without these three the
/// panel opens empty, which looks exactly like a broken preview rather than like missing wiring.
extension SimilarPairWindowController {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    /// **`MainActor.assumeIsolated`, and it is not decoration.** These come from `NSResponder`, which this SDK
    /// does not annotate, so they arrive `nonisolated` while `QLPreviewPanel.dataSource` is main-actor isolated.
    /// Locally that is a warning; on the SDK CI compiles against it is the kind of thing that turns into a hard
    /// error, which is the fifth time this project has met that gap. Quick Look only ever calls these on the main
    /// thread, which is what the assumption states.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = quickLook
            panel.delegate = quickLook
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }
}
