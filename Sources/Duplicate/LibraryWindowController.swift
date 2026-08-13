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
final class LibraryWindowController: NSWindowController, NSToolbarItemValidation {
    private let stateDirectory: StateDirectory
    private var library: ScanLibrary
    private var rows: [ScanStore.Summary] = []
    private var sort: LibrarySort = .newest
    private var filter: String = ""

    private var watchers: [DirectoryWatcher] = []
    /// Review windows, keyed by scan id, so double-clicking the same row twice raises the window it
    /// already opened instead of starting a second review of the same scan against the same file.
    private var reviewWindows: [String: ReviewWindowController] = [:]
    private var scanPanel: ScanPanelController?
    private var folderWindows: [String: FolderPairWindowController] = [:]
    private var similarWindows: [String: SimilarPairWindowController] = [:]

    /// Which detector's scans the table is showing.
    ///
    /// One table with three sets of columns rather than three windows: they are the same question asked three
    /// ways, and separate windows would make the user go find them.
    enum LibraryKind: Int {
        case files = 0
        case folders = 1
        case similar = 2
    }

    private var showingKind: LibraryKind = .files
    private var showingFolders: Bool { showingKind == .folders }
    private var showingSimilar: Bool { showingKind == .similar }
    private var folderRows: [ScanStore.FolderSummary] = []
    private var similarRows: [ScanStore.SimilarSummary] = []
    private let kindControl = NSSegmentedControl(
        labels: [
            Strings.string("library.kind.files"), Strings.string("library.kind.folders"),
            Strings.string("library.kind.similar"),
        ],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    /// Bumped per load so a slow read that lands after a newer one is dropped.
    ///
    /// A burst of watcher fires starts several reads, and they can finish out of order -- the older one
    /// would then overwrite the newer with a stale list.
    private var loadGeneration = 0
    /// Whether a read has finished. Until it has, the empty state stays hidden: flashing "no scans yet"
    /// for a third of a second before 119 rows arrive reads as a bug.
    private var hasLoadedOnce = false
    /// A scan to select as soon as it shows up in the list.
    private var pendingSelection: String?

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
        window.minSize = NSSize(width: 720, height: 360)
        window.tabbingMode = .disallowed
        super.init(window: window)

        window.delegate = self
        buildContent()
        buildToolbar()
        rebuildColumns()
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
        tableView.doubleAction = #selector(reviewScan(_:))
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

        kindControl.selectedSegment = 0
        kindControl.target = self
        kindControl.action = #selector(kindChanged(_:))

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
            withTitle: Strings.string("library.action.review"),
            action: #selector(reviewScan(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
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
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Strings.string("library.action.delete"),
            action: #selector(deleteScan(_:)),
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

        if let wanted = pendingSelection,
            let index = rows.firstIndex(where: { $0.scanID == wanted })
        {
            pendingSelection = nil
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else if let selected, let index = rows.firstIndex(where: { $0.scanID == selected }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateFooter()
        updateEmptyState()
    }

    /// The footer counts scans, and deliberately **does not** add up their reclaimable bytes.
    ///
    /// It used to, and the number was a lie of a specific kind: scans overlap -- this library holds twenty
    /// scans of the same folder from one afternoon -- so summing them counts the same duplicate twenty
    /// times. It read "up to 422.5 GB reclaimable" over a corpus where a sample of twelve scans found 0.67%
    /// of their paths still on disk. A number nobody can act on, in the most reassuring place on screen.
    ///
    /// The per-scan figures stay: each one is about one scan and is honest about its own bounds.
    private func updateFooter() {
        if showingSimilar {
            footer.stringValue = String(
                format: Strings.string("library.footer.similar"),
                similarRows.count,
                similarRows.reduce(0) { $0 + $1.imagePairCount },
                similarRows.reduce(0) { $0 + $1.videoPairCount }
            )
            return
        }
        if showingFolders {
            footer.stringValue = String(
                format: Strings.string("library.footer.folders"),
                folderRows.count, folderRows.reduce(0) { $0 + $1.pairCount }
            )
            return
        }
        let totals = library.totals
        footer.stringValue = String(
            format: Strings.string("library.footer"), totals.scanCount, rows.count)
    }

    private func updateEmptyState() {
        if showingSimilar {
            emptyState.isHidden = !similarRows.isEmpty || !hasLoadedOnce
            if similarRows.isEmpty {
                emptyState.stringValue = Strings.string("library.empty.similar")
            }
            return
        }
        if showingFolders {
            emptyState.isHidden = !folderRows.isEmpty || !hasLoadedOnce
            if folderRows.isEmpty {
                emptyState.stringValue = Strings.string("library.empty.folders")
            }
            return
        }
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

    /// Switches between the two detectors' scans.
    ///
    /// One table with different columns rather than two windows: they are the same question asked two ways,
    /// and a second window would make the user find it.
    @objc private func kindChanged(_ sender: Any?) {
        showingKind = LibraryKind(rawValue: kindControl.selectedSegment) ?? .files
        rebuildColumns()
        loadFromDisk()
    }

    /// Rebuilds the columns for the detector being shown.
    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        let columns: [Column] =
            switch showingKind {
            case .files: Self.columns
            case .folders: Self.folderColumns
            case .similar: Self.similarColumns
            }
        for column in columns {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = Strings.string(column.titleKey)
            tableColumn.width = column.width
            tableColumn.minWidth = column.minimumWidth
            if column.isNumeric { tableColumn.headerCell.alignment = .right }
            tableView.addTableColumn(tableColumn)
        }
    }

    /// Opens the scan window, or raises the one already open.
    ///
    /// One at a time on purpose: two concurrent scans would contend for the same hash cache and the same
    /// bounded read concurrency, and the second would make the first slower for no gain.
    @objc func beginScan(_ sender: Any? = nil) {
        if let existing = scanPanel {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let panel = ScanPanelController(stateDirectory: stateDirectory)
        panel.onFolderFinished = { [weak self] _ in
            guard let self else { return }
            // Land on the detector that just produced something, or the new scan is invisible.
            self.kindControl.selectedSegment = LibraryKind.folders.rawValue
            self.kindChanged(nil)
        }
        panel.onSimilarFinished = { [weak self] _ in
            guard let self else { return }
            self.kindControl.selectedSegment = LibraryKind.similar.rawValue
            self.kindChanged(nil)
        }
        panel.onFinished = { [weak self] scan in
            // The watcher would find it anyway; this selects it so the user lands on what they just made.
            self?.loadFromDisk()
            self?.select(scanID: scan.scanID)
        }
        scanPanel = panel
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanPanel = nil }
        }
        panel.showWindow(nil)
    }

    /// Greys out the Review item when no row is selected.
    ///
    /// `NSToolbarItemValidation` rather than `validateMenuItem`: a toolbar item asks its target through this,
    /// and without it the button stays enabled and does nothing when nothing is selected.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard item.action == #selector(reviewScan(_:)) else { return true }
        return tableView.selectedRow >= 0 || tableView.clickedRow >= 0
    }

