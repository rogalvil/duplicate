import AppKit
import DuplicateCore

/// The scan library window: the app's home.
///
/// Lists every scan under the shared state directory, whichever tool wrote it, and stays current while the
/// window is open -- a `rav duplicate scan` finished in a terminal appears here without the user asking.
///
/// Deliberately not an `NSDocument` app. A scan is not the user's document: it is derived state keyed by a
/// timestamp, and `CFBundleDocumentTypes` would invite opening one by double-click and drag the whole
/// `NSDocument` architecture in for nothing.
@MainActor
final class LibraryWindowController: NSWindowController {
    private let stateDirectory: StateDirectory
    private var library: ScanLibrary
    private var rows: [ScanStore.Summary] = []
    private var sort: LibrarySort = .newest
    private var filter: String = ""

    private var watchers: [DirectoryWatcher] = []

    /// Bumped per load so a slow read that lands after a newer one is dropped.
    ///
    /// A burst of watcher fires starts several reads, and they can finish out of order -- the older one
    /// would then overwrite the newer with a stale list.
    private var loadGeneration = 0
    /// Whether a read has finished. Until it has, the empty state stays hidden: flashing "no scans yet"
    /// for a third of a second before 119 rows arrive reads as a bug.
    private var hasLoadedOnce = false

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let sortControl = NSPopUpButton()
    private let footer = NSTextField(labelWithString: "")
    private let emptyState = NSTextField(wrappingLabelWithString: "")

