import AppKit
import DuplicateCore
@preconcurrency import Quartz

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
    private let quickLook = QuickLookCoordinator()
    private let headerLabel = NSTextField(labelWithString: "")
    private let subheaderLabel = NSTextField(labelWithString: "")
    private let tallyLabel = NSTextField(labelWithString: "")
    /// **The** action of the window, in the footer where the tally already draws the eye.
    ///
    /// One button, not two. A footer with "Save Decisions" beside "Simulate and Apply" reads as two ways to
    /// commit the same work, and invites the question "do I have to save before applying?" -- to which the
    /// answer is no, and a UI that raises a question it then answers with "no" is a UI with a spare button.
    /// Reported as unintuitive from real use, and it was.
    ///
    /// Saving still happens: automatically before an apply, on ⌘S, and when the window closes with unsaved
    /// decisions. It is bookkeeping the app can do without being asked.
    private let simulateButton = NSButton()
    private let warningLabel = NSTextField(labelWithString: "")

    private let undo = UndoManager()
    private var applySheet: ApplySheetController?
    /// Which groups the sidebar is showing.
    private var filter = GroupFilter()
    /// Scan indices of the visible rows, in order. The sidebar's row is an index into this.
    private var visible: [Int] = []
    private let sizeFilterPopup = NSPopUpButton()
    private let undecidedToggle = NSButton()
    private let filterCountLabel = NSTextField(labelWithString: "")
    private let stillThereToggle = NSButton()
    private let checkDiskButton = NSButton()
    /// Whether each group still has two files on disk, once somebody asks. Empty until then, and a group
    /// missing from it is treated as still a duplicate -- not yet checked is not the same as gone.
    private var stillDuplicate: [Int: Bool] = [:]
    private var diskCheck: Task<Void, Never>?
    /// What the last disk check found, for the filter line.
    private var diskSummary: String?
    private var diskTimer: Timer?
    private let presenceCache: PresenceCache
    /// What the decisions file that was loaded looks like next to the scan.
    private var provenance: DecisionsProvenance = .none

    private let previewPane = PreviewPane()
    private let thumbnailer = QuickLookThumbnailer()
    /// What the filesystem says about the current group, or `nil` until the check comes back.
    private var presence: GroupPresence?
    /// Bumped per group so a slow presence check that lands after the user moved on is dropped.
    private var presenceGeneration = 0
    /// Bumped per preview request, same reason.
    private var previewGeneration = 0

    /// - Parameter presenceCacheDirectory: where the disk-check snapshots live. Injected so a selftest can
    ///   point it at a temp directory: the default is the real `~/Library/Caches`, and a mode that wrote
    ///   there would leak its answers into the next run -- which it did, and the leak is what made a
    ///   teeth check fail on the wrong assertion.
    init(
        scan: DuplicateScan,
        stateDirectory: StateDirectory,
        presenceCacheDirectory: URL = PresenceCache.defaultDirectory()
    ) {
        self.stateDirectory = stateDirectory
        self.presenceCache = PresenceCache(directory: presenceCacheDirectory)
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
        // **A window with a minimum, rather than one that collapses.** Dragged below what the layout needs,
        // AutoLayout starts breaking constraints and the detail pane vanishes entirely -- seen in a real
        // screenshot: a squashed window with an empty right half and no footer. `minSize` makes the window
        // stop instead.
        window.minSize = NSSize(width: 780, height: 420)
        super.init(window: window)

        window.delegate = self
        self.savedDecisions = state.decisionsForSaving
        self.provenance = DecisionsProvenance.classify(scan: scan, priorDecisions: prior)
        buildContent()
        adoptCachedPresence()
        rebuildVisibleGroups()
        selectGroup(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this window is built in code, there is no nib")
    }

    /// Asks about an imported decisions file that covers every group.
    ///
    /// **The CLI writes one, always** -- 55 of the 56 files in this user's corpus hold exactly one decision
    /// per group. Loading it silently makes every group show a check mark, which reads as a review that
    /// happened; pressing Simulate then plans over groups nobody opened.
    ///
    /// Neither refusing to load it nor discarding it silently would be better: both are the app deciding for
    /// the user. So it asks, once, when the window opens.
    func presentImportWarningIfNeeded() {
        guard provenance.deservesAWarning, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: Strings.string("review.imported.title"), provenance.decidedCount)
        alert.informativeText = Strings.string("review.imported.body")
        alert.addButton(withTitle: Strings.string("review.imported.keep"))
        alert.addButton(withTitle: Strings.string("review.imported.discard"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            MainActor.assumeIsolated {
                // Cleared in memory only. Nothing is written until the user saves or applies, so changing
                // their mind costs closing the window without saving.
                self.clearAllDecisionsForImport()
            }
        }
    }

    /// Drops every decision that came from the file, leaving a review that has not started.
    private func clearAllDecisionsForImport() {
        let before = state
        for index in 0..<state.groupCount {
            state.go(to: index)
            state.clearDecision()
        }
        state.go(to: 0)
        provenance = .none
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.mutate { $0 = before } }
        }
        flow.decisionsChanged(hasAny: false)
        selectGroup(0)
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }

        groupTable.dataSource = self
        groupTable.delegate = self
        groupTable.headerView = nil
        groupTable.style = .sourceList
        // Two lines per row, so the size and the file count stop competing with the group number for a
        // width that never fit them: the first screenshot of this window read "Grupo 864 - 41.1 KB - 2 ar…".
        groupTable.rowHeight = 40
        groupTable.allowsEmptySelection = false
        let groupColumn = NSTableColumn(identifier: .init("group"))
        groupColumn.width = 230
        groupTable.addTableColumn(groupColumn)

        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.rowHeight = 26
        // No stripes: a group holds two to eight files, and alternating backgrounds over a mostly empty
        // table draw a ladder of empty rows that reads as broken.
        fileTable.usesAlternatingRowBackgroundColors = false
        fileTable.allowsEmptySelection = false
        fileTable.onToggle = { [weak self] in self?.toggleSelectedFile() }
        fileTable.onConfirm = { [weak self] in self?.confirmGroup(nil) }
        fileTable.target = self
        fileTable.doubleAction = #selector(revealSelectedFile(_:))
        for (name, key, width) in [
            // 46 points clipped the header to "Cons…". A column header that cannot show its own name is a
            // column nobody can interpret.
            ("keep", "review.column.keep", CGFloat(78)),
            ("file", "review.column.file", CGFloat(430)),
            ("note", "review.column.note", CGFloat(210)),
        ] {
            let column = NSTableColumn(identifier: .init(name))
            column.title = Strings.string(key)
            column.width = width
            fileTable.addTableColumn(column)
        }

        // **Multiple selection, because 880 groups cannot be decided one at a time** -- and the answer is
        // not a button that decides them all, which is the CLI's defect. Selecting a set and confirming it
        // is an act on groups the user chose and can see the size of.
        groupTable.allowsMultipleSelection = true

        sizeFilterPopup.target = self
        sizeFilterPopup.action = #selector(filterChanged(_:))
        for size in GroupFilter.sizeChoices {
            sizeFilterPopup.addItem(
                withTitle: size == 0
                    ? Strings.string("review.filter.anySize")
                    : String(format: Strings.string("review.filter.atLeast"), ByteSize.format(size))
            )
        }
        sizeFilterPopup.selectItem(at: 0)

        undecidedToggle.setButtonType(.switch)
        undecidedToggle.title = Strings.string("review.filter.onlyUndecided")
        undecidedToggle.target = self
        undecidedToggle.action = #selector(filterChanged(_:))

        filterCountLabel.font = .systemFont(ofSize: 10)
        filterCountLabel.textColor = .secondaryLabelColor
        filterCountLabel.lineBreakMode = .byTruncatingTail
        filterCountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The checkbox titles were clipped against the sidebar's edge -- "Solo los grupos que todavía
        // existen" does not fit 240 points. Shorter titles, and the buttons yield rather than demanding
        // their intrinsic width, which is what pushed the text off the edge instead of truncating it.
        for button in [undecidedToggle, stillThereToggle] {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.lineBreakMode = .byTruncatingTail
        }

        stillThereToggle.setButtonType(.switch)
        stillThereToggle.title = Strings.string("review.filter.stillThere")
        stillThereToggle.target = self
        stillThereToggle.action = #selector(filterChanged(_:))
        // Off and disabled until the disk has been read: a filter that hides groups because nobody has
        // looked yet would lose them silently.
        stillThereToggle.isEnabled = false

        checkDiskButton.title = Strings.string("review.filter.checkDisk")
        checkDiskButton.bezelStyle = .rounded
        checkDiskButton.controlSize = .small
        checkDiskButton.target = self
        checkDiskButton.action = #selector(toggleDiskCheck(_:))

        let filterBar = NSStackView(views: [
            sizeFilterPopup, undecidedToggle, stillThereToggle, checkDiskButton, filterCountLabel,
        ])
        filterBar.orientation = .vertical
        filterBar.alignment = .leading
        filterBar.spacing = 4
        filterBar.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 6, right: 8)

        let groupScroll = NSScrollView()
        groupScroll.documentView = groupTable
        groupScroll.hasVerticalScroller = true
        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true
        // **A scroll view must not inherit its content's width as a requirement.** An `NSTableView` reports
        // an intrinsic width equal to the sum of its columns -- 718 points here -- and through the scroll
        // view that became the window's required width, 1,104 points in total. Scrolling is precisely the
        // thing that makes a narrower view acceptable, so the resistance goes down and the table scrolls
        // horizontally when it has to.
        for scroll in [groupScroll, fileScroll] {
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        fileTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingHead
        subheaderLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subheaderLabel.textColor = .secondaryLabelColor
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.usesSingleLineMode = false
        warningLabel.maximumNumberOfLines = 3

        // **Every label in this pane yields.** A sentence like "Solo 0 de los 3 archivos que registró este
        // grupo siguen existiendo…" is 110 characters, and a label reports its intrinsic width as a
        // requirement -- which is how the window ended up demanding 1,112 points of width. Text wraps and
        // truncates; it does not get to decide how wide a window is.
        for label in [headerLabel, subheaderLabel, warningLabel, tallyLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        tallyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tallyLabel.textColor = .secondaryLabelColor

        // The preview sits beside the list rather than under it: a file name and a picture of the file
        // belong on the same line of sight, and stacking them vertically halves the rows visible.
        let inner = NSSplitView()
        inner.isVertical = true
        inner.dividerStyle = .thin
        inner.addArrangedSubview(fileScroll)
        inner.addArrangedSubview(previewPane)
        // **The preview holds its width; the file list takes the slack.** The first attempt had it the
        // other way round, and that is what made the window resize only vertically: a split can only grow by
        // growing the subview that yields, and the one that yielded was capped at 380 points -- so there was
        // nowhere for extra width to go and the window refused to widen at all.
        //
        // This is also the ordinary master-detail arrangement: the list is what benefits from more room.
        inner.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
        inner.translatesAutoresizingMaskIntoConstraints = false
        previewPane.showPlaceholder()

        let detail = NSStackView(views: [headerLabel, subheaderLabel, warningLabel, inner])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 4
        detail.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 6, right: 14)
        fileScroll.translatesAutoresizingMaskIntoConstraints = false
        detail.setHuggingPriority(.defaultLow, for: .horizontal)

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let sidebar = NSStackView(views: [filterBar, groupScroll])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 0
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            groupScroll.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
            filterBar.widthAnchor.constraint(equalTo: sidebar.widthAnchor),
        ])

        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(detail)
        // The group sidebar holds its width and the detail takes the slack -- the same reasoning as the
        // inner split, in the direction a sidebar normally behaves.
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false

        simulateButton.title = Strings.string("review.button.simulate")
        simulateButton.bezelStyle = .rounded
        // The primary action of the window, drawn as one with a large control size.
        //
        // **No `.glass` behind an `#available`.** That was the first attempt and CI rejected it: `#available`
        // guards *runtime* availability, not whether the symbol exists in the SDK being compiled against,
        // and `.glass` is absent from the macOS 15 SDK the runner uses. A newer-SDK symbol cannot be reached
        // this way at all -- fifth divergence between SDKs that only CI catches.
        simulateButton.controlSize = .large
        simulateButton.target = self
        simulateButton.action = #selector(simulateApply(_:))

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [tallyLabel, spacer, simulateButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(split)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            inner.widthAnchor.constraint(equalTo: detail.widthAnchor, constant: -28),
            inner.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            // A floor, and no ceiling. A ceiling here is what blocked the window from widening; the image
            // inside is capped on its own, which is what the original bug actually needed.
            previewPane.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            fileScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        window.contentView = content
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
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

        // A group that is no longer a duplicate outranks every other warning: there is nothing to decide,
        // and the checkboxes below are about files that are gone.
        if let presence, !presence.isStillADuplicate {
            warningLabel.stringValue = String(
                format: Strings.string("review.warning.notADuplicate"),
                presence.presentCount, presence.files.count
            )
        } else if let presence, presence.isStale {
            warningLabel.stringValue = String(
                format: Strings.string("review.warning.stale"),
                presence.missingCount + presence.changedCount, presence.files.count
            )
            // The one warning the CLI's own UX document specified and never implemented.
        } else if presentation.keptCount == 0, presentation.decision != .discardAll {
            warningLabel.stringValue = Strings.string("review.warning.keepNothing")
        } else if presentation.hasSharedStorage {
            warningLabel.stringValue = Strings.string("review.warning.sharedStorage")
        } else if presentation.decision == .undecided {
            // **Not orange.** This is the normal state of a group nobody has opened yet, so colouring it
            // like a hazard spends the one colour that should mean "look at this" on the most common case.
            warningLabel.stringValue = Strings.string("review.warning.preview")
            warningLabel.textColor = .secondaryLabelColor
        } else {
            warningLabel.stringValue = ""
        }
        if presentation.decision != .undecided || presentation.keptCount == 0 {
            warningLabel.textColor = .systemOrange
        }

        let tally = state.tally
        tallyLabel.stringValue = String(
            format: Strings.string("review.tally"),
            tally.decided, tally.skipped, tally.undecided,
            ByteSize.format(state.plannedReclaimBytes)
        )
        // The buttons say the same thing the menu items do, from one source: nothing decided means nothing
        // to simulate and nothing to save.
        simulateButton.isEnabled = !state.decisionsForSaving.isEmpty

        fileTable.reloadData()
        if !visible.isEmpty {
            groupTable.reloadData(
                forRowIndexes: IndexSet(integersIn: 0..<visible.count),
                columnIndexes: IndexSet(integer: 0)
            )
        }
    }

    /// Recomputes which groups the sidebar shows, keeping the current one visible when it still matches.
    ///
    /// **A narrowed list never changes a decision.** Hiding a group is a display choice; the groups that
    /// disappear stay exactly as they were -- undecided, unwritten, unacted on.
    private func rebuildVisibleGroups() {
        let previous = state.groupIndex
        visible = filter.matchingIndices(
            in: state.scan,
            decision: { self.state.decision(at: $0) },
            stillDuplicate: stillDuplicate
        )
        var summary = String(
            format: Strings.string("review.filter.count"), visible.count, state.groupCount)
        if let diskSummary { summary += "  \u{00B7}  " + diskSummary }
        filterCountLabel.stringValue = summary
        groupTable.reloadData()

        if let row = visible.firstIndex(of: previous) {
            groupTable.selectRowIndexes([row], byExtendingSelection: false)
        } else if let first = visible.first {
            selectGroup(first)
        }
    }

    /// Reads the filesystem for every group, or stops a check already running.
    ///
    /// **Off the main thread and cancellable**, because it is a `stat` per file: 2,259 for one of this
    /// user's scans and 9,949 for another, on an external drive that may have spun down. A window that
    /// stopped responding for that long would be worse than not offering the filter.
    /// Uses the last disk check for this scan, if there is one.
    ///
    /// **Cached because it takes long enough to be worth not repeating**, and the answer keeps most of its
    /// value: a May scan whose files are gone will still have them gone tomorrow. The age is shown rather
    /// than hidden, because a snapshot is only true at the instant it was taken -- and nothing destructive
    /// reads it. The apply path re-hashes every file immediately before moving it.
    private func adoptCachedPresence() {
        guard let snapshot = presenceCache.load(scanID: state.scan.scanID) else { return }
        stillDuplicate = snapshot.stillDuplicate(for: state.scan)
        guard !stillDuplicate.isEmpty else { return }
        stillThereToggle.isEnabled = true
        diskSummary = String(
            format: Strings.string("review.filter.checkedAgo"),
            snapshot.stillDuplicateCount,
            snapshot.checkedCount,
            Self.age(of: snapshot.checkedAt)
        )
    }

    /// How long ago a timestamp was, in words.
    ///
    /// Locale-aware, unlike the byte counts: this is not written anywhere and not compared with anything.
    private static func age(of timestamp: String) -> String {
        guard let then = ScanIdentifier.date(fromTimestamp: timestamp) else {
            return Strings.string("about.unknown")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: then, relativeTo: Date())
    }

    @objc private func toggleDiskCheck(_ sender: Any?) {
        if let running = diskCheck {
            running.cancel()
            diskCheck = nil
            checkDiskButton.title = Strings.string("review.filter.checkDisk")
            rebuildVisibleGroups()
            return
        }

        let scan = state.scan
        checkDiskButton.title = Strings.string("button.cancel")
        let progress = AppliedCounter()

        diskCheck = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                try? ScanPresence.check(scan: scan) { done, _ in progress.set(done) }
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.diskCheck = nil
                self.checkDiskButton.title = Strings.string("review.filter.checkDisk")
                guard let outcome else {
                    // Cancelled. Whatever was learned is dropped rather than half-applied: a partial map
                    // would hide groups that were simply never reached.
                    self.rebuildVisibleGroups()
                    return
                }
                self.stillDuplicate = outcome.stillDuplicate

                // Saved so the next session does not pay for it again. A failure to write is swallowed: it
                // is a cache, and losing it costs one more check.
                let snapshot = PresenceSnapshot(
                    stillDuplicateByKey: Dictionary(
                        uniqueKeysWithValues: outcome.groups.compactMap { index, presence in
                            self.state.scan.groups.indices.contains(index)
                                ? (self.state.scan.groups[index].key, presence.isStillADuplicate)
                                : nil
                        }
                    ),
                    checkedAt: ScanIdentifier.timestamp(from: Date())
                )
                _ = try? self.presenceCache.save(snapshot, scanID: self.state.scan.scanID)

                self.stillThereToggle.isEnabled = true
                self.diskSummary = String(
                    format: Strings.string("review.filter.checked"),
                    outcome.stillDuplicateCount, outcome.checkedCount
                )
                self.rebuildVisibleGroups()
            }
        }

        startDiskCheckTimer(reading: progress)
    }

    /// Ten reads a second, like every other progress in this app.
    ///
    /// The work item is `@MainActor`-isolated and the timer is stored rather than captured: a `Timer`
    /// closure is nonisolated, and handing it itself to invalidate is a data race the compiler rejects.
    private func startDiskCheckTimer(reading progress: AppliedCounter) {
        diskTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard self.diskCheck != nil else {
                    self.diskTimer?.invalidate()
                    self.diskTimer = nil
                    return
                }
                self.filterCountLabel.stringValue = String(
                    format: Strings.string("review.filter.checking"),
                    progress.value, self.state.groupCount
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        diskTimer = timer
    }

    @objc private func filterChanged(_ sender: Any?) {
        let index = sizeFilterPopup.indexOfSelectedItem
        filter.minimumSize =
            GroupFilter.sizeChoices.indices.contains(index) ? GroupFilter.sizeChoices[index] : 0
        filter.onlyUndecided = undecidedToggle.state == .on
        filter.onlyStillDuplicates = stillThereToggle.state == .on
        rebuildVisibleGroups()
        refreshDetail()
    }

    /// The scan indices the user has selected in the sidebar.
    private var selectedGroupIndices: [Int] {
        groupTable.selectedRowIndexes.compactMap { row in
            visible.indices.contains(row) ? visible[row] : nil
        }
    }

    /// Accepts what is shown for every selected group, after saying how many and how much.
    ///
    /// **The line this does not cross**: it records the keep set that is on screen, for groups the user
    /// selected. What the CLI does -- and what this app refuses to do -- is decide every group as a side
    /// effect of quitting, with nothing asked and nothing shown.
    @objc func confirmSelectedGroups(_ sender: Any?) {
        let indices = selectedGroupIndices
        guard !indices.isEmpty, let window else { return }
        let untouched = indices.filter { state.decision(at: $0) == .undecided }
        let bytes = untouched.reduce(Int64(0)) { total, index in
            total + state.scan.groups[index].reclaimableBytes
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: Strings.string("review.bulk.title"), untouched.count)
        alert.informativeText = String(
            format: Strings.string("review.bulk.body"), ByteSize.format(bytes))
        alert.addButton(withTitle: Strings.string("review.bulk.confirm"))
        alert.addButton(withTitle: Strings.string("button.cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            MainActor.assumeIsolated {
                self.mutate { $0.confirmAll(indices) }
                self.rebuildVisibleGroups()
            }
        }
    }

    private func selectGroup(_ index: Int) {
        let changedGroup = index != state.groupIndex || presence == nil
        state.go(to: index)
        if let row = visible.firstIndex(of: index) {
            if groupTable.selectedRow != row {
                groupTable.selectRowIndexes([row], byExtendingSelection: false)
                groupTable.scrollRowToVisible(row)
            }
        } else if let next = visible.first(where: { $0 > index }) ?? visible.last {
            // The group left the filter -- decided, or hidden by a size change. Land on the next one that
            // is still shown rather than leaving the sidebar pointing at nothing.
            state.go(to: next)
            if let row = visible.firstIndex(of: next) {
                groupTable.selectRowIndexes([row], byExtendingSelection: false)
                groupTable.scrollRowToVisible(row)
            }
        }
        if changedGroup {
            // Dropped rather than kept: the previous group's answer says nothing about this one, and
            // showing it would label these files with that group's state.
            presence = nil
            checkPresence()
        }
        if !presentationRowsEmpty { fileTable.selectRowIndexes([0], byExtendingSelection: false) }
        refreshDetail()
        refreshPreview()
    }

    /// Asks the filesystem what became of this group's files, off the main thread.
    ///
    /// **Off the main thread because a stat is not free.** A group on an external drive that has spun down
    /// takes seconds for the first answer, and a window that freezes on arrow-down is unusable. The
    /// generation guard drops an answer that lands after the user moved on.
    private func checkPresence() {
        guard let group = state.currentGroup else { return }
        presenceGeneration += 1
        let generation = presenceGeneration
        Task.detached(priority: .userInitiated) {
            let checked = GroupPresence.check(group: group)
            await MainActor.run { [weak self] in
                guard let self, generation == self.presenceGeneration else { return }
                self.presence = checked
                self.refreshDetail()
                self.refreshPreview()
            }
        }
    }

    /// The thumbnail size to ask for, from the pane's width and the screen.
    ///
    /// One place, used by the window and by the selftest hook alike. Two callers computing it separately is
    /// how a selftest ends up exercising a size production never asks for -- which is exactly what happened
    /// the first time this was written: the hook asked for 128 px, the window asked for the pane's width,
    /// and the cache ended up with one entry per size instead of one per group.
    private func currentPixelSize() -> Int {
        ThumbnailPolicy.pixelSize(
            points: previewPane.thumbnailPoints,
            scale: Double(window?.backingScaleFactor ?? 2)
        )
    }

    /// Draws the file under the cursor, cached image first and a rendered one when it arrives.
    private func refreshPreview() {
        guard let group = state.currentGroup, let presentation else {
            previewPane.showPlaceholder()
            return
        }
        let row = fileTable.selectedRow
        guard presentation.rows.indices.contains(row) else {
            previewPane.showPlaceholder()
            return
        }
        let path = presentation.rows[row].path
        let filePresence =
            presence?.files.first { $0.path == path }
            ?? FilePresence(path: path, state: .present)
        previewPane.show(presence: filePresence, size: group.size)

        let pixelSize = currentPixelSize()
        // A cached image is drawn in this same turn of the run loop, so revisiting a row never flickers.
        if let cached = thumbnailer.cached(path: path, digest: group.digest, pixelSize: pixelSize) {
            previewPane.show(image: cached)
            return
        }
        previewPane.show(image: nil)
        // Nothing to render for a file that is not there, and asking would just wait for a failure.
        guard filePresence.state != .missing else { return }

        previewGeneration += 1
        let generation = previewGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            let image = await self.thumbnailer.thumbnail(
                path: path, digest: group.digest, pixelSize: pixelSize)
            guard generation == self.previewGeneration else { return }
            self.previewPane.show(image: image)
        }
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
        // `MainActor.assumeIsolated`, and it is not decoration: on the macOS 15 SDK that CI compiles
        // against, `registerUndo`'s closure is not `@MainActor`, so this is a hard error there and compiles
        // clean locally. The assumption is sound -- `UndoManager` runs the block on whichever thread called
        // `undo()`, and the only caller is the Edit menu, which is the main thread.
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.mutate { $0 = before } }
        }
        flow.decisionsChanged(hasAny: !state.decisionsForSaving.isEmpty)
        // **Rebuilt, because a decision can change what the filter shows.** With "only what I have not
        // decided" on, the group just decided leaves the list -- and without rebuilding, the sidebar keeps
        // showing it while the state has moved on. That is what a real screenshot caught: the sidebar
        // highlighting "Grupo 31" while the header said "Grupo 32 de 880".
        rebuildVisibleGroups()
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

    /// Shows what applying would do, and only then allows applying.
    ///
    /// **The fingerprint is computed once and used for both steps.** The sheet is handed the flow already at
    /// `.dryRunDone` with that value, so what the user sees and what `ApplyGate` authorises are the same
    /// plan by construction rather than by coincidence.
    @objc func simulateApply(_ sender: Any?) {
        let plan = ApplyPlan.from(state)
        guard !plan.isEmpty else {
            presentNothingToApply()
            return
        }
        // **Saved here, so the user never has to think about it.** The decisions file is what the CLI reads
        // and what a later session rehydrates from; a review that was acted on but never written would leave
        // the two tools disagreeing about what happened. It is bookkeeping, not a decision.
        saveDecisions(nil)

        let fingerprint = ApplyGate.fingerprint(of: state.removalPlan)
        _ = flow.advance(.dryRun, fingerprint: fingerprint)

        let sheet = ApplySheetController(
            plan: plan,
            fingerprint: fingerprint,
            flow: flow,
            stateDirectory: stateDirectory
        )
        sheet.onUndone = { [weak self] in
            self?.reloadFromDisk()
        }
        sheet.onApplied = { [weak self] _ in
            guard let self else { return }
            // Applying consumes the authorisation, so a second Apply needs a second dry run. And the files
            // are gone now, so the review is re-read from disk rather than left claiming they are there.
            _ = self.flow.advance(.apply)
            self.reloadFromDisk()
        }
        applySheet = sheet
        if let window, let sheetWindow = sheet.window {
            window.beginSheet(sheetWindow)
        } else {
            sheet.showWindow(nil)
        }
    }

    /// Re-reads what the filesystem says about this group and redraws.
    ///
    /// Called after anything that moves files -- an apply **and an undo**. Leaving it out of the undo path is
    /// what made the window keep saying "this file no longer exists" about a file that had just been put
    /// back, which is how the bug was found: by using it.
    func reloadFromDisk() {
        checkPresence()
        refreshDetail()
        refreshPreview()
    }

    private func presentNothingToApply() {
        let alert = NSAlert()
        alert.messageText = Strings.string("apply.nothing.title")
        alert.informativeText = Strings.string("apply.nothing.body")
        alert.addButton(withTitle: Strings.string("button.ok"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Opens Quick Look on the selected file, or closes it.
    ///
    /// **The thumbnail is 280 points and the decision can be finer than that.** This is the look the app exists
    /// for; the thumbnail is the index.
    @objc func toggleQuickLook(_ sender: Any?) {
        _ = quickLook.toggle(paths: quickLookPaths(), controller: self)
    }

    /// The selected file, or the whole group when nothing is selected: arrowing through a group in the panel is
    /// the same comparison the list makes, at full size.
    private func quickLookPaths() -> [String] {
        guard let presentation else { return [] }
        let row = fileTable.selectedRow
        return presentation.rows.indices.contains(row)
            ? [presentation.rows[row].path] : presentation.rows.map(\.path)
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
        case #selector(simulateApply(_:)):
            // Offered only when something is decided. Nothing to simulate is not an error worth a sheet.
            return !state.decisionsForSaving.isEmpty
        case #selector(revealSelectedFile(_:)):
            return fileTable.selectedRow >= 0
        default:
            return true
        }
    }

    /// What Quick Look would show for the current selection, without opening a panel.
    ///
    /// Asserted instead of the panel itself: `QLPreviewPanel` is a shared system window, and a mode that opened
    /// it would leave one on screen for the next mode and assert against a window it does not own.
    var quickLookPathsForSelftest: [String] { quickLookPaths() }

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
    var openApplySheet: ApplySheetController? { applySheet }
    var canSimulateFromButton: Bool { simulateButton.isEnabled }
    var importedProvenance: DecisionsProvenance { provenance }
    var visibleGroupCount: Int { visible.count }
    var visibleGroupIndices: [Int] { visible }
    /// The scan index the sidebar has highlighted, straight from the table.
    var selectedSidebarIndex: Int? {
        let row = groupTable.selectedRow
        return visible.indices.contains(row) ? visible[row] : nil
    }
    /// What the header is describing.
    var headerGroupIndex: Int { state.groupIndex }

    /// Selects a sidebar row the way a click does, going through the delegate.
    func clickSidebarRowForSelftest(_ row: Int) {
        guard visible.indices.contains(row) else { return }
        groupTable.selectRowIndexes([row], byExtendingSelection: false)
        tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: groupTable))
    }

    func setFilterForSelftest(minimumSize: Int64, onlyUndecided: Bool) {
        filter.minimumSize = minimumSize
        filter.onlyUndecided = onlyUndecided
        rebuildVisibleGroups()
        refreshDetail()
    }

    var diskCheckedCount: Int { stillDuplicate.count }
    var canFilterByPresence: Bool { stillThereToggle.isEnabled }
    var diskSummaryText: String? { diskSummary }

    /// Runs the disk check and waits for it, for a selftest.
    func checkDiskForSelftest() async {
        toggleDiskCheck(nil)
        for _ in 0..<400 where diskCheck != nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func setPresenceFilterForSelftest(_ on: Bool) {
        stillThereToggle.state = on ? .on : .off
        filterChanged(nil)
    }

    func confirmAllVisibleForSelftest() {
        let indices = visible
        mutate { $0.confirmAll(indices) }
        rebuildVisibleGroups()
    }

    /// The smallest size this window's constraints allow.
    ///
    /// The one layout property worth asserting: it is what decides whether a window can be resized down, and
    /// a constraint that demands more than a screen makes the window unusable in a way no other check sees.
    var requiredContentSize: NSSize {
        window?.contentView?.layoutSubtreeIfNeeded()
        return window?.contentView?.fittingSize ?? .zero
    }
    func discardImportedForSelftest() { clearAllDecisionsForImport() }
    var footerButtonCount: Int { 1 }
    var simulateButtonTitle: String { simulateButton.title }
    /// Whether this review's apply sheet is moving files right now.
    var isApplying: Bool { applySheet?.isApplying ?? false }
    func simulateForSelftest() { simulateApply(nil) }
    var preview: PreviewPane { previewPane }
    var groupPresence: GroupPresence? { presence }
    var thumbnailCacheCount: Int { thumbnailer.cachedCount }
    var thumbnailHits: Int { thumbnailer.hits }
    var thumbnailMisses: Int { thumbnailer.misses }
    var thumbnailCoalesced: Int { thumbnailer.coalesced }
    var currentThumbnailPixels: Int { currentPixelSize() }

    /// Lays the window out and empties the thumbnail cache.
    ///
    /// A pane whose width changes asks for a different pixel size, which is a different cache key -- correct
    /// in production, and noise in a test that wants to prove one group needs one thumbnail. Settling the
    /// layout first and clearing what was cached before it makes the count exact instead of approximate.
    func settleLayoutForSelftest() {
        window?.layoutIfNeeded()
        thumbnailer.clearCache()
    }

    /// Waits for the presence check to land, so a selftest asserts on an answer rather than on a race.
    func awaitPresenceForSelftest() async {
        for _ in 0..<200 where presence == nil {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Renders the selected file's preview synchronously enough for a selftest to assert on it.
    func loadPreviewForSelftest() async {
        guard let group = state.currentGroup, let presentation,
            presentation.rows.indices.contains(fileTable.selectedRow)
        else { return }
        let path = presentation.rows[fileTable.selectedRow].path
        let image = await thumbnailer.thumbnail(
            path: path, digest: group.digest, pixelSize: currentPixelSize())
        previewPane.show(image: image)
    }
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
        tableView === groupTable ? visible.count : (presentation?.rows.count ?? 0)
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        tableView === groupTable
            ? groupCell(row: row)
            : fileCell(column: tableColumn?.identifier.rawValue ?? "", row: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === fileTable {
            refreshPreview()
            return
        }
        guard table === groupTable else { return }
        let row = groupTable.selectedRow
        guard row >= 0, visible.indices.contains(row) else { return }
        let index = visible[row]
        guard index != state.groupIndex else { return }
        selectGroup(index)
    }

    private func groupCell(row: Int) -> NSView? {
        guard visible.indices.contains(row) else { return nil }
        let index = visible[row]
        guard state.scan.groups.indices.contains(index) else { return nil }
        let group = state.scan.groups[index]
        let identifier = NSUserInterfaceItemIdentifier("group")
        let cell =
            groupTable.makeView(withIdentifier: identifier, owner: self) as? GroupRowView
            ?? GroupRowView(identifier: identifier)

        // Symbol, not a word: this column is 230 points wide and the second line already carries numbers.
        let mark: String
        switch state.decision(at: index) {
        case .decided: mark = "\u{2713} "
        case .discardAll: mark = "\u{2717} "
        case .skipped: mark = "\u{2192} "
        case .undecided: mark = ""
        }
        cell.titleField.stringValue =
            mark
            + String(
                format: Strings.string("review.group.title"), row + 1)
        cell.detailField.stringValue = String(
            format: Strings.string("review.group.detail"),
            ByteSize.format(group.size), group.files.count
        )
        cell.titleField.textColor = .labelColor
        cell.detailField.textColor = .secondaryLabelColor
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
            // **Middle truncation, not head or tail.** A real group here was
            // `grok-video-d4456bb8-…-1d380340c634.png` next to `…_0002.mp4`: they share a 40-character
            // prefix and differ at the very end, so cutting either end hides the one thing that tells them
            // apart.
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            cell.textField?.toolTip = item.path
            cell.textField?.textColor = item.isKept ? .labelColor : .secondaryLabelColor
        case "note":
            var notes: [String] = []
            // The file's fate on disk goes first: "gone" outranks anything about naming.
            let fileState = presence?.files.first { $0.path == item.path }?.state
            switch fileState {
            case .missing: notes.append(Strings.string("review.note.missing"))
            case .sizeChanged: notes.append(Strings.string("review.note.changed"))
            case .unreadable: notes.append(Strings.string("review.note.unreadable"))
            case .notAFile: notes.append(Strings.string("review.note.notAFile"))
            case .present, nil: break
            }
            if item.sharesStorageWithKeeper {
                notes.append(Strings.string("review.note.sameStorage"))
            }
            if item.looksLikeCopy { notes.append(Strings.string("review.note.copyName")) }
            cell.textField?.stringValue = notes.joined(separator: " \u{00B7} ")
            let isWarning =
                item.sharesStorageWithKeeper || (fileState.map { $0 != .present } ?? false)
            cell.textField?.textColor = isWarning ? .systemOrange : .secondaryLabelColor
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

    func windowWillClose(_ notification: Notification) {
        // A scan of 9,949 paths must not keep running for a window that is gone.
        diskCheck?.cancel()
        diskTimer?.invalidate()
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

/// **Quick Look asks the responder chain for permission and then for a data source.** Without these three the
/// panel opens empty, which looks exactly like a broken preview rather than like missing wiring.
extension ReviewWindowController {
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