    /// Tells every open review to re-read the disk.
    ///
    /// The Sessions menu can undo a session while a review of that scan is open, and that review's rows are
    /// about files that just moved back.
    func reloadOpenReviews() {
        for controller in reviewWindows.values { controller.reloadFromDisk() }
    }

    /// Whether any open review is in the middle of an apply.
    ///
    /// Asked by `applicationShouldTerminate`: quitting halfway through would leave files half-moved and a
    /// journal that stops mid-run.
    var hasApplyInFlight: Bool {
        reviewWindows.values.contains { $0.isApplying }
    }

    /// Selects a row by scan id once it appears, since the list is read asynchronously.
    private func select(scanID: String) {
        if let index = rows.firstIndex(where: { $0.scanID == scanID }) {
            tableView.selectRowIndexes([index], byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
            return
        }
        pendingSelection = scanID
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
        let kind = showingKind
        Task.detached(priority: .userInitiated) {
            let fresh = kind == .files ? store.summaries() : []
            let freshFolders = kind == .folders ? store.folderSummaries() : []
            let freshSimilar = kind == .similar ? store.similarSummaries() : []
            await MainActor.run { [weak self] in
                guard let self, generation == self.loadGeneration else { return }
                let changed = self.library.adopt(fresh)
                let foldersChanged = self.folderRows != freshFolders
                let similarChanged = self.similarRows != freshSimilar
                self.folderRows = freshFolders
                self.similarRows = freshSimilar
                self.hasLoadedOnce = true
                if changed || foldersChanged || similarChanged {
                    self.reloadRows()
                } else {
                    // Nothing moved, but the first read still has to reveal the empty state.
                    self.updateEmptyState()
                }
            }
        }
    }

    /// Opens a review of the selected scan, or raises the one already open for it.
    ///
    /// Two windows reviewing the same scan would both write `decisions/<scan_id>.json`, and the last one
    /// to save would silently drop the other's work.
    @objc private func reviewScan(_ sender: Any?) {
        if showingFolders {
            openFolderScan()
            return
        }
        if showingSimilar {
            openSimilarScan()
            return
        }
        guard let summary = clickedSummary() else { return }
        if let existing = reviewWindows[summary.scanID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard !summary.hasRelativePaths else {
            presentRelativePathWarning(summary, bodyKey: "library.relativePaths.reviewBody")
            return
        }
        let store = ScanStore(state: stateDirectory)
        let scan: DuplicateScan
        do {
            scan = try store.loadScan(id: summary.scanID)
        } catch {
            presentLoadFailure(summary, error: error)
            return
        }
        let controller = ReviewWindowController(scan: scan, stateDirectory: stateDirectory)
        reviewWindows[summary.scanID] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviewWindows[summary.scanID] = nil }
        }
        controller.showWindow(nil)
        controller.presentImportWarningIfNeeded()
    }

