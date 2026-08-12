import AppKit
import DuplicateCore

/// A table that answers to the keys a file list should answer to.
///
/// Space and Return are handled here rather than as menu key equivalents because **a menu key equivalent
/// is global**: Return as a shortcut would fire while the user is typing in the library's search field.
/// Here they mean something only because a list of files has focus.
final class ReviewTableView: NSTableView {
    /// Called for the space bar: toggle whether the row under the cursor is kept.
    var onToggle: (() -> Void)?
    /// Called for Return: accept the group and move on.
    var onConfirm: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " " where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
            onToggle?()
        case "\r",
            "\u{3}" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
            onConfirm?()
        default:
            super.keyDown(with: event)
        }
    }
}

/// Reviews one scan: which file in each group survives.
///
/// **The window that has to be honest about three things**, each of which is a way a duplicate finder
/// loses a user's trust for good:
///
/// 1. A group nobody looked at is not a decision. The heuristic's guess is shown greyed out as a
///    *preview*; closing the window records nothing for it. The CLI writes a decision for every group
///    including the unseen ones, so quitting after group 1 of 50 records 49 -- in a terminal that takes a
///    deliberate `q`, in a window it takes closing the window.
/// 2. A file that shares storage with the keeper frees nothing, and is never offered for removal.
/// 3. A figure the scan cannot know exactly is labelled, not rounded off to a confident number.
@MainActor
final class ReviewWindowController: NSWindowController, NSMenuItemValidation {
    private let stateDirectory: StateDirectory
    private let store: ScanStore
    private var state: ExactReviewState
    private var flow: ReviewFlow
    /// What was on disk when the window opened, so closing can tell whether anything needs saving.
    private var savedDecisions: [(key: String, keptPaths: [String])]

    private let groupTable = NSTableView()
    private let fileTable = ReviewTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let subheaderLabel = NSTextField(labelWithString: "")
    private let tallyLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")

    private let undo = UndoManager()

