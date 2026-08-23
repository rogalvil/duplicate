import AppKit
import DuplicateCore

/// Lists every apply this app has performed, and lets any of them be undone.
///
/// **The window that makes an existing capability reachable.** `UndoCoordinator.undo(sessionID:in:)` has always
/// taken an arbitrary session, but the only way to call it was "undo the last one" -- so applying twice and
/// wanting the first one back had no path through the app. Nothing needed to be built to make it possible; only
/// something to name the sessions.
///
/// **No keyboard equivalent on the undo, here or in the menu.** The plan's reasoning stands: Command-Z means
/// "what I just typed" in every other Mac app, and a session undo moves files. It is a button with a
/// confirmation, reached deliberately.
@MainActor
final class SessionHistoryWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuItemValidation
{
    private let stateDirectory: StateDirectory
    private var rows: [SessionHistory.Row] = []
    private let table = NSTableView()
    private let footerLabel = NSTextField(labelWithString: "")
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private let pruneButton = NSButton(title: "", target: nil, action: nil)

    /// Locale-aware: a date is read by a person, not compared across tools.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(stateDirectory: StateDirectory) {
        self.stateDirectory = stateDirectory
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.string("history.window.title")
        // A floor, not a hope: dragged below what the layout needs, AutoLayout starts breaking constraints and
        // the table's columns collapse into each other.
        window.minSize = NSSize(width: 520, height: 260)
        super.init(window: window)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not from a nib")
    }

    private func build() {
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        for (name, key, width) in [
            ("when", "history.column.when", CGFloat(170)),
            ("files", "history.column.files", CGFloat(96)),
            ("bytes", "history.column.bytes", CGFloat(90)),
            ("state", "history.column.state", CGFloat(160)),
            ("scan", "history.column.scan", CGFloat(160)),
        ] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = Strings.string(key)
            column.width = width
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // A scroll view exists to be narrower than its content: without this the table's summed column widths
        // become the window's minimum, which is the bug that once put a 718-point floor under a review window.
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        undoButton.title = Strings.string("history.button.undo")
        undoButton.bezelStyle = .rounded
        undoButton.target = self
        undoButton.action = #selector(undoSelectedSession(_:))
        undoButton.isEnabled = false
        pruneButton.title = Strings.string("history.button.prune")
        pruneButton.bezelStyle = .rounded
        pruneButton.target = self
        pruneButton.action = #selector(pruneFromHistory(_:))

        footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [footerLabel, pruneButton, undoButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let content = NSStackView(views: [scroll, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        content.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: host.topAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32),
        ])
        window?.contentView = host
    }

    /// Re-reads the journals.
    ///
    /// Called after an undo and after a prune, because both change what every row says -- and a list that still
    /// claims a session has four files to restore after they came back is worse than no list.
    func reload() {
        rows = SessionHistory.rows(in: stateDirectory)
        table.reloadData()
        refreshFooter()
        refreshButtons()
    }

    private func refreshFooter() {
        let moved = rows.reduce(0) { $0 + $1.movedCount }
        let bytes = rows.reduce(Int64(0)) { $0 + $1.movedBytes }
        let restored = rows.reduce(0) { $0 + $1.restoredCount }
        footerLabel.stringValue = String(
            format: Strings.string("history.footer"),
            rows.count, moved, ByteSize.format(bytes), restored
        )
    }

    private func refreshButtons() {
        let row = table.selectedRow
        undoButton.isEnabled = rows.indices.contains(row) && rows[row].hasWorkLeft
        pruneButton.isEnabled = rows.contains(where: \.isFullyRestored)
    }

    // MARK: - Actions

    /// Undoes whichever session is selected, not just the last one.
    @objc func undoSelectedSession(_ sender: Any?) {
        let index = table.selectedRow
        guard rows.indices.contains(index), rows[index].hasWorkLeft else { return }
        let row = rows[index]

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = Strings.string("history.undo.title")
        confirm.informativeText = String(
            format: Strings.string("history.undo.body"),
            row.movedCount - row.restoredCount, ByteSize.format(row.movedBytes)
        )
        confirm.addButton(withTitle: Strings.string("history.undo.confirm"))
        confirm.addButton(withTitle: Strings.string("button.cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let outcome = UndoCoordinator.undo(sessionID: row.sessionID, in: stateDirectory)
        let done = NSAlert()
        done.alertStyle = .informational
        done.messageText = outcome.summary
        done.informativeText = outcome.detail
        done.addButton(withTitle: Strings.string("button.close"))
        done.runModal()
        reload()
        // **A review window open at the same time keeps its last disk check.** Refreshing it from here would
        // mean starting a check that stats every file in the scan -- work the user did not ask for, behind their
        // back, because they undid something in another window. A stale label they can refresh with one button
        // is the smaller wrong.
    }

    @objc func pruneFromHistory(_ sender: Any?) {
        NSApp.sendAction(#selector(AppDelegate.pruneUndoneSessions(_:)), to: nil, from: self)
        reload()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(undoSelectedSession(_:)) {
            let row = table.selectedRow
            return rows.indices.contains(row) && rows[row].hasWorkLeft
        }
        return true
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(
        _ tableView: NSTableView, objectValueFor column: NSTableColumn?, row index: Int
    ) -> Any? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        switch column?.identifier.rawValue {
        case "when":
            return dateFormatter.string(from: sessionDate(row))
        case "files":
            return String(row.movedCount)
        case "bytes":
            return ByteSize.format(row.movedBytes)
        case "state":
            if row.isUnreadable { return Strings.string("history.state.unreadable") }
            if row.movedCount == 0 { return Strings.string("history.state.empty") }
            if row.isFullyRestored { return Strings.string("history.state.restored") }
            if row.restoredCount == 0 { return Strings.string("history.state.moved") }
            return String(
                format: Strings.string("history.state.partial"), row.restoredCount, row.movedCount)
        case "scan":
            // Several scans in one session is possible and rare; naming the first and counting the rest beats
            // a cell that lists three identifiers nobody can read.
            guard let first = row.scanIDs.first else { return "" }
            return row.scanIDs.count == 1
                ? first
                : String(
                    format: Strings.string("history.scan.several"), first, row.scanIDs.count - 1)
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshButtons()
    }

    /// The session's instant, from its identifier.
    ///
    /// The identifier is the timestamp, so this needs no journal read -- and it is what orders the list. Falls
    /// back to the first entry's own timestamp, then to the epoch, because a row with no date is still a row
    /// worth showing.
    private func sessionDate(_ row: SessionHistory.Row) -> Date {
        if let date = ScanIdentifier.date(from: row.sessionID) { return date }
        if let date = ScanIdentifier.date(fromTimestamp: row.firstTimestamp) { return date }
        return Date(timeIntervalSince1970: 0)
    }

    // MARK: - Selftest hooks

    var rowCountForSelftest: Int { rows.count }
    var footerForSelftest: String { footerLabel.stringValue }
    var canUndoSelectionForSelftest: Bool { undoButton.isEnabled }
    var canPruneForSelftest: Bool { pruneButton.isEnabled }

    func selectForSelftest(_ index: Int) {
        table.selectRowIndexes([index], byExtendingSelection: false)
        refreshButtons()
    }

    func cellForSelftest(row: Int, column: String) -> String {
        let identifier = NSTableColumn(identifier: .init(column))
        return (tableView(table, objectValueFor: identifier, row: row) as? String) ?? ""
    }

    /// Runs the undo without the confirmation sheet, which is what a harness can drive.
    func undoForSelftest(_ index: Int) -> UndoCoordinator.Outcome? {
        guard rows.indices.contains(index), rows[index].hasWorkLeft else { return nil }
        let outcome = UndoCoordinator.undo(sessionID: rows[index].sessionID, in: stateDirectory)
        reload()
        return outcome
    }
}