    /// Opens a perceptual scan's pairs, side by side.
    private func openSimilarScan() {
        let clicked = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard similarRows.indices.contains(clicked) else { return }
        let summary = similarRows[clicked]
        if let existing = similarWindows[summary.scanID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let scan = try? ScanStore(state: stateDirectory).loadSimilarScan(id: summary.scanID)
        else { return }
        let controller = SimilarPairWindowController(scan: scan)
        similarWindows[summary.scanID] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.similarWindows[summary.scanID] = nil }
        }
        controller.showWindow(nil)
    }

    /// Opens a folder scan's pairs.
    private func openFolderScan() {
        let clicked = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard folderRows.indices.contains(clicked) else { return }
        let summary = folderRows[clicked]
        if let existing = folderWindows[summary.scanID] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let scan = try? ScanStore(state: stateDirectory).loadFolderScan(id: summary.scanID)
        else { return }
        let controller = FolderPairWindowController(scan: scan)
        folderWindows[summary.scanID] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.folderWindows[summary.scanID] = nil }
        }
        controller.showWindow(nil)
    }

    private func presentLoadFailure(_ summary: ScanStore.Summary, error: any Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
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

    /// Opens the folder a scan covered.
    ///
    /// Refuses when the scan recorded relative paths -- the CLI resolves those against its working
    /// directory, which this app does not share, and Launch Services starts the app in `/`. Guessing would
    /// reveal the wrong folder, or none.
    @objc private func revealScannedFolder(_ sender: Any?) {
        guard let summary = clickedSummary() else { return }
        guard !summary.hasRelativePaths else {
            presentRelativePathWarning(summary, bodyKey: "library.relativePaths.body")
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

    /// Removes a scan from the library.
    ///
    /// **Only the record, never the files it lists.** Says so in the sheet, because "delete" next to a list
    /// of duplicate files is a word that has to be disambiguated before it is clicked, not after.
    ///
    /// This exists because the library filled up: 119 scans from four days in May, most of them describing
    /// folders that no longer exist, with no way to clear any of them.
    @objc private func deleteScan(_ sender: Any?) {
        guard let summary = clickedSummary() else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: Strings.string("library.delete.title"), summary.scanID)
        alert.informativeText = Strings.string("library.delete.body")
        alert.addButton(withTitle: Strings.string("library.delete.confirm"))
        alert.addButton(withTitle: Strings.string("button.cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MainActor.assumeIsolated {
                _ = try? ScanStore(state: self.stateDirectory).delete(id: summary.scanID)
                self.loadFromDisk()
            }
        }
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

    private func presentRelativePathWarning(_ summary: ScanStore.Summary, bodyKey: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Strings.string("library.relativePaths.title")
        alert.informativeText = String(format: Strings.string(bodyKey), summary.root)
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
    var showingFolderScans: Bool { showingFolders }
    var folderRowCount: Int { folderRows.count }
    var showingSimilarScans: Bool { showingSimilar }
    var similarRowCount: Int { similarRows.count }

    func showSimilarScansForSelftest() {
        kindControl.selectedSegment = LibraryKind.similar.rawValue
        kindChanged(nil)
    }

    func showFolderScansForSelftest() {
        kindControl.selectedSegment = 1
        kindChanged(nil)
    }

    /// The smallest size this window's constraints allow. See the review window for why this is asserted.
    var requiredContentSize: NSSize {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.fittingSize ?? .zero
    }
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

    /// The folder detector's columns. A folder scan has no bytes to reclaim -- what it has is how alike two
    /// trees are and how much of them differs, which is what decides whether a pair is worth opening.
    private static let folderColumns: [Column] = [
        Column("root", "library.column.root", width: 300, minimum: 120),
        Column("created", "library.column.created", width: 150, minimum: 90),
        Column("threshold", "library.column.threshold", width: 100, numeric: true),
        Column("pairs", "library.column.pairs", width: 80, numeric: true),
        Column("folders", "library.column.folders", width: 90, numeric: true),
        Column("state", "library.column.state", width: 90),
    ]

    /// **The pair counts are split by kind on purpose.** This build produces no video pair at all, so one
    /// total would read as "this tree has no similar video" when it means "the app did not look".
    private static let similarColumns: [Column] = [
        Column("root", "library.column.root", width: 280, minimum: 120),
        Column("created", "library.column.created", width: 150, minimum: 90),
        Column("imagePairs", "library.column.similarPairs", width: 80, numeric: true),
        Column("videoPairs", "similar.kind.video", width: 80, numeric: true),
        Column("files", "library.column.similarFiles", width: 80, numeric: true),
        Column("threshold", "library.column.similarThreshold", width: 90, numeric: true),
        Column("state", "library.column.state", width: 90),
    ]

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
        switch showingKind {
        case .files: rows.count
        case .folders: folderRows.count
        case .similar: similarRows.count
        }
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        if showingFolders { return folderCell(column: tableColumn, row: row) }
        if showingSimilar { return similarCell(column: tableColumn, row: row) }
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

    /// One row of a perceptual scan.
    private func similarCell(column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, similarRows.indices.contains(row) else { return nil }
        let summary = similarRows[row]
        let cell =
            tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: column.identifier)
        guard let field = cell.textField else { return cell }
        field.textColor = .labelColor

        switch column.identifier.rawValue {
        case "root":
            field.stringValue = summary.root
            field.lineBreakMode = .byTruncatingHead
            field.toolTip = summary.root
        case "created":
            if let date = ScanIdentifier.date(from: summary.scanID) {
                field.stringValue = dateFormatter.string(from: date)
            } else {
                field.stringValue = summary.createdAt
            }
            field.toolTip = summary.createdAt
        case "imagePairs":
            field.stringValue = summary.imagePairCount.formatted()
        case "videoPairs":
            field.stringValue = summary.videoPairCount.formatted()
        case "files":
            field.stringValue = summary.involvedFileCount.formatted()
        case "threshold":
            // Bits out of 64, which is the unit the CLI's img_threshold is in.
            field.stringValue = String(
                format: Strings.string("library.similarThreshold.value"), summary.imageThreshold)
        case "state":
            if summary.hasRelativePaths {
                field.stringValue = Strings.string("library.state.relativePaths")
                field.textColor = .systemOrange
            } else {
                field.stringValue = ""
            }
        default:
            field.stringValue = ""
        }
        return cell
    }

    /// One row of a folder scan.
    private func folderCell(column: NSTableColumn?, row: Int) -> NSView? {
        guard let column, folderRows.indices.contains(row) else { return nil }
        let summary = folderRows[row]
        let cell =
            tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTableCellView
            ?? makeCell(identifier: column.identifier)
        guard let field = cell.textField else { return cell }

        switch column.identifier.rawValue {
        case "root":
            field.stringValue = summary.root
            field.lineBreakMode = .byTruncatingHead
            field.toolTip = summary.root
        case "created":
            if let date = ScanIdentifier.date(from: summary.scanID) {
                field.stringValue = dateFormatter.string(from: date)
            } else {
                field.stringValue = summary.createdAt
            }
        case "threshold":
            field.stringValue = String(format: "%d%%", Int(summary.threshold * 100))
        case "pairs":
            field.stringValue = summary.pairCount.formatted()
        case "folders":
            field.stringValue = summary.involvedFolderCount.formatted()
        case "state":
            field.stringValue =
                summary.hasRelativePaths ? Strings.string("library.state.relativePaths") : ""
            field.textColor = summary.hasRelativePaths ? .systemOrange : .labelColor
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
        let numeric =
            (Self.columns + Self.folderColumns).first { $0.identifier == identifier }?.isNumeric
            ?? false
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
    private static let newScanItem = NSToolbarItem.Identifier("newScan")
    private static let reviewItem = NSToolbarItem.Identifier("review")
    private static let kindItem = NSToolbarItem.Identifier("kind")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            Self.newScanItem, Self.reviewItem, Self.refreshItem, Self.kindItem, Self.sortItem,
            .flexibleSpace, .init("search"),
        ]
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
        case Self.newScanItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = Strings.string("library.toolbar.newScan")
            item.toolTip = item.label
            item.image = NSImage(
                systemSymbolName: "plus", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(beginScan(_:))
            return item
        case Self.reviewItem:
            // The other primary action of the app, and it was reachable only by double-clicking a row --
            // which nothing on screen said. Same complaint as the review's missing Simulate button.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = Strings.string("library.toolbar.review")
            item.toolTip = item.label
            item.image = NSImage(
                systemSymbolName: "checklist", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(reviewScan(_:))
            // Greyed out with no row selected, rather than opening nothing.
            item.autovalidates = true
            return item
        case Self.kindItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = Strings.string("library.toolbar.kind")
            item.view = kindControl
            return item
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