    init(scan: DuplicateScan, stateDirectory: StateDirectory) {
        self.stateDirectory = stateDirectory
        let store = ScanStore(state: stateDirectory)
        self.store = store
        let prior = store.priorDecisions(scanID: scan.scanID)
        self.state = ExactReviewState(scan: scan, root: scan.root, priorDecisions: prior)
        self.flow = ReviewFlow(step: .scanned, hasDecisions: !prior.isEmpty)
        self.savedDecisions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(
            format: Strings.string("review.window.title"),
            PathElision.elide(scan.root, leading: 1, trailing: 2)
        )
        window.center()
        // Per scan, so reviewing two scans does not make them fight over one saved frame.
        window.setFrameAutosaveName("ReviewWindow")
        super.init(window: window)

        window.delegate = self
        self.savedDecisions = state.decisionsForSaving
        buildContent()
        selectGroup(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this window is built in code, there is no nib")
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        groupTable.dataSource = self
        groupTable.delegate = self
        groupTable.headerView = nil
        groupTable.style = .sourceList
        groupTable.rowHeight = 34
        groupTable.allowsEmptySelection = false
        let groupColumn = NSTableColumn(identifier: .init("group"))
        groupColumn.width = 210
        groupTable.addTableColumn(groupColumn)

        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.rowHeight = 26
        fileTable.usesAlternatingRowBackgroundColors = true
        fileTable.allowsEmptySelection = false
        fileTable.onToggle = { [weak self] in self?.toggleSelectedFile() }
        fileTable.onConfirm = { [weak self] in self?.confirmGroup(nil) }
        fileTable.target = self
        fileTable.doubleAction = #selector(revealSelectedFile(_:))
        for (name, key, width) in [
            ("keep", "review.column.keep", CGFloat(46)),
            ("file", "review.column.file", CGFloat(430)),
            ("note", "review.column.note", CGFloat(210)),
        ] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = Strings.string(key)
            column.width = width
            fileTable.addTableColumn(column)
        }

        let groupScroll = NSScrollView()
        groupScroll.documentView = groupTable
        groupScroll.hasVerticalScroller = true
        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingHead
        subheaderLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subheaderLabel.textColor = .secondaryLabelColor
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        tallyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tallyLabel.textColor = .secondaryLabelColor

        let detail = NSStackView(views: [headerLabel, subheaderLabel, warningLabel, fileScroll])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 4
        detail.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 6, right: 14)
        fileScroll.translatesAutoresizingMaskIntoConstraints = false
        detail.setHuggingPriority(.defaultLow, for: .horizontal)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(groupScroll)
        split.addArrangedSubview(detail)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(split)
        content.addSubview(tallyLabel)
        tallyLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: tallyLabel.topAnchor, constant: -6),
            tallyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            tallyLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
            fileScroll.widthAnchor.constraint(
                greaterThanOrEqualTo: detail.widthAnchor, constant: -28),
            fileScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
        ])
        window.contentView = content
        groupScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    }

    // MARK: - Presentation

    /// The group being reviewed, as values Core worked out.
    private var presentation: GroupPresentation? {
        guard let group = state.currentGroup else { return nil }
        return GroupPresentation(
            group: group,
            keep: state.effectiveKeep(at: state.groupIndex),
            decision: state.decision(at: state.groupIndex),
            root: state.root
        )
    }

    private func refreshDetail() {
        guard let presentation else { return }
        headerLabel.stringValue =
            presentation.commonParent ?? Strings.string("review.header.noCommonParent")
        headerLabel.toolTip = presentation.commonParent

        let size = ByteSize.format(presentation.size)
        let freed = ByteSize.format(presentation.reclaimableBytes)
        subheaderLabel.stringValue = String(
            format: Strings.string(
                presentation.isReclaimExact ? "review.subheader" : "review.subheader.upperBound"),
            state.groupIndex + 1, state.groupCount, size, presentation.rows.count, freed
        )

        // The one warning the CLI's own UX document specified and never implemented.
        if presentation.keptCount == 0, presentation.decision != .discardAll {
            warningLabel.stringValue = Strings.string("review.warning.keepNothing")
        } else if presentation.hasSharedStorage {
            warningLabel.stringValue = Strings.string("review.warning.sharedStorage")
        } else if presentation.decision == .undecided {
            warningLabel.stringValue = Strings.string("review.warning.preview")
        } else {
            warningLabel.stringValue = ""
        }

        let tally = state.tally
        tallyLabel.stringValue = String(
            format: Strings.string("review.tally"),
            tally.decided, tally.skipped, tally.undecided,
            ByteSize.format(state.plannedReclaimBytes)
        )
        fileTable.reloadData()
        groupTable.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<state.groupCount),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func selectGroup(_ index: Int) {
        state.go(to: index)
        if groupTable.selectedRow != index, state.scan.groups.indices.contains(index) {
            groupTable.selectRowIndexes([index], byExtendingSelection: false)
            groupTable.scrollRowToVisible(index)
        }
        if !presentationRowsEmpty { fileTable.selectRowIndexes([0], byExtendingSelection: false) }
        refreshDetail()
    }

    private var presentationRowsEmpty: Bool { (presentation?.rows.isEmpty ?? true) }

    // MARK: - Editing

    /// Applies a mutation and registers its inverse with the undo manager.
    ///
    /// The whole decision map is captured rather than a delta. It is a dictionary of small enums over at
    /// most a few thousand groups, so a snapshot costs less than the bookkeeping a delta would need -- and
    /// an undo that restores a snapshot cannot drift from the forward operation.
    private func mutate(_ body: (inout ExactReviewState) -> Void) {
        let before = state
        body(&state)
        undo.registerUndo(withTarget: self) { controller in
            controller.mutate { $0 = before }
        }
        flow.decisionsChanged(hasAny: !state.decisionsForSaving.isEmpty)
        selectGroup(state.groupIndex)
    }

    private func toggleSelectedFile() {
        let row = fileTable.selectedRow
        guard row >= 0 else { return }
        var accepted = true
        mutate { state in
            state.go(to: state.groupIndex)
            // The cursor lives in Core so the refusal rule is Core's: a group must keep at least one file.
            while state.fileIndex > row { state.moveCursor(by: -1) }
            while state.fileIndex < row { state.moveCursor(by: 1) }
            accepted = state.toggleCursor()
        }
        fileTable.selectRowIndexes([row], byExtendingSelection: false)
        if !accepted { NSSound.beep() }
    }

    // MARK: - Actions

    @objc func confirmGroup(_ sender: Any?) {
        var outcome: ConfirmOutcome = .advanced
        mutate { outcome = $0.confirm() }
        switch outcome {
        case .rejectedNoKeep:
            // **Not an exit.** The CLI's TUI reads this same condition as "we are done" and quits the
            // review, so pressing Return with nothing checked loses the session.
            NSSound.beep()
            warningLabel.stringValue = Strings.string("review.warning.keepNothing")
        case .finished:
            warningLabel.stringValue = Strings.string("review.warning.lastGroup")
        case .advanced:
            break
        }
    }

    @objc func skipGroup(_ sender: Any?) {
        mutate { _ = $0.skip() }
    }

    @objc func clearDecision(_ sender: Any?) {
        mutate { $0.clearDecision() }
    }

    @objc func keepAll(_ sender: Any?) {
        mutate { $0.keepAll() }
    }

    /// Removes every copy in the group.
    ///
    /// Named for what it does, asked for once, and reachable only from the menu. The CLI calls this
    /// "Mover todos" and then skips the group at apply time because its keep list is empty -- a labelled
    /// destructive action that silently does nothing.
    @objc func discardEntireGroup(_ sender: Any?) {
        guard let presentation, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("review.discardAll.title")
        alert.informativeText = String(
            format: Strings.string("review.discardAll.body"),
            presentation.rows.count,
            ByteSize.format(presentation.size * Int64(presentation.distinctCopies))
        )
        alert.addButton(withTitle: Strings.string("review.discardAll.confirm"))
        alert.addButton(withTitle: Strings.string("button.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.mutate { $0.discardEntireGroup() }
        }
    }

    @objc func previousGroup(_ sender: Any?) {
        guard state.groupIndex > 0 else { return }
        selectGroup(state.groupIndex - 1)
    }

    @objc func nextGroup(_ sender: Any?) {
        guard state.groupIndex + 1 < state.groupCount else { return }
        selectGroup(state.groupIndex + 1)
    }

    @objc func revealSelectedFile(_ sender: Any?) {
        guard let presentation else { return }
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        guard presentation.rows.indices.contains(row) else { return }
        Reveal.item(at: presentation.rows[row].path)
    }

    /// Writes the decisions, and **only the groups the user decided**.
    ///
    /// The absence of a key is the contract that makes a partial review safe in both tools: the CLI's
    /// `_apply_decisions` only overrides keys that are present and `decision_candidates` skips absent
    /// ones, so a file written here makes even the CLI act on exactly the reviewed groups.
    @objc func saveDecisions(_ sender: Any?) {
        let decisions = state.decisionsForSaving
        guard !decisions.isEmpty else {
            // Nothing decided: writing an empty document would replace a real one from an earlier session.
            savedDecisions = decisions
            return
        }
        do {
            let document = DecisionsCodec.document(
                from: state,
                instant: ScanIdentifier.Instant(Date())
            )
            try store.save(document)
            savedDecisions = decisions
            flow.hasDecisions = true
        } catch {
            presentSaveFailure(error)
        }
    }

    private func presentSaveFailure(_ error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = Strings.string("review.saveFailed.title")
        alert.informativeText = String(
            format: Strings.string("review.saveFailed.body"), String(describing: error))
        alert.addButton(withTitle: Strings.string("button.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private var hasUnsavedChanges: Bool {
        let current = state.decisionsForSaving
        guard current.count == savedDecisions.count else { return true }
        for (mine, theirs) in zip(current, savedDecisions) {
            if mine.key != theirs.key || mine.keptPaths != theirs.keptPaths { return true }
        }
        return false
    }

    // MARK: - Menu state

    /// Greys out what does not apply, so the menu describes the situation instead of beeping at the user.
    ///
    /// From `NSMenuItemValidation`, not an override: `NSWindowController` does not declare it, and writing
    /// `override` there is a compile error that reads as if the method were wrong.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(previousGroup(_:)):
            return state.groupIndex > 0
        case #selector(nextGroup(_:)):
            return state.groupIndex + 1 < state.groupCount
        case #selector(clearDecision(_:)):
            return state.decision(at: state.groupIndex) != .undecided
        case #selector(saveDecisions(_:)):
            return hasUnsavedChanges && !state.decisionsForSaving.isEmpty
        case #selector(revealSelectedFile(_:)):
            return fileTable.selectedRow >= 0
        default:
            return true
        }
    }

    // MARK: - Selftest hooks

    var reviewState: ExactReviewState { state }
    var reviewFlow: ReviewFlow { flow }
    var currentPresentation: GroupPresentation? { presentation }
    var headerText: String { headerLabel.stringValue }
    var subheaderText: String { subheaderLabel.stringValue }
    var warningText: String { warningLabel.stringValue }
    var tallyText: String { tallyLabel.stringValue }
    var groupRowCount: Int { groupTable.numberOfRows }
    var fileRowCount: Int { fileTable.numberOfRows }
    var canUndoReview: Bool { undo.canUndo }
    var hasUnsavedReviewChanges: Bool { hasUnsavedChanges }

    func selectFileForSelftest(_ row: Int) {
        fileTable.selectRowIndexes([row], byExtendingSelection: false)
    }

    func toggleForSelftest() { toggleSelectedFile() }
    func undoForSelftest() { undo.undo() }
    func selectGroupForSelftest(_ index: Int) { selectGroup(index) }

    func fileCellText(row: Int, column: String) -> String? {
        guard
            let tableColumn = fileTable.tableColumns.first(where: {
                $0.identifier.rawValue == column
            })
        else { return nil }
        let view = self.tableView(fileTable, viewFor: tableColumn, row: row)
        if let cell = view as? NSTableCellView { return cell.textField?.stringValue }
        if let button = view as? NSButton { return button.state == .on ? "on" : "off" }
        return nil
    }
}