    /// Locale-aware, unlike the byte counts.
    ///
    /// Byte sizes are pinned to the CLI's exact strings because they are interop; a date is not written
    /// anywhere, so it should read the way the reader expects. Held rather than rebuilt per row:
    /// `DateFormatter` is expensive to create and a table asks for the same column 119 times.
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(stateDirectory: StateDirectory) {
        self.stateDirectory = stateDirectory
        // Deliberately empty: the read happens off the main thread. Measured on the real corpus,
        // decoding 119 scans takes 0.34 s, and a window that stalls before it draws is a window that
        // feels broken.
        self.library = ScanLibrary(store: ScanStore(state: stateDirectory), loadNow: false)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.string("window.library.title")
        window.center()
        window.setFrameAutosaveName("LibraryWindow")
        window.tabbingMode = .disallowed
        super.init(window: window)

        window.delegate = self
        buildContent()
        buildToolbar()
        reloadRows()
        loadFromDisk()
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this window is built in code, there is no nib")
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.style = .inset
        tableView.rowHeight = 28
        tableView.target = self
        tableView.doubleAction = #selector(revealScannedFolder(_:))
        tableView.menu = rowMenu()

        for column in Self.columns {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = Strings.string(column.titleKey)
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            if column.isNumeric {
                // Right-aligned headers over right-aligned numbers. A column of counts that is left
                // aligned cannot be compared down the page.
                tableColumn.headerCell.alignment = .right
            }
            tableView.addTableColumn(tableColumn)
        }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .secondaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        emptyState.alignment = .center
        emptyState.textColor = .secondaryLabelColor
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(footer)
        content.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            emptyState.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyState.widthAnchor.constraint(
                lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
        window.contentView = content
    }

    private func buildToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "LibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        searchField.target = self
        searchField.action = #selector(filterChanged(_:))
        searchField.sendsSearchStringImmediately = false
        searchField.placeholderString = Strings.string("library.search.placeholder")

        sortControl.target = self
        sortControl.action = #selector(sortChanged(_:))
        for option in LibrarySort.allCases {
            sortControl.addItem(withTitle: Strings.string("library.sort.\(option.rawValue)"))
        }
        sortControl.selectItem(at: 0)
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: Strings.string("library.action.revealFolder"),
            action: #selector(revealScannedFolder(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Strings.string("library.action.revealDocument"),
            action: #selector(revealScanDocument(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Strings.string("library.action.copyIdentifier"),
            action: #selector(copyIdentifier(_:)),
            keyEquivalent: ""
        )
        for item in menu.items { item.target = self }
        return menu
    }

    // MARK: - Data

    /// Re-reads the state directory and reloads the table.
    ///
    /// The selection is restored by scan id rather than by row index: a scan appearing above the selected
    /// one shifts every index below it, so reapplying the index would silently move the selection to a
    /// different scan.
    private func reloadRows() {
        let selected =
            tableView.selectedRow >= 0 && tableView.selectedRow < rows.count
            ? rows[tableView.selectedRow].scanID
            : nil

        rows = library.rows(sortedBy: sort, filter: filter)
        tableView.reloadData()

        if let selected, let index = rows.firstIndex(where: { $0.scanID == selected }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateFooter()
        updateEmptyState()
    }

    private func updateFooter() {
        let totals = library.totals
        let size = ByteSize.format(totals.reclaimableBytes)
        let key = totals.isReclaimExact ? "library.footer" : "library.footer.upperBound"
        footer.stringValue = String(
            format: Strings.string(key),
            totals.scanCount, totals.groupCount, totals.fileCount, size
        )
    }

    private func updateEmptyState() {
        emptyState.isHidden = !rows.isEmpty || !hasLoadedOnce
        guard rows.isEmpty else { return }
        emptyState.stringValue =
            library.summaries.isEmpty
            ? String(
                format: Strings.string("library.empty"), stateDirectory.path(for: .scans))
            : Strings.string("library.empty.filtered")
    }

    // MARK: - Watching

    /// Watches the two directories whose contents change what this window shows.
    ///
    /// Both, not just `scans/`: a decisions document appearing beside a scan changes its badge, and that is
    /// how the user sees that a review they did in the CLI landed.
    ///
    /// **The known gap**: a directory watch reports entries, not contents, so the CLI re-saving an
    /// existing decisions document in place fires nothing. That leaves no row wrong -- the badge tracks
    /// existence -- but a window that showed decision *counts* would need more than this.
    private func startWatching() {
        for slot in [StateDirectory.Slot.scans, .decisions] {
            // Created if absent: a watch cannot be placed on a directory that does not exist, and a
            // first-run app with no scans yet is the normal case. `create` is `mkdir -p`, which the CLI
            // does too.
            _ = try? stateDirectory.create(slot)
            let watcher = DirectoryWatcher(path: stateDirectory.path(for: slot)) { [weak self] in
                // The callback arrives on the watcher's own queue. Hopping to the main actor only to
                // schedule the read, never to perform it.
                Task { @MainActor [weak self] in
                    self?.loadFromDisk()
                }
            }
            if watcher.start() {
                watchers.append(watcher)
            } else {
                Log.app.error("could not watch \(slot.rawValue, privacy: .public)")
            }
        }
    }

    private func stopWatching() {
        for watcher in watchers { watcher.stop() }
        watchers.removeAll()
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: NSSearchField) {
        filter = sender.stringValue
        reloadRows()
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard LibrarySort.allCases.indices.contains(index) else { return }
        sort = LibrarySort.allCases[index]
        reloadRows()
    }

    @objc private func refreshNow(_ sender: Any?) {
        loadFromDisk()
    }

    /// Reads the state directory off the main thread and adopts the result.
    ///
    /// `ScanStore.summaries()` decodes every group of every scan -- 21,594 groups and 71,580 paths on this
    /// user's corpus -- to produce a handful of counts. That is 0.34 s of work, measured, and it happens
    /// again on every watcher fire. On the main thread it would stall the window on open and stutter it
    /// whenever the CLI writes anything.
    ///
    /// The generation guard drops a read that lands after a newer one: a burst of watcher fires starts
    /// several, and finishing out of order would leave the older list on screen.
    private func loadFromDisk() {
        loadGeneration += 1
        let generation = loadGeneration
        let store = ScanStore(state: stateDirectory)
        Task.detached(priority: .userInitiated) {
            let fresh = store.summaries()
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                let changed = self.library.adopt(fresh)
                self.hasLoadedOnce = true
                if changed {
                    self.reloadRows()
                } else {
                    // Nothing moved, but the first read still has to reveal the empty state.
                    self.updateEmptyState()
                }
            }
        }
    }

    /// Opens the folder a scan covered.
    ///
    /// Refuses when the scan recorded relative paths -- the CLI resolves those against its working
    /// directory, which this app does not share, and Launch Services starts the app in `/`. Guessing would
    /// reveal the wrong folder, or none.
    @objc private func revealScannedFolder(_ sender: Any?) {
        guard let summary = clickedSummary() else { return }
        guard !summary.hasRelativePaths else {
            presentRelativePathWarning(summary)
            return
        }
        Reveal.folder(at: summary.root)
    }

    @objc private func revealScanDocument(_ sender: Any?) {
        guard let summary = clickedSummary(),
            let path = try? stateDirectory.filePath(for: .scans, id: summary.scanID)
        else { return }
        Reveal.item(at: path)
    }

    @objc private func copyIdentifier(_ sender: Any?) {
        guard let summary = clickedSummary() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.scanID, forType: .string)
    }

    /// The row the menu or double-click was aimed at, which is not always the selected row.
    private func clickedSummary() -> ScanStore.Summary? {
        let clicked = tableView.clickedRow
        let index = clicked >= 0 ? clicked : tableView.selectedRow
        guard rows.indices.contains(index) else { return nil }
        return rows[index]
    }

    private func presentRelativePathWarning(_ summary: ScanStore.Summary) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("library.relativePaths.title")
        alert.informativeText = String(
            format: Strings.string("library.relativePaths.body"), summary.root)
        alert.addButton(withTitle: Strings.string("button.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    // MARK: - Selftest hooks

    /// Reads back what the table is showing, through the production data source.
    ///
    /// Internal so `--selftest --mode library` can assert on the real rendering path rather than on a
    /// second copy of the formatting rules. Every value here is produced by the same
    /// `tableView(_:viewFor:row:)` the window draws with.
    var displayedRowCount: Int { rows.count }

    func displayedValue(row: Int, column: String) -> String? {
        guard rows.indices.contains(row),
            let tableColumn = tableView.tableColumns.first(where: {
                $0.identifier.rawValue == column
            })
        else { return nil }
        let view = self.tableView(tableView, viewFor: tableColumn, row: row)
        return (view as? NSTableCellView)?.textField?.stringValue
    }

    var footerText: String { footer.stringValue }
    var emptyStateText: String? { emptyState.isHidden ? nil : emptyState.stringValue }
    var watcherCount: Int { watchers.count }
    var hasFinishedFirstLoad: Bool { hasLoadedOnce }

    /// Drives the sort control and the search field the way a click would.
    func applyForSelftest(sort: LibrarySort, filter: String) {
        self.sort = sort
        self.filter = filter
        reloadRows()
    }

    // MARK: - Columns

    private struct Column {
        let identifier: NSUserInterfaceItemIdentifier
        let titleKey: String
        let width: CGFloat
        let minimumWidth: CGFloat
        let isNumeric: Bool

        init(
            _ name: String, _ titleKey: String, width: CGFloat, minimum: CGFloat = 50,
            numeric: Bool = false
        ) {
            self.identifier = NSUserInterfaceItemIdentifier(name)
            self.titleKey = titleKey
            self.width = width
            self.minimumWidth = minimum
            self.isNumeric = numeric
        }
    }

    private static let columns: [Column] = [
        Column("root", "library.column.root", width: 320, minimum: 120),
        Column("created", "library.column.created", width: 150, minimum: 90),
        Column("groups", "library.column.groups", width: 80, numeric: true),
        Column("files", "library.column.files", width: 80, numeric: true),
        Column("reclaim", "library.column.reclaimable", width: 110, numeric: true),
        Column("state", "library.column.state", width: 90),
    ]
}

// MARK: - Table data

extension LibraryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let summary = rows[row]
        let identifier = tableColumn.identifier

        let cell =
            tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: identifier)
        guard let field = cell.textField else { return cell }

        switch identifier.rawValue {
        case "root":
            field.stringValue = summary.root
            // Head truncation: the tail of a path is the part that identifies it, and a column of
            // `/Volumes/WD12TB/Tmp/…` truncated at the end is a column of identical cells.
            field.lineBreakMode = .byTruncatingHead
            field.toolTip = summary.root
        case "created":
            if let date = ScanIdentifier.date(from: summary.scanID) {
                field.stringValue = dateFormatter.string(from: date)
            } else {
                field.stringValue = summary.createdAt
            }
            field.toolTip = summary.createdAt
        case "groups":
            field.stringValue = summary.groupCount.formatted()
        case "files":
            field.stringValue = summary.fileCount.formatted()
        case "reclaim":
            let size = ByteSize.format(summary.reclaimableBytes)
            // A figure that counts files rather than storage classes is an upper bound, and saying so
            // costs one character. A tool caught overstating reclaimable space is not believed about
            // anything else either.
            field.stringValue = summary.isReclaimExact ? size : "≤ " + size
            field.toolTip =
                summary.isReclaimExact
                ? nil : Strings.string("library.reclaimable.upperBound.tooltip")
        case "state":
            field.stringValue =
                summary.hasDecisions ? Strings.string("library.state.reviewed") : ""
            if summary.hasRelativePaths {
                field.stringValue = Strings.string("library.state.relativePaths")
                field.textColor = .systemOrange
            } else {
                field.textColor = .labelColor
            }
        default:
            field.stringValue = ""
        }
        return cell
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        let numeric = Self.columns.first { $0.identifier == identifier }?.isNumeric ?? false
        if numeric {
            field.alignment = .right
            // Monospaced digits, because a proportional numeral in a column of counts makes the digits
            // fail to line up and the column impossible to scan.
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Toolbar

extension LibraryWindowController: NSToolbarDelegate {
    private static let sortItem = NSToolbarItem.Identifier("sort")
    private static let refreshItem = NSToolbarItem.Identifier("refresh")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.refreshItem, Self.sortItem, .flexibleSpace, .init("search")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.refreshItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = Strings.string("library.toolbar.refresh")
            item.toolTip = item.label
            item.image = NSImage(
                systemSymbolName: "arrow.clockwise",
                accessibilityDescription: item.label
            )
            item.target = self
            item.action = #selector(refreshNow(_:))
            return item
        case Self.sortItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = Strings.string("library.toolbar.sort")
            item.view = sortControl
            return item
        case .init("search"):
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            item.label = Strings.string("library.toolbar.search")
            return item
        default:
            return nil
        }
    }
}

// MARK: - Window lifecycle

extension LibraryWindowController: NSWindowDelegate {
    /// Stops the watchers when the window closes.
    ///
    /// Two open descriptors and a Dispatch source for a window nobody is looking at is not free, and the
    /// callback would reach a controller on its way out.
    func windowWillClose(_ notification: Notification) {
        stopWatching()
    }
}
