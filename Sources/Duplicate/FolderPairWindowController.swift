import AppKit
import DuplicateCore
@preconcurrency import Quartz

/// Shows what a folder scan found.
///
/// **Read-only, and that is a deliberate stopping point.** Removing a folder is not removing a file: a
/// folder that is 95% a copy of another still holds the 5% that is not, and a single click that trashes a
/// tree would be the most dangerous button in the app. Reviewing and applying folder pairs needs its own
/// design and its own decisions format; this window exists so a scan is useful before that lands.
///
/// What it offers instead: the pairs, their overlap, what each side has that the other does not, and Finder.
@MainActor
final class FolderPairWindowController: NSWindowController, NSWindowDelegate {
    private let scan: FolderScan
    private let stateDirectory: StateDirectory
    private var review: FolderReviewState
    private var flow = ReviewFlow()
    private var applySheet: FolderApplySheetController?
    private let adviceLabel = NSTextField(labelWithString: "")
    private let tallyLabel = NSTextField(labelWithString: "")
    private var decisionButtons: [String: NSButton] = [:]
    private var savedCount = 0
    private let undo: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private var pairs: [FolderPair] = []

    private let table = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let detailView = NSTextView()
    /// **What the two folders are, beside how alike they are.** The header already says the similarity and
    /// the file counts -- those come out of the scan document -- and the one thing a person reaching for
    /// "which of these two do I keep" asks next is which one is newer. That is one `stat` per side.
    ///
    /// **A folder's size is not here, and that is a measurement rather than an omission.** A directory has no
    /// size of its own: getting one means walking it, and the folder apply already pays for that walk once to
    /// build a manifest -- 979 MB/s over a 10,506-file tree, tens of seconds. Paying it again on every arrow
    /// key, to draw a number nobody decides on, is the wrong trade.
    private let metadataLabel = NSTextField(labelWithString: "")
    private let quickLook = QuickLookCoordinator()
    private let footerLabel = NSTextField(labelWithString: "")

