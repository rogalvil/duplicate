import AppKit
import DuplicateCore

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
final class SimilarPairWindowController: NSWindowController {

    private let scan: SimilarScan
    private let pairs: [SimilarPair]
    private let stateDirectory: StateDirectory
    private var review: SimilarReviewState
    /// Facts already probed, by path. Filled for the pair being looked at, never for all of them.
    private var facts: [String: MediaFacts] = [:]
    private var probeGeneration = 0
    private let probe = MediaProbe()
    private let table = NSTableView()
    private let thumbnailer = QuickLookThumbnailer()
    private let leftPane = SimilarSidePane()
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

    init(scan: SimilarScan, stateDirectory: StateDirectory = StateDirectory.current()) {
        self.scan = scan
        self.pairs = scan.pairs
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
        build()
        refreshDetail()
        if !pairs.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

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

        let content = NSStackView(views: [
            scroll, headerLabel, panes, adviceLabel, decisionRow, tallyLabel, footerLabel,
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
        switch pair.mediaKind {
        case .image:
            headerLabel.stringValue = String(
                format: Strings.string("similar.header.image"),
                pair.similarity * 100,
                Int(((1.0 - pair.similarity) * 64.0).rounded())
            )
        case .video:
            headerLabel.stringValue = String(
                format: Strings.string("similar.header.video"), pair.similarity * 100)
        }
        leftPane.show(path: pair.fileA, thumbnailer: thumbnailer)
        rightPane.show(path: pair.fileB, thumbnailer: thumbnailer)
        refreshAdvice(row: selectedRow, pair: pair)
        refreshDecisionButtons(row: selectedRow)
        probeFactsIfNeeded(row: selectedRow, pair: pair)
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
        }
    }

    /// Warns when one file is kept by one pair and discarded by another.
    ///
    /// **Shown on close rather than on every click**: the conflict only matters when the set of decisions is done
    /// with, and a sheet after each choice would make deciding impossible.
    func presentContradictionsIfNeeded() {
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

    @objc private func decisionChosen(_ sender: Any?) {
        guard let button = sender as? NSButton,
            SimilarPairWindowController.decisionOrder.indices.contains(button.tag),
            pairs.indices.contains(selectedRow)
        else { return }
        let decision = SimilarPairWindowController.decisionOrder[button.tag]
        review.go(to: selectedRow)
        review.confirm(decision)
        // Saved as it goes, for the same reason the exact review does: a decision the user made and an app that
        // forgot it are indistinguishable from the outside.
        saveDecisions()
        table.reloadData(forRowIndexes: [selectedRow], columnIndexes: allColumnIndexes)
        advanceSelection()
        refreshDetail()
    }

    @objc private func skipPair(_ sender: Any?) {
        guard pairs.indices.contains(selectedRow) else { return }
        review.go(to: selectedRow)
        review.skip()
        saveDecisions()
        table.reloadData(forRowIndexes: [selectedRow], columnIndexes: allColumnIndexes)
        advanceSelection()
        refreshDetail()
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

    // MARK: - Selftest hooks

    var pairRowCount: Int { table.numberOfRows }
    var headerText: String { headerLabel.stringValue }
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

    var applySheetForSelftest: SimilarApplySheetController? { applySheet }

    func simulateForSelftest() { simulateAndApply(nil) }

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
            guard let row = pairs.firstIndex(of: pair) else { return "" }
            switch review.decision(at: row) {
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
    private var currentPath: String?

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
        for label in [nameLabel, pathLabel, stateLabel] {
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let stack = NSStackView(views: [imageView, nameLabel, pathLabel, stateLabel])
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
    }

    func showEmpty() {
        currentPath = nil
        imageView.image = nil
        nameLabel.stringValue = ""
        pathLabel.stringValue = ""
        stateLabel.stringValue = ""
        stateLabel.isHidden = true
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
        let exists = FileManager.default.fileExists(atPath: path)
        stateLabel.stringValue = exists ? "" : Strings.string("similar.state.missing")
        stateLabel.isHidden = exists
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