// MARK: - Tables

extension ReviewWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === groupTable ? state.groupCount : (presentation?.rows.count ?? 0)
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        tableView === groupTable
            ? groupCell(row: row)
            : fileCell(column: tableColumn?.identifier.rawValue ?? "", row: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table === groupTable else { return }
        let row = groupTable.selectedRow
        guard row >= 0, row != state.groupIndex else { return }
        selectGroup(row)
    }

    private func groupCell(row: Int) -> NSView? {
        guard state.scan.groups.indices.contains(row) else { return nil }
        let group = state.scan.groups[row]
        let cell =
            groupTable.makeView(withIdentifier: .init("group"), owner: self) as? NSTableCellView
            ?? makeLabelCell(.init("group"))
        // Symbol, not a word: this cell is 210 points wide and holds a path already.
        let mark: String
        switch state.decision(at: row) {
        case .decided: mark = "\u{2713} "
        case .discardAll: mark = "\u{2717} "
        case .skipped: mark = "\u{2192} "
        case .undecided: mark = ""
        }
        cell.textField?.stringValue =
            mark
            + String(
                format: Strings.string("review.group.row"), row + 1,
                ByteSize.format(group.size), group.files.count)
        cell.textField?.textColor =
            state.decision(at: row).isActionable ? .labelColor : .secondaryLabelColor
        return cell
    }

    private func fileCell(column: String, row: Int) -> NSView? {
        guard let presentation, presentation.rows.indices.contains(row) else { return nil }
        let item = presentation.rows[row]

        if column == "keep" {
            let button =
                fileTable.makeView(withIdentifier: .init("keep"), owner: self) as? NSButton
                ?? {
                    let created = NSButton(
                        checkboxWithTitle: "", target: self,
                        action: #selector(keepCheckboxToggled(_:)))
                    created.identifier = .init("keep")
                    return created
                }()
            button.state = item.isKept ? .on : .off
            button.tag = row
            // A file that shares the keeper's storage cannot be removed, so its checkbox is not a choice.
            button.isEnabled = !item.sharesStorageWithKeeper
            return button
        }

        let cell =
            fileTable.makeView(withIdentifier: .init(column), owner: self) as? NSTableCellView
            ?? makeLabelCell(.init(column))
        switch column {
        case "file":
            cell.textField?.stringValue = item.displayPath
            cell.textField?.lineBreakMode = .byTruncatingHead
            cell.textField?.toolTip = item.path
            cell.textField?.textColor = item.isKept ? .labelColor : .secondaryLabelColor
        case "note":
            var notes: [String] = []
            if item.sharesStorageWithKeeper {
                notes.append(Strings.string("review.note.sameStorage"))
            }
            if item.looksLikeCopy { notes.append(Strings.string("review.note.copyName")) }
            cell.textField?.stringValue = notes.joined(separator: " \u{00B7} ")
            cell.textField?.textColor =
                item.sharesStorageWithKeeper ? .systemOrange : .secondaryLabelColor
        default:
            cell.textField?.stringValue = ""
        }
        return cell
    }

    @objc private func keepCheckboxToggled(_ sender: NSButton) {
        fileTable.selectRowIndexes([sender.tag], byExtendingSelection: false)
        toggleSelectedFile()
    }

    private func makeLabelCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
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

// MARK: - Window lifecycle

extension ReviewWindowController: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        undo
    }

    /// Asks before losing a review.
    ///
    /// **Closing a window is not quitting an app**, and the CLI's equivalent of this moment is a
    /// deliberate `q`. Discarding a review silently because a window closed would be the same class of
    /// mistake as writing decisions for groups nobody looked at.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnsavedChanges, !state.decisionsForSaving.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = Strings.string("review.unsaved.title")
        alert.informativeText = String(
            format: Strings.string("review.unsaved.body"), state.tally.decided)
        alert.addButton(withTitle: Strings.string("review.unsaved.save"))
        alert.addButton(withTitle: Strings.string("button.cancel"))
        alert.addButton(withTitle: Strings.string("review.unsaved.discard"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveDecisions(nil)
                sender.close()
            case .alertThirdButtonReturn:
                self.savedDecisions = self.state.decisionsForSaving
                sender.close()
            default:
                break
            }
        }
        return false
    }
}