    init(scan: FolderScan, stateDirectory: StateDirectory = StateDirectory.current()) {
        self.stateDirectory = stateDirectory
        self.review = FolderReviewState(
            scan: scan,
            priorDecisions: ScanStore(state: stateDirectory)
                .priorFolderDecisions(scanID: scan.scanID)
        )
        self.scan = scan
        self.pairs = scan.pairs

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            format: Strings.string("folders.window.title"),
            PathElision.elide(scan.root, leading: 1, trailing: 2)
        )
        window.center()
        window.setFrameAutosaveName("FolderPairWindow")
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self
        build()
        observeMetadataPreference()
        if !pairs.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        refreshDetail()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this window is built in code, there is no nib")
    }

    private func build() {
        guard let window else { return }
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = false
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.target = self
        table.doubleAction = #selector(revealA(_:))
        table.menu = rowMenu()
        for (name, key, width, numeric) in [
            ("similarity", "folders.column.similarity", CGFloat(90), true),
            ("a", "folders.column.a", CGFloat(280), false),
            ("b", "folders.column.b", CGFloat(280), false),
            ("matching", "folders.column.matching", CGFloat(110), true),
            ("difference", "folders.column.difference", CGFloat(120), true),
            ("decision", "folders.column.decision", CGFloat(140), false),
        ] as [(String, String, CGFloat, Bool)] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = Strings.string(key)
            column.width = width
            if numeric { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        headerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        detailView.isEditable = false
        detailView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        detailView.drawsBackground = false
        let detailScroll = NSScrollView()
        detailScroll.documentView = detailView
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        adviceLabel.font = .systemFont(ofSize: 11)
        adviceLabel.maximumNumberOfLines = 2
        tallyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tallyLabel.textColor = .secondaryLabelColor
        metadataLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.isHidden = true
        for label in [headerLabel, footerLabel, adviceLabel, tallyLabel, metadataLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingMiddle
        }

        let decisionRow = NSStackView()
        decisionRow.orientation = .horizontal
        decisionRow.spacing = 8
        decisionRow.translatesAutoresizingMaskIntoConstraints = false
        for (identifier, key) in [
            ("keepA", "folders.decision.keepA"), ("keepB", "folders.decision.keepB"),
            ("keepBoth", "folders.decision.keepBoth"), ("skip", "folders.decision.skip"),
        ] {
            let button = NSButton()
            button.title = Strings.string(key)
            button.bezelStyle = .rounded
            button.setButtonType(.pushOnPushOff)
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            button.target = self
            button.action = #selector(decisionChosen(_:))
            decisionButtons[identifier] = button
            decisionRow.addView(button, in: .leading)
        }
        let applyButton = NSButton()
        applyButton.title = Strings.string("folders.review.apply")
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(simulateAndApply(_:))
        decisionRow.addView(applyButton, in: .trailing)

        let content = NSStackView(views: [
            scroll, headerLabel, metadataLabel, detailScroll, adviceLabel, decisionRow, tallyLabel,
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
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            detailScroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            detailScroll.heightAnchor.constraint(equalToConstant: 150),
        ])
        window.contentView = container
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        for (key, selector) in [
            ("folders.action.revealA", #selector(revealA(_:))),
            ("folders.action.revealB", #selector(revealB(_:))),
        ] {
            let item = menu.addItem(
                withTitle: Strings.string(key), action: selector, keyEquivalent: "")
            item.target = self
        }
        return menu
    }

    private var selectedPair: FolderPair? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return pairs.indices.contains(row) ? pairs[row] : nil
    }

    /// The count, the threshold, and what the two columns mean to anything that acts on them.
    ///
    /// `rav duplicate folders-move` keeps `folder_a` and moves `folder_b` to quarantine. This viewer is
    /// read-only, so the CLI is the only thing that can act on a pair today -- which makes "which side gets
    /// destroyed" information the reader needs here, not a footnote for the docs.
    private func footerString() -> String {
        String(format: Strings.string("folders.footer"), pairs.count, Int(scan.threshold * 100))
            + "  ·  " + Strings.string("folders.orientation")
    }

    /// Locale-aware, unlike the byte counts, which are pinned to the CLI's format because they are interop.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// The counts the scan recorded and the date each folder carries on disk.
    ///
    /// Built here rather than in Core, because Core never produces prose. A folder whose date cannot be read
    /// is named without one rather than skipped: the pair is still worth deciding, and a missing date is
    /// itself information.
    static func metadataText(for pair: FolderPair, formatter: DateFormatter) -> String {
        func describe(_ path: String, _ count: Int) -> String {
            let name = (path as NSString).lastPathComponent
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let modified = attributes?[.modificationDate] as? Date else {
                return String(format: Strings.string("folders.meta.side.noDate"), name, count)
            }
            return String(
                format: Strings.string("folders.meta.side"), name, count,
                formatter.string(from: modified))
        }
        return describe(pair.folderA, pair.totalA) + "     "
            + describe(pair.folderB, pair.totalB)
    }

    /// The same preference the file viewers honour, or "Show File Metadata" would govern two windows out of
    /// three, which makes the menu item a lie rather than a setting.
    private func observeMetadataPreference() {
        NotificationCenter.default.addObserver(
            forName: MetadataPreference.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDetail() }
        }
    }

    private func refreshDetail() {
        guard let pair = selectedPair else {
            headerLabel.stringValue = Strings.string("folders.empty")
            detailView.string = ""
            metadataLabel.stringValue = ""
            metadataLabel.isHidden = true
            footerLabel.stringValue = footerString()
            refreshAdvice()
            return
        }
        headerLabel.stringValue = String(
            format: Strings.string("folders.header"),
            Int(pair.similarity * 100), pair.matching, pair.totalA, pair.totalB
        )

        // The whole difference, not a sample: a folder pair is worth acting on only if you can see what
        // acting on it would lose.
        var lines: [String] = []
        if !pair.onlyInA.isEmpty {
            lines.append(String(format: Strings.string("folders.onlyIn"), pair.folderA))
            lines.append(contentsOf: pair.onlyInA.map { "    " + $0 })
        }
        if !pair.onlyInB.isEmpty {
            lines.append(String(format: Strings.string("folders.onlyIn"), pair.folderB))
            lines.append(contentsOf: pair.onlyInB.map { "    " + $0 })
        }
        if !pair.changed.isEmpty {
            lines.append(Strings.string("folders.changedHeader"))
            lines.append(contentsOf: pair.changed.map { "    " + $0 })
        }
        if lines.isEmpty { lines.append(Strings.string("folders.identical")) }
        detailView.string = lines.joined(separator: "\n")

        metadataLabel.stringValue = Self.metadataText(for: pair, formatter: dateFormatter)
        metadataLabel.isHidden =
            !MetadataPreference.isEnabled || metadataLabel.stringValue.isEmpty
        footerLabel.stringValue = footerString()
        refreshAdvice()
    }

    private var selectedRow: Int {
        table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    }

    /// **What the scan already knows, said before the decision instead of after the refusal.**
    ///
    /// A folder pair carries `only_in_a` and `only_in_b`, so the window can say "moving the second would lose 5
    /// files it has and the first does not" while the user is choosing -- rather than letting them choose, press
    /// apply, and read it in a refusal list. The apply still checks: the scan may be old, and its counts are what
    /// was true then.
    private func refreshAdvice() {
        // **The tally is the whole review's and does not belong behind the per-row guard.** The advice
        // talks about this pair, so it clears with the selection; `decided / skipped / not looked at` is
        // about all of them, and clearing it took away the one number that says a decision landed.
        let tally = review.tally
        tallyLabel.stringValue = String(
            format: Strings.string("folders.tally"), tally.decided, tally.skipped, tally.undecided)
        guard pairs.indices.contains(selectedRow) else {
            adviceLabel.stringValue = ""
            return
        }
        let pair = pairs[selectedRow]
        let keep = review.effectiveKeep(at: selectedRow)
        let doomed = keep.contains(pair.folderA) ? pair.folderB : pair.folderA
        let losing = doomed == pair.folderA ? pair.onlyInA : pair.onlyInB
        let name = (doomed as NSString).lastPathComponent
        if keep.count > 1 {
            adviceLabel.stringValue = ""
        } else if losing.isEmpty {
            adviceLabel.stringValue = String(format: Strings.string("folders.warnNoLoss"), name)
            adviceLabel.textColor = .secondaryLabelColor
        } else {
            adviceLabel.stringValue = String(
                // **The count goes first.** Foundation chooses a `.stringsdict` variant from the argument
                // at the plural variable's own position, so a leading `%1$@` made it read the folder name
                // as the number and always pick the plural. Measured: "1 archivos" with the name mangled.
                format: Strings.string("folders.warnLoss"), losing.count, name)
            adviceLabel.textColor = .systemOrange
        }

        let decision = review.decision(at: selectedRow)
        let kept = decision.keptPaths
        for (identifier, button) in decisionButtons {
            switch identifier {
            case "keepA": button.state = kept == [pair.folderA] ? .on : .off
            case "keepB": button.state = kept == [pair.folderB] ? .on : .off
            case "keepBoth": button.state = (kept?.count ?? 0) > 1 ? .on : .off
            default: button.state = decision == .skipped ? .on : .off
            }
        }
    }

    @objc private func decisionChosen(_ sender: Any?) {
        guard let button = sender as? NSButton, let identifier = button.identifier?.rawValue,
            pairs.indices.contains(selectedRow)
        else { return }
        let pair = pairs[selectedRow]
        let row = selectedRow
        mutate { state in
            state.go(to: row)
            switch identifier {
            case "keepA": state.keep(pair.folderA)
            case "keepB": state.keep(pair.folderB)
            case "keepBoth": state.keepBoth()
            default: state.skip()
            }
        }
        let next = row + 1
        if pairs.indices.contains(next) {
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
            refreshDetail()
        }
    }

    /// **Where ⌘Z arrives.** AppKit asks the window's delegate for the undo manager; without this the Edit menu's
    /// `undo:` reaches nothing and the item is greyed out -- a working undo nobody can invoke.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    /// Applies a change and registers its inverse. The whole state is captured, like the other two reviews.
    ///
    /// **And the undo saves too**, because decisions here are written as they are made: an undo that only changed
    /// memory would leave the file holding a decision the window no longer shows.
    private func mutate(_ body: (inout FolderReviewState) -> Void) {
        // **Grouped explicitly, not by event.** `UndoManager` defaults to grouping every registration made in one
        // turn of the run loop, which is right for typing and wrong here: two decisions taken without a turn in
        // between -- which is what a batch, or a harness, does -- would collapse into one undo step. Measured: the
        // first ⌘Z took a skip back and the second did nothing, because both had landed in the same group.
        // **And not while undoing.** Opening a group inside `undo()` breaks the manager's own phase tracking: the
        // registration the undo makes lands back on the undo stack instead of the redo stack, so pressing ⌘Z twice
        // undoes the same step twice. Measured -- the second press kept reporting one decision.
        let grouping = !undo.isUndoing && !undo.isRedoing
        if grouping { undo.beginUndoGrouping() }
        defer { if grouping { undo.endUndoGrouping() } }
        let before = review
        body(&review)
        // Not decoration: `registerUndo`'s closure is not `@MainActor` on the SDK CI compiles against.
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.mutate { $0 = before } }
        }
        saveDecisions()
        // **`reloadData()` drops the table's selection**, and every mutation has to put it back or the
        // window goes blank: no detail, no advice, and no tally -- so nothing at all says the decision
        // registered. Restoring here rather than at the call sites covers undo too, which had the same
        // hole and no `next` row to hide behind.
        let selected = selectedRow
        table.reloadData()
        if pairs.indices.contains(selected) {
            table.selectRowIndexes([selected], byExtendingSelection: false)
        }
        refreshDetail()
    }

    private func saveDecisions() {
        let document = review.decisionsForSaving(instant: ScanIdentifier.Instant(Date()))
        savedCount = document.count
        // Only decided pairs are in there; an empty document is still worth writing, because it is how a review
        // that cleared its decisions stops the CLI from acting on the old ones.
        _ = try? ScanStore(state: stateDirectory).save(document)
    }

    @objc private func simulateAndApply(_ sender: Any?) {
        let plan = FolderApplyPlan.from(review)
        flow.decisionsChanged(hasAny: review.tally.decided > 0)
        guard flow.advance(.dryRun, fingerprint: plan.fingerprint) != nil else {
            let alert = NSAlert()
            alert.messageText = Strings.string("folders.apply.nothing")
            alert.addButton(withTitle: Strings.string("button.ok"))
            alert.runModal()
            return
        }
        let sheet = FolderApplySheetController(
            plan: plan, fingerprint: plan.fingerprint, flow: flow, stateDirectory: stateDirectory)
        sheet.onApplied = { [weak self] _ in self?.refreshDetail() }
        sheet.onUndone = { [weak self] in self?.refreshDetail() }
        applySheet = sheet
        if let window, let sheetWindow = sheet.window {
            window.beginSheet(sheetWindow) { [weak self] _ in self?.applySheet = nil }
        } else {
            sheet.showWindow(nil)
        }
    }

    @objc private func revealA(_ sender: Any?) {
        guard let pair = selectedPair else { return }
        Reveal.folder(at: pair.folderA)
    }

    @objc private func revealB(_ sender: Any?) {
        guard let pair = selectedPair else { return }
        Reveal.folder(at: pair.folderB)
    }

    /// Opens Quick Look on both folders, or closes it.
    ///
    /// A folder previews as its Finder icon and item count rather than as a picture, which is less than a photo
    /// gives -- and still the fastest way to see that one of the two is not there any more, which in this
    /// user's real folder scans is the common case.
    @objc func toggleQuickLook(_ sender: Any?) {
        _ = quickLook.toggle(paths: quickLookPaths(), controller: self)
    }

    private func quickLookPaths() -> [String] {
        guard let pair = selectedPairForQuickLook else { return [] }
        return [pair.folderA, pair.folderB]
    }

    /// Opens both folders in Finder.
    @objc func revealSelectedFile(_ sender: Any?) {
        guard let pair = selectedPairForQuickLook else { return }
        for path in [pair.folderA, pair.folderB] {
            Reveal.folder(at: path)
        }
    }

    /// The pair under the selection, or nil.
    private var selectedPairForQuickLook: FolderPair? {
        pairs.indices.contains(selectedRow) ? pairs[selectedRow] : nil
    }

    /// What Quick Look would show for the current selection, without opening a panel.
    ///
    /// Asserted instead of the panel itself: `QLPreviewPanel` is a shared system window, and a mode that opened
    /// it would leave one on screen for the next mode and assert against a window it does not own.
    var quickLookPathsForSelftest: [String] { quickLookPaths() }

    // MARK: - Selftest hooks

    var pairRowCount: Int { table.numberOfRows }
    var headerText: String { headerLabel.stringValue }
    var detailText: String { detailView.string }
    var metadataForSelftest: (text: String, hidden: Bool) {
        (metadataLabel.stringValue, metadataLabel.isHidden)
    }
    var footerText: String { footerLabel.stringValue }
    var requiredContentSize: NSSize {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.fittingSize ?? .zero
    }

    var adviceText: String { adviceLabel.stringValue }
    var tallyText: String { tallyLabel.stringValue }
    var selectedRowForSelftest: Int { table.selectedRow }

    /// Clicking empty space in the table deselects, and the tally has to survive that.
    func clearSelectionForSelftest() {
        table.deselectAll(nil)
        refreshDetail()
    }
    var reviewTallyForSelftest: (decided: Int, skipped: Int, undecided: Int) { review.tally }
    var applySheetForSelftest: FolderApplySheetController? { applySheet }

    func undoForSelftest() { undo.undo() }
    var canUndoForSelftest: Bool { undo.canUndo }

    func decideForSelftest(_ identifier: String, row: Int) {
        table.selectRowIndexes([row], byExtendingSelection: false)
        guard let button = decisionButtons[identifier] else { return }
        decisionChosen(button)
    }

    func simulateForSelftest() { simulateAndApply(nil) }

    func selectPairForSelftest(_ row: Int) {
        guard pairs.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
        refreshDetail()
    }

    func cellTextForSelftest(row: Int, column: String) -> String? {
        guard
            let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == column })
        else { return nil }
        let view = self.tableView(table, viewFor: tableColumn, row: row)
        return (view as? NSTableCellView)?.textField?.stringValue
    }
}

extension FolderPairWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { pairs.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, pairs.indices.contains(row) else { return nil }
        let pair = pairs[row]
        let identifier = tableColumn.identifier
        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier)
        guard let field = cell.textField else { return cell }

        switch identifier.rawValue {
        case "similarity":
            // Two decimals: 0.95 and 0.9473 are different answers and rounding both to 95% hides it.
            field.stringValue = String(format: "%.2f%%", pair.similarity * 100)
        case "a":
            field.stringValue = PathElision.relative(pair.folderA, to: scan.root)
            field.toolTip = pair.folderA
        case "b":
            field.stringValue = PathElision.relative(pair.folderB, to: scan.root)
            field.toolTip = pair.folderB
        case "matching":
            field.stringValue = "\(pair.matching)"
        case "difference":
            // The number that decides whether a pair is worth looking at: what acting on it would lose.
            let differing = pair.onlyInA.count + pair.onlyInB.count + pair.changed.count
            field.stringValue = "\(differing)"
            field.textColor = differing == 0 ? .secondaryLabelColor : .labelColor
        case "decision":
            field.textColor = .labelColor
            guard let index = pairs.firstIndex(of: pair) else {
                field.stringValue = ""
                break
            }
            switch review.decision(at: index) {
            case .decided(let keep):
                if keep.count > 1 {
                    field.stringValue = Strings.string("folders.decision.keepBoth")
                } else if keep.first == pair.folderA {
                    field.stringValue = Strings.string("folders.decision.keepA")
                } else {
                    field.stringValue = Strings.string("folders.decision.keepB")
                }
            case .skipped:
                field.stringValue = Strings.string("similar.state.skipped")
            case .undecided:
                field.stringValue = ""
            }
        default:
            field.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshDetail()
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if ["similarity", "matching", "difference"].contains(identifier.rawValue) {
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// **Quick Look asks the responder chain for permission and then for a data source.** Without these three the
/// panel opens empty, which looks exactly like a broken preview rather than like missing wiring.
extension FolderPairWindowController {
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
