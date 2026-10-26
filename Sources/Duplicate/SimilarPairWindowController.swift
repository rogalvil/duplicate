import AppKit
import DuplicateCore
@preconcurrency import Quartz

/// Shows the groups of one perceptual scan: which files are alike, and which of them stay.
///
/// **Groups, not pairs** (#217). The scan stores pairs, and three copies of one video are three pairs; decided one at
/// a time, the third pair could only contradict the first two, and the apply then left those files alone. One group of
/// 23 copies in this user's scans was 253 pairs. A group is one decision -- a keep set, like the exact review's -- and
/// it is saved as the CLI's pair decisions, so the file format does not change.
///
/// **Two thumbnails, because that is the only way to judge this detector.** The left pane holds the best file the
/// group keeps and the right one the file selected in the list, at the same size: the app claims they *look* alike,
/// and only the user can say whether that is true.
///
/// **Deciding and moving are separate steps.** A choice here is only recorded in `similar-decisions`. Moving happens
/// from the apply sheet, behind the same dry-run gate, journal and verify-before-moving the exact detector has: each
/// file is scored again against a file that stays.
///
/// **The suggestion is shown checked and is never saved on its own**, as in the exact review: confirming is what
/// turns it into a decision.
@MainActor
final class SimilarPairWindowController: NSWindowController, NSWindowDelegate {

    private let scan: SimilarScan
    /// The group indices on screen, in the review's order. **Narrowing decides nothing** -- this is the only thing a
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
    /// Facts already probed, by the bytes of the path. Filled for the group being looked at, never for all of them.
    private var facts: [[UInt8]: MediaFacts] = [:]
    private let probe = MediaProbe()
    private let groupTable = ReviewTableView()
    private let fileTable = ReviewTableView()
    /// The members of the selected group, best first: the rows of the file list.
    private var fileOrder: [Int] = []
    /// The member in the left pane: the best one the group keeps.
    private var reference: Int?
    /// The member in the right pane: the one selected in the list, or the next one.
    private var compared: Int?
    /// The member under the list's selection: what the space bar checks or unchecks. Usually ``compared``; the
    /// keeper on the left when that row is selected, which is how the keyboard replaces a keeper.
    private var cursor: Int?
    /// Paths a probe already tried, by their bytes. **Tried, not answered**: a file that is gone or unreadable has no
    /// facts to store, and asking again on every redraw was a loop -- the probe's own redraw asked again (#219).
    private var probed: Set<[UInt8]> = []
    private var probeLaunches = 0
    /// Probes started and not yet answered, so a selftest can wait for one instead of sleeping.
    private var probesInFlight = 0
    private let thumbnailer = QuickLookThumbnailer()
    private let leftPane = SimilarSidePane()
    private let quickLook = QuickLookCoordinator()
    private let rightPane = SimilarSidePane()
    private let headerLabel = NSTextField(labelWithString: "")
    private let warningLabel = NSTextField(labelWithString: "")
    private let pairLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let adviceLabel = NSTextField(labelWithString: "")
    private let tallyLabel = NSTextField(labelWithString: "")
    private let confirmButton = NSButton()
    private let keepAllButton = NSButton()
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

    /// What the decisions loaded at open look like: a file covering every pair is most likely the CLI's.
    private var provenance: DecisionsProvenance

    /// How a compared file is opened in its app, and shown in Finder (#226). Replaced by a selftest, which must not
    /// launch Preview or raise a Finder window on the user's screen.
    var openFile: (String) -> Void = { NSWorkspace.shared.open(URL(filePath: $0)) }
    var revealFile: (String) -> Void = { Reveal.item(at: $0) }

    init(scan: SimilarScan, stateDirectory: StateDirectory = StateDirectory.current()) {
        self.scan = scan
        self.stateDirectory = stateDirectory
        // Rehydrated from disk, so reopening a scan shows what was already decided -- including a document the
        // CLI wrote, which decides every pair and so reads as decided groups -- and which names were chosen (#228).
        let store = ScanStore(state: stateDirectory)
        self.review = SimilarReviewState(
            scan: scan,
            priorDecisions: store.priorSimilarDecisions(scanID: scan.scanID),
            priorRenames: store.priorSimilarRenames(scanID: scan.scanID)
        )
        self.provenance = DecisionsProvenance.classify(
            decided: review.tally.decided, total: scan.pairs.count)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(format: Strings.string("similar.window.title"), scan.scanID)
        window.minSize = NSSize(width: 720, height: 420)
        super.init(window: window)
        window.delegate = self
        build()
        rebuildVisible()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// **Where ⌘Z arrives.** AppKit asks the window's delegate for the undo manager, and without this the Edit
    /// menu's `undo:` reaches nothing and the menu item is disabled -- a review with a perfectly working undo that
    /// is invisible, which is worse than not having one.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undo }

    private func build() {
        groupTable.dataSource = self
        groupTable.delegate = self
        groupTable.usesAlternatingRowBackgroundColors = true
        groupTable.rowHeight = 22
        groupTable.allowsMultipleSelection = false
        groupTable.target = self
        groupTable.doubleAction = #selector(revealSelected(_:))
        groupTable.onConfirm = { [weak self] in self?.confirmGroup(nil) }
        groupTable.onToggle = { [weak self] in self?.toggle(member: self?.compared) }
        for (identifier, key, width) in [
            ("similarity", "similar.column.similarity", 90.0),
            ("kind", "similar.column.kind", 64.0),
            ("files", "similar.column.files", 64.0),
            ("decision", "similar.column.decision", 120.0),
            ("name", "similar.column.a", 420.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = Strings.string(key)
            column.width = width
            groupTable.addTableColumn(column)
        }
        // Numbers line up on the right, under a header that does too.
        groupTable.tableColumns[2].headerCell.alignment = .right

        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.rowHeight = 20
        fileTable.allowsMultipleSelection = false
        fileTable.onConfirm = { [weak self] in self?.confirmGroup(nil) }
        fileTable.target = self
        fileTable.doubleAction = #selector(openClickedFile(_:))
        for pane in [leftPane, rightPane] {
            pane.onOpen = { [weak self] path in self?.openFile(path) }
            pane.onReveal = { [weak self] path in self?.revealFile(path) }
        }
        fileTable.onToggle = { [weak self] in self?.toggle(member: self?.cursor) }
        for (identifier, key, width) in [
            ("keep", "similar.column.keep", 60.0),
            ("takeName", "similar.column.name", 52.0),
            ("file", "similar.column.a", 220.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = Strings.string(key)
            column.width = width
            fileTable.addTableColumn(column)
        }
        fileTable.tableColumns[0].minWidth = 44
        fileTable.tableColumns[1].minWidth = 44
        fileTable.tableColumns[1].headerToolTip = Strings.string("similar.column.name.help")
        fileTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let groupScroll = NSScrollView()
        groupScroll.documentView = groupTable
        groupScroll.hasVerticalScroller = true
        groupScroll.borderType = .bezelBorder
        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true
        fileScroll.borderType = .bezelBorder
        fileScroll.translatesAutoresizingMaskIntoConstraints = false
        // A table reports the sum of its columns as its intrinsic width, and through a scroll view that becomes a
        // floor on the window. A scroll view exists to be narrower than its content.
        for scroll in [groupScroll, fileScroll] {
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for label in [headerLabel, footerLabel, adviceLabel, tallyLabel, pairLabel, warningLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingMiddle
        }
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        pairLabel.font = .systemFont(ofSize: 11)
        warningLabel.font = .systemFont(ofSize: 11)
        warningLabel.textColor = .systemOrange
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.maximumNumberOfLines = 2
        footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor
        adviceLabel.font = .systemFont(ofSize: 11)
        adviceLabel.textColor = .secondaryLabelColor
        adviceLabel.maximumNumberOfLines = 2
        tallyLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tallyLabel.textColor = .secondaryLabelColor

        // Same titles and selectors as the exact review's, so the Group menu and its shortcuts reach this window too.
        confirmButton.title = Strings.string("menu.group.confirm")
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmGroup(_:))
        keepAllButton.title = Strings.string("similar.group.keepAll")
        keepAllButton.bezelStyle = .rounded
        keepAllButton.target = self
        keepAllButton.action = #selector(keepAll(_:))
        skipButton.title = Strings.string("similar.decision.skip")
        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skipGroup(_:))
        let decisionRow = NSStackView(views: [confirmButton, keepAllButton, skipButton])
        decisionRow.orientation = .horizontal
        decisionRow.spacing = 8
        decisionRow.translatesAutoresizingMaskIntoConstraints = false

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
        confirmShownButton.toolTip = Strings.string("similar.confirmShown.tip")
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
        // As wide as what it holds: its trailing edge is only capped, so without this its width was free (#214).
        filterRow.setHuggingPriority(.init(740), for: .horizontal)

        // **A button, not only a menu item.** The last time an action of this app lived behind a keyboard
        // shortcut alone, nothing on screen said a review could be applied at all.
        applyButton.title = Strings.string("similar.review.apply")
        applyButton.bezelStyle = .rounded
        applyButton.target = self
        applyButton.action = #selector(simulateAndApply(_:))

        // **The two scan-wide actions get their own line, and that is what lets the window narrow.** One row with
        // every button asked for 986 points, and a window cannot be dragged below what its widest row demands.
        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = 8
        actionRow.translatesAutoresizingMaskIntoConstraints = false
        actionRow.addView(confirmShownButton, in: .trailing)
        actionRow.addView(applyButton, in: .trailing)

        let panes = NSStackView(views: [leftPane, rightPane])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 12
        panes.translatesAutoresizingMaskIntoConstraints = false

        // The file list holds its width; the two panes split the rest.
        let middle = NSView()
        middle.translatesAutoresizingMaskIntoConstraints = false
        middle.addSubview(fileScroll)
        middle.addSubview(panes)
        NSLayoutConstraint.activate([
            fileScroll.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
            fileScroll.topAnchor.constraint(equalTo: middle.topAnchor),
            fileScroll.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            panes.leadingAnchor.constraint(equalTo: fileScroll.trailingAnchor, constant: 12),
            panes.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
            panes.topAnchor.constraint(equalTo: middle.topAnchor),
            panes.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
        ])

        let content = NSStackView(views: [
            filterRow, groupScroll, headerLabel, warningLabel, middle, pairLabel, adviceLabel,
            decisionRow, actionRow, tallyLabel, footerLabel,
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
            // **Every full-width row is pinned**, or a leading-aligned row has no width of its own and AutoLayout
            // keeps whatever width it last had -- the folder viewer's decision row, found by `make ui` (#211).
            groupScroll.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            middle.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            actionRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            decisionRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -28),
            groupScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            // **A cap, not a minimum.** Without it the group list takes every extra point of height and the two
            // pictures stay at their floor -- which shipped once, with a thumbnail the size of a postage stamp. The
            // comparison is the reason this window exists, so the lists are the parts that get bounded.
            groupScroll.heightAnchor.constraint(
                lessThanOrEqualTo: container.heightAnchor, multiplier: 0.3),
            // 280 since the «Name» column (#228): at 240 it left the file names three characters wide.
            fileScroll.widthAnchor.constraint(equalToConstant: 280),
            panes.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            // **As tall as their row** (#214). A horizontal stack centres its views rather than stretching them, so a
            // pane could be anything from its content's height to the row's, and the thumbnail landed wherever the
            // last layout left it.
            leftPane.heightAnchor.constraint(equalTo: panes.heightAnchor),
            rightPane.heightAnchor.constraint(equalTo: panes.heightAnchor),
        ])
        window?.contentView = container
    }

    // MARK: - What is on screen

    private var selectedGroup: Int? {
        let row = groupTable.selectedRow
        return visible.indices.contains(row) ? visible[row] : nil
    }

    private func rebuildVisible() {
        let selected = selectedGroup
        visible = filter.matchingGroupIndices(in: review.groups) { review.groupState(at: $0) }
        groupTable.reloadData()
        countLabel.stringValue = String(
            format: Strings.string("similar.filter.count"), visible.count,
            Strings.count("count.groups", review.groups.count))
        let undecided = shownUndecidedGroups.count
        confirmShownButton.title = String(format: Strings.string("review.acceptShown"), undecided)
        confirmShownButton.isEnabled = undecided > 0
        // The selection follows the group, not the row: a filter that removes rows above it would otherwise move
        // the selection to a different group without saying so.
        if let selected, let row = visible.firstIndex(of: selected) {
            groupTable.selectRowIndexes([row], byExtendingSelection: false)
        } else if let next = visible.firstIndex(where: { $0 > (selected ?? -1) })
            ?? visible.indices.first
        {
            // The group left the filter -- decided with "not decided yet" on. The next one shown after it, not the
            // first: going back to the top after every decision is how a review loses its place.
            groupTable.selectRowIndexes([next], byExtendingSelection: false)
            groupTable.scrollRowToVisible(next)
        }
        refreshDetail()
    }

    /// The groups shown that nobody has decided: what the accept button acts on.
    private var shownUndecidedGroups: [Int] {
        visible.filter { review.groupState(at: $0) == .undecided }
    }

    private func refreshDetail(keepingCompared: Bool = false) {
        refreshFooter()
        refreshTally()
        guard let index = selectedGroup else {
            headerLabel.stringValue = Strings.string("similar.empty")
            warningLabel.isHidden = true
            pairLabel.stringValue = ""
            adviceLabel.stringValue = ""
            fileOrder = []
            reference = nil
            compared = nil
            fileTable.reloadData()
            leftPane.showEmpty()
            rightPane.showEmpty()
            for button in [confirmButton, keepAllButton, skipButton] { button.isEnabled = false }
            return
        }
        for button in [confirmButton, keepAllButton, skipButton] { button.isEnabled = true }
        let group = review.groups[index]
        let previous = keepingCompared ? compared : nil
        let previousCursor = keepingCompared ? cursor : nil
        fileOrder = review.rankedFiles(inGroup: index)
        let keep = review.effectiveKeep(inGroup: index)
        let best = fileOrder.first { keep.contains($0) } ?? fileOrder.first
        reference = best
        compared =
            previous.flatMap { fileOrder.contains($0) && $0 != best ? $0 : nil }
            ?? fileOrder.first { $0 != best }
        cursor = previousCursor.flatMap { fileOrder.contains($0) ? $0 : nil } ?? compared
        fileTable.reloadData()
        if let cursor, let row = fileOrder.firstIndex(of: cursor) {
            fileTable.selectRowIndexes([row], byExtendingSelection: false)
            fileTable.scrollRowToVisible(row)
        }

        headerLabel.stringValue = String(
            format: Strings.string("similar.group.header"),
            (visible.firstIndex(of: index) ?? 0) + 1, visible.count,
            Strings.count("count.files", group.files.count))
        // The name it will have, said where the group is named: the radio column says whose, this says what (#228).
        if let rename = review.rename(inGroup: index) {
            headerLabel.stringValue += String(
                format: Strings.string("similar.group.keepsAs"),
                (rename.targetPath as NSString).lastPathComponent)
        }
        refreshWarning(index: index, keep: keep)
        showPanes(group: group)
        refreshAdvice(index: index)
        probeFactsIfNeeded(index: index)
    }

    /// What a reader has to know before confirming, most urgent first: a file confirming would refuse, then pair
    /// decisions that do not add up, then a group whose members are not all alike to each other.
    private func refreshWarning(index: Int, keep: Set<Int>) {
        let group = review.groups[index]
        var text = ""
        if let lonely = review.unmatched(keep: keep, inGroup: index).first {
            text = String(
                format: Strings.string("similar.group.unmatched"),
                (group.files[lonely] as NSString).lastPathComponent)
        } else if review.groupState(at: index) == .mixed {
            text = Strings.string("similar.group.mixed")
        } else if !group.isFullyLinked {
            text = Strings.string("similar.group.chained")
        }
        warningLabel.stringValue = text
        warningLabel.isHidden = text.isEmpty
    }

    private func showPanes(group: SimilarGroup) {
        if let reference {
            let path = group.files[reference]
            leftPane.show(path: path, thumbnailer: thumbnailer)
            if let known = facts[Array(path.utf8)] { leftPane.show(facts: known) }
        } else {
            leftPane.showEmpty()
        }
        if let compared {
            let path = group.files[compared]
            rightPane.show(path: path, thumbnailer: thumbnailer)
            if let known = facts[Array(path.utf8)] { rightPane.show(facts: known) }
        } else {
            rightPane.showEmpty()
        }
    }

    /// The pair on screen and why one of the two would stay, or that the two were never compared.
    private func refreshAdvice(index: Int) {
        let group = review.groups[index]
        guard let reference, let compared,
            let link = group.link(between: reference, and: compared),
            scan.pairs.indices.contains(link.pairIndex)
        else {
            pairLabel.stringValue = ""
            adviceLabel.stringValue =
                reference != nil && compared != nil
                ? Strings.string("similar.group.notCompared") : ""
            return
        }
        let pair = scan.pairs[link.pairIndex]
        // The pair's own number: bits for an image, the share of matching frames for a video.
        pairLabel.stringValue = similarHeaderText(
            pair: pair, durationA: facts[Array(pair.fileA.utf8)]?.duration,
            durationB: facts[Array(pair.fileB.utf8)]?.duration)
        guard let suggestion = review.suggestion(at: link.pairIndex) else {
            adviceLabel.stringValue = ""
            return
        }
        let winner = suggestion.decision == .keepB ? link.b : link.a
        let name = (group.files[winner] as NSString).lastPathComponent
        adviceLabel.stringValue = String(
            format: Strings.string("similar.suggested"),
            String(format: Strings.string("similar.group.keepName"), name) + " - "
                + SimilarAdviceText.explanation(for: suggestion.ground))
    }

    private func refreshTally() {
        let tally = review.groupTally
        tallyLabel.stringValue = String(
            format: Strings.string("similar.tally"), Strings.count("count.decided", tally.decided),
            Strings.count("count.skipped", tally.skipped), tally.undecided)
    }

    /// Probes the members of the group being looked at, then refines the suggestions of its pairs.
    ///
    /// **Lazily.** Probing all 2,460 files of a real scan up front would repeat a large part of the scan. A group is at
    /// most a few dozen files -- 27 videos is the largest in this user's scans.
    ///
    /// **What a probe read is kept even if the selection moved on**, and only the redraw depends on it (#219). Its
    /// paths are marked as tried when it starts, so dropping a late answer -- which a generation counter here did --
    /// lost that group's resolution, codec and duration for good, and its suggestion never used them.
    private func probeFactsIfNeeded(index: Int) {
        let group = review.groups[index]
        let missing = group.files.filter { !probed.contains(Array($0.utf8)) }
        guard !missing.isEmpty else { return }
        for path in missing { probed.insert(Array(path.utf8)) }
        probeLaunches += 1
        probesInFlight += 1
        let kind = group.mediaKind
        let probe = self.probe
        Task { @MainActor [weak self] in
            var found: [(String, MediaFacts)] = []
            for path in missing {
                let fact: MediaFacts? =
                    switch kind {
                    case .image: probe.facts(ofImage: path)
                    case .video: await probe.facts(ofVideo: path)
                    }
                if let fact { found.append((path, fact)) }
            }
            guard let self else { return }
            self.probesInFlight -= 1
            for (path, fact) in found { self.facts[Array(path.utf8)] = fact }
            for link in group.links {
                let pair = self.scan.pairs[link.pairIndex]
                self.review.updateSuggestion(
                    at: link.pairIndex, factsA: self.facts[Array(pair.fileA.utf8)],
                    factsB: self.facts[Array(pair.fileB.utf8)])
            }
            // The group's row names its best file, which the probe can change.
            if let row = self.visible.firstIndex(of: index) {
                self.groupTable.reloadData(
                    forRowIndexes: IndexSet(integer: row),
                    columnIndexes: IndexSet(integersIn: 0..<self.groupTable.numberOfColumns))
            }
            // A better suggestion can reorder the list and change the file on the left, so the whole detail is
            // redrawn -- the right pane stays on the file the reader was looking at.
            guard self.selectedGroup == index else { return }
            self.refreshDetail(keepingCompared: true)
        }
    }

    /// Warns when one file is kept by one pair and discarded by another, or when a saved key cannot be parsed.
    ///
    /// **Shown on close rather than on every click**: the conflict only matters when the set of decisions is done
    /// with. Deciding groups cannot produce one; pair decisions read from disk can.
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
    /// **Split because a scan can hold either kind alone.** A single total would read as "there is no video here"
    /// when it means "this scan did not look".
    private func refreshFooter() {
        footerLabel.stringValue = footerString()
        footerLabel.textColor = saveFailure == nil ? .secondaryLabelColor : .systemOrange
    }

    private func footerString() -> String {
        var text = String(
            format: Strings.string("similar.footer"),
            Strings.count("count.imagePairs", scan.pairCount(of: .image)),
            Strings.count("count.bits", scan.imageThreshold),
            Strings.count("count.videoPairs", scan.pairCount(of: .video)),
            Int(scan.videoThreshold * 100)
        )
        if let saveFailure {
            // First, and in orange: the footer is one line truncated in the middle, and a failure at its end was
            // the part the ellipsis hid.
            return Strings.string("review.saveFailed.title") + ": " + saveFailure + "  -  " + text
        }
        if savedCount > 0 { text += "  -  " + Strings.string("similar.saved") }
        return text
    }

    /// The size on disk, or zero when it cannot be read.
    private static func fileSize(_ path: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let size = attributes[.size] as? Int64
        else { return 0 }
        return size
    }

    // MARK: - Actions

    @objc private func filterChanged(_ sender: Any?) {
        filter = PairFilter(
            minimumSimilarity: (similarityPopup.selectedItem?.representedObject as? Double) ?? 0,
            kind: (kindPopup.selectedItem?.representedObject as? String).flatMap(
                MediaKind.init(rawValue:)),
            onlyUndecided: undecidedToggle.state == .on
        )
        rebuildVisible()
    }

    /// Accepts the suggestion for every group shown that nobody has decided.
    ///
    /// **The sheet names what it will cost before it happens**, and the counts come from the review rather than
    /// from the filter: the files that would move. Nothing moves here -- this writes decisions, and applying is
    /// still its own step behind its own gate.
    ///
    /// **Only the shown, undecided groups.** That is the invariant that keeps this from becoming the "decide
    /// everything" button the CLI has: every group handed to `confirmGroups` is one this window put on screen, and
    /// a skipped, decided or mixed group carries a choice somebody made.
    @objc private func confirmShown(_ sender: Any?) {
        let indices = shownUndecidedGroups
        guard let window else { return }
        guard !indices.isEmpty else {
            NSSound.beep()
            return
        }
        let plan = previewAccept(indices)
        // **A `stat` per file, and that is the cost of saying the number.** The alternative is a sheet that says
        // "some files" and asks for a destructive decision anyway.
        let bytes = plan.items.reduce(Int64(0)) { total, item in
            total + Self.fileSize(item.path)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: Strings.string("similar.confirmShown.title"),
            Strings.count("count.groups", indices.count))
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
            MainActor.assumeIsolated { self.accept(indices) }
        }
    }

    /// What accepting would plan, **computed on a copy** so the question can be asked before the answer is taken --
    /// and so Cancel leaves the window exactly as it was. Weighing the live review here changed suggestions before
    /// the answer, and a Cancel left the old box checked over a keep set that had moved (found in review on #225).
    private func previewAccept(_ indices: [Int]) -> SimilarApplyPlan {
        var preview = review
        weighBySize(indices, in: &preview)
        preview.confirmGroups(indices)
        return SimilarApplyPlan.from(preview)
    }

    /// What the sheet's Accept does: weigh, then decide, as **one undo step** -- accepting 800 groups and undoing them
    /// one at a time would not be an undo. The weighing is here, on the path the button takes, so a harness that
    /// accepts through this function cannot pass with the button's half removed.
    private func accept(_ indices: [Int]) {
        mutate { state in
            weighBySize(indices, in: &state)
            state.confirmGroups(indices)
        }
    }

    /// Gives the files of these groups that no probe has read their size on disk, and refines their suggestions.
    ///
    /// **So a batch decides on quality too** (#223). Quality comes before the name, but a group nobody opened has no
    /// facts -- probing reads every file, 300 ms a video -- so its suggestion fell through to the copy-looking name.
    /// The size is a `stat`, which the sheet below already pays per file to say how much would move. Resolution and
    /// codec still arrive when a group is opened, and refine the suggestion again.
    ///
    /// **Like against like.** When only one file of a pair was probed, both are weighed by size alone: a resolution
    /// against an unknown that reads as zero pixels would win every time, whatever the files are.
    private func weighBySize(_ indices: [Int], in state: inout SimilarReviewState) {
        func sizeOnly(_ path: String) -> MediaFacts? {
            let size = Self.fileSize(path)
            return size > 0
                ? MediaFacts(path: path, byteCount: size, pixelWidth: 0, pixelHeight: 0) : nil
        }
        for index in indices {
            for link in state.groups[index].links {
                let pair = scan.pairs[link.pairIndex]
                let probedA = facts[Array(pair.fileA.utf8)]
                let probedB = facts[Array(pair.fileB.utf8)]
                guard probedA == nil || probedB == nil else { continue }
                state.updateSuggestion(
                    at: link.pairIndex, factsA: sizeOnly(pair.fileA), factsB: sizeOnly(pair.fileB))
            }
        }
    }

    /// Records the keep set on screen and moves on. The Group menu's Confirm (⌘↩) arrives here too.
    @objc func confirmGroup(_ sender: Any?) {
        guard let index = selectedGroup else { return }
        var outcome: SimilarReviewState.GroupConfirmOutcome = .noSuchGroup
        mutate { outcome = $0.confirmGroup(index) }
        switch outcome {
        case .confirmed: advance(from: index)
        // The warning line already names the file; the beep says the button heard the click and declined.
        case .nothingKept, .unmatched, .noSuchGroup: NSSound.beep()
        }
    }

    /// Keeps every member: nothing in the group moves.
    @objc func keepAll(_ sender: Any?) {
        guard let index = selectedGroup else { return }
        let everyone = Set(review.groups[index].files.indices)
        mutate { _ = $0.confirmGroup(index, keep: everyone) }
        advance(from: index)
    }

    /// Passes over the group without deciding it. The Group menu's Skip (⇧⌘K) arrives here too.
    @objc func skipGroup(_ sender: Any?) {
        guard let index = selectedGroup else { return }
        mutate { $0.skipGroup(index) }
        advance(from: index)
    }

    /// Checks or unchecks a member: the space bar, on the row selected in the list -- or on the right pane's file
    /// when the group list has the focus.
    private func toggle(member: Int?) {
        guard let member else { return }
        toggle(file: member)
    }

    private func toggle(file: Int) {
        guard let index = selectedGroup else { return }
        var accepted = true
        mutate(saving: false) { accepted = $0.toggleKeep(file, inGroup: index) }
        if !accepted { NSSound.beep() }
    }

    @objc private func keepCheckboxToggled(_ sender: NSButton) {
        guard fileOrder.indices.contains(sender.tag) else { return }
        toggle(file: fileOrder[sender.tag])
    }

    /// The kept file takes this row's name, or -- on the kept file's own row -- keeps its own (#228).
    ///
    /// **Saved at once, like a decision**, and undoable like one; but it is not a decision, so it goes to its own
    /// document and never into the CLI's.
    @objc private func nameChosen(_ sender: NSButton) {
        guard let index = selectedGroup, fileOrder.indices.contains(sender.tag) else { return }
        var accepted = true
        mutate(saving: false) { accepted = $0.setNameSource(fileOrder[sender.tag], inGroup: index) }
        saveRenames()
        refreshFooter()
        if !accepted { NSSound.beep() }
    }

    /// Moves to the next group, which is what makes deciding a rhythm rather than a click-and-hunt. With "not
    /// decided yet" on, the decided group has already left the list and the selection moved with it.
    private func advance(from index: Int) {
        guard !filter.onlyUndecided, let row = visible.firstIndex(of: index) else { return }
        let next = row + 1
        guard visible.indices.contains(next) else { return }
        groupTable.selectRowIndexes([next], byExtendingSelection: false)
        groupTable.scrollRowToVisible(next)
    }

    /// Applies a change to the review and registers its inverse with the undo manager.
    ///
    /// **The whole state is captured, not a delta** -- the same trade the exact review makes. It is a dictionary of
    /// small enums over at most a few thousand pairs, so a snapshot costs less than the bookkeeping a delta needs,
    /// and an undo that restores a snapshot cannot drift from the operation it reverses.
    ///
    /// **And the undo saves too.** Decisions here are written as they are made, so an undo that only changed memory
    /// would leave the file holding a decision the window no longer shows -- and the CLI reading it.
    private func mutate(saving: Bool = true, _ body: (inout SimilarReviewState) -> Void) {
        // **Grouped explicitly rather than by event, and never while undoing.** `UndoManager` groups every
        // registration made in one turn of the run loop, which is right for typing and wrong for a batch: accepting
        // 800 groups in one call would otherwise be indistinguishable from one decision. And opening a group inside
        // `undo()` breaks the manager's own phase tracking, so the registration an undo makes lands back on the undo
        // stack instead of the redo stack.
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
        if saving { saveDecisions() }
        if saving {
            rebuildVisible()
        } else {
            // A toggle changes one group's keep set: the lists stay, the detail redraws on the same file.
            groupTable.reloadData(
                forRowIndexes: IndexSet(integer: groupTable.selectedRow),
                columnIndexes: IndexSet(integersIn: 0..<groupTable.numberOfColumns))
            refreshDetail(keepingCompared: true)
        }
    }

    /// Writes what has been decided, and **only** what has been decided -- then the names chosen beside it.
    private func saveDecisions() {
        let document = review.decisionsForSaving
        do {
            _ = try ScanStore(state: stateDirectory).save(document, scanID: scan.scanID)
            savedCount = document.count
            saveFailure = nil
        } catch {
            // Reported in the footer rather than in a sheet: losing a decision matters, and a modal over every
            // click would make deciding hundreds of groups impossible. The localized description:
            // `String(describing:)` is the whole `NSError`, `UserInfo` and all, which no footer can show.
            saveFailure = error.localizedDescription
            return
        }
        saveRenames()
    }

    private func saveRenames() {
        do {
            try ScanStore(state: stateDirectory).save(review.renamesForSaving, scanID: scan.scanID)
        } catch {
            // In the footer, for the reason a decision's failure is.
            saveFailure = error.localizedDescription
        }
    }

    /// Asks, once, about a decisions file that covers every pair (#155).
    ///
    /// The CLI writes a decision for every pair it was shown: 17 of the 18 perceptual decision files in this user's
    /// corpus cover every pair. Shown as decided with no word, those marks read as the user's own and pressing
    /// Simulate plans over all of them. Starting over here also clears the file, because this viewer saves every
    /// change -- which the text says.
    func presentImportWarningIfNeeded() {
        guard provenance.deservesAWarning, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            format: Strings.string("similar.imported.title"), provenance.decidedCount)
        alert.informativeText = Strings.string("similar.imported.body")
        alert.addButton(withTitle: Strings.string("review.imported.keep"))
        alert.addButton(withTitle: Strings.string("review.imported.discard"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            MainActor.assumeIsolated { self.clearImportedDecisions() }
        }
    }

    /// Drops every decision, as one undoable step that is saved like any other.
    private func clearImportedDecisions() {
        mutate { state in
            for index in state.scan.pairs.indices { state.clearDecision(at: index) }
        }
        provenance = .none
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
            self?.refreshDetail(keepingCompared: true)
        }
        sheet.onUndone = { [weak self] in self?.refreshDetail(keepingCompared: true) }
        applySheet = sheet
        if let window, let sheetWindow = sheet.window {
            window.beginSheet(sheetWindow) { [weak self] _ in self?.applySheet = nil }
        } else {
            sheet.showWindow(nil)
        }
    }

    /// A double click on a file of the list opens it (#226).
    @objc private func openClickedFile(_ sender: Any?) {
        let row = fileTable.clickedRow >= 0 ? fileTable.clickedRow : fileTable.selectedRow
        guard let index = selectedGroup, fileOrder.indices.contains(row) else { return }
        openFile(review.groups[index].files[fileOrder[row]])
    }

    @objc private func revealSelected(_ sender: Any?) {
        guard let index = selectedGroup, let reference else { return }
        Reveal.item(at: review.groups[index].files[reference])
    }

    /// Opens Quick Look on **every member** of the group, best first, or closes it.
    ///
    /// Every member, because the panel's arrow keys then become the comparison: this is the full-size version of
    /// what the panes show two at a time.
    @objc func toggleQuickLook(_ sender: Any?) {
        _ = quickLook.toggle(paths: quickLookPaths(), controller: self)
    }

    private func quickLookPaths() -> [String] {
        guard let index = selectedGroup else { return [] }
        return fileOrder.map { review.groups[index].files[$0] }
    }

    /// Shows every member in Finder.
    ///
    /// **All of them, and that is the honest answer to an ambiguous request.** A group has several files and the
    /// menu item says "in Finder"; picking one silently would be picking for the user.
    @objc func revealSelectedFile(_ sender: Any?) {
        let urls = quickLookPaths()
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

    var groupRowCount: Int { groupTable.numberOfRows }
    var headerText: String { headerLabel.stringValue }
    var pairText: String { pairLabel.stringValue }
    var warningText: String { warningLabel.isHidden ? "" : warningLabel.stringValue }

    var leftMetadataForSelftest: (text: String, hidden: Bool) { leftPane.metadataForSelftest }
    var rightMetadataForSelftest: (text: String, hidden: Bool) { rightPane.metadataForSelftest }

    /// Waits for the media probe of the selected group, so an assertion is not a race against a decode.
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
    var groupTallyForSelftest: (decided: Int, skipped: Int, undecided: Int) { review.groupTally }
    var groupStatesForSelftest: [SimilarGroupState] {
        review.groups.indices.map { review.groupState(at: $0) }
    }
    var warnsAboutImportedForSelftest: Bool { provenance.deservesAWarning }
    func discardImportedForSelftest() { clearImportedDecisions() }
    var contradictionsForSelftest: [String] { review.contradictions }

    var ambiguousKeysForSelftest: [String] { review.ambiguousKeys }

    var applySheetForSelftest: SimilarApplySheetController? { applySheet }

    func simulateForSelftest() { simulateAndApply(nil) }
    /// What the sheet would list, without opening one.
    var applyPlanForSelftest: SimilarApplyPlan { SimilarApplyPlan.from(review) }

    var shownCountForSelftest: Int { visible.count }
    var countText: String { countLabel.stringValue }
    var acceptShownButtonForSelftest: (title: String, enabled: Bool) {
        (confirmShownButton.title, confirmShownButton.isEnabled)
    }

    func setFilterForSelftest(minimumSimilarity: Double = 0, onlyUndecided: Bool = false) {
        filter = PairFilter(minimumSimilarity: minimumSimilarity, onlyUndecided: onlyUndecided)
        rebuildVisible()
    }

    /// What the accept button does once its sheet is answered. The sheet is modal and cannot be clicked from here,
    /// so the groups come from the same property the button reads.
    func confirmShownForSelftest() { accept(shownUndecidedGroups) }
    /// What the button computes before its sheet asks, without asking.
    func previewAcceptForSelftest() { _ = previewAccept(shownUndecidedGroups) }

    func undoForSelftest() { undo.undo() }
    var canUndoForSelftest: Bool { undo.canUndo }

    func selectGroupForSelftest(_ row: Int) {
        guard visible.indices.contains(row) else { return }
        groupTable.selectRowIndexes([row], byExtendingSelection: false)
        refreshDetail()
    }

    /// The «Name» radios as drawn, through the table's own cells: whether each is on, and whether it can be pressed.
    var nameRadiosForSelftest: [(on: Bool, enabled: Bool)] {
        fileOrder.indices.compactMap { row in
            let column = fileTable.column(withIdentifier: .init("takeName"))
            guard column >= 0,
                let radio = fileTable.view(atColumn: column, row: row, makeIfNecessary: true)
                    as? NSButton
            else { return nil }
            return (radio.state == .on, radio.isEnabled)
        }
    }

    /// Clicks a row's «Name» radio: the cell's own button, so its target and action are what is tested.
    func clickNameForSelftest(row: Int) {
        let column = fileTable.column(withIdentifier: .init("takeName"))
        guard column >= 0,
            let radio = fileTable.view(atColumn: column, row: row, makeIfNecessary: true)
                as? NSButton
        else { return }
        radio.performClick(nil)
    }

    /// The file list as drawn: each member's path and whether its box is checked.
    var fileRowsForSelftest: [(path: String, kept: Bool)] {
        guard let index = selectedGroup else { return [] }
        let keep = review.effectiveKeep(inGroup: index)
        return fileOrder.map { (review.groups[index].files[$0], keep.contains($0)) }
    }

    /// Clicks the checkbox of a row, through the same action a real click sends.
    func clickKeepForSelftest(row: Int) {
        let probe = NSButton()
        probe.tag = row
        keepCheckboxToggled(probe)
    }

    func pressConfirmForSelftest() { confirmButton.performClick(nil) }
    func pressOpenForSelftest(left: Bool) { (left ? leftPane : rightPane).pressOpenForSelftest() }
    func pressRevealForSelftest(left: Bool) {
        (left ? leftPane : rightPane).pressRevealForSelftest()
    }
    /// Each of the four buttons on its own: one `&&` over them let a single disabled button pass for all four
    /// (found in review on #227).
    var paneButtonsEnabledForSelftest: [Bool] { leftPane.buttonsEnabled + rightPane.buttonsEnabled }
    /// A double click, through the table's own `doubleAction` and target -- calling `openClickedFile` directly would
    /// pass with the wiring removed.
    func doubleClickFileForSelftest(_ row: Int) {
        fileTable.selectRowIndexes([row], byExtendingSelection: false)
        guard let action = fileTable.doubleAction else { return }
        NSApp.sendAction(action, to: fileTable.target, from: fileTable)
    }

    /// Selects a row of the file list the way a click or an arrow key does, delegate included.
    func selectFileForSelftest(_ row: Int) {
        guard fileOrder.indices.contains(row) else { return }
        fileTable.selectRowIndexes([row], byExtendingSelection: false)
        tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: fileTable))
    }

    /// The space bar in the file list, through the closure the table calls.
    func pressSpaceInFileListForSelftest() { fileTable.onToggle?() }

    /// How many probes this window started. One per group: a file that cannot be read is not asked again.
    var probeLaunchesForSelftest: Int { probeLaunches }
    var probesInFlightForSelftest: Int { probesInFlight }
    func pressSkipForSelftest() { skipButton.performClick(nil) }

    private func groupText(for index: Int, column: String) -> String {
        let group = review.groups[index]
        switch column {
        case "similarity":
            // Two decimals, for the same reason as folders: 0.95 and 0.9473 are different answers and rounding
            // both to 95% hides one of them. A range when the pairs disagree.
            let low = String(format: "%.2f%%", group.lowestSimilarity * 100)
            guard group.highestSimilarity != group.lowestSimilarity else { return low }
            return low + "\u{2013}" + String(format: "%.2f%%", group.highestSimilarity * 100)
        case "kind":
            return Strings.string(
                group.mediaKind == .image ? "similar.kind.image" : "similar.kind.video")
        case "files": return "\(group.files.count)"
        case "name":
            let best = review.rankedFiles(inGroup: index).first ?? 0
            return (group.files[best] as NSString).lastPathComponent
        case "decision":
            switch review.groupState(at: index) {
            case .decided(let keep):
                return String(
                    format: Strings.string("similar.group.state.keeps"), keep.count,
                    group.files.count)
            case .skipped: return Strings.string("similar.state.skipped")
            case .mixed: return Strings.string("similar.group.state.mixed")
            case .undecided: return Strings.string("similar.state.undecided")
            }
        default: return ""
        }
    }
}

extension SimilarPairWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === fileTable ? fileOrder.count : visible.count
    }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        let identifier = tableColumn.identifier
        if tableView === fileTable {
            return fileCell(column: identifier.rawValue, row: row)
        }
        guard visible.indices.contains(row) else { return nil }
        let cell = labelCell(in: tableView, identifier: identifier)
        let index = visible[row]
        cell.textField?.stringValue = groupText(for: index, column: identifier.rawValue)
        cell.textField?.alignment = identifier.rawValue == "files" ? .right : .natural
        cell.textField?.toolTip =
            identifier.rawValue == "name"
            ? review.groups[index].files.joined(separator: "\n") : nil
        return cell
    }

    private func fileCell(column: String, row: Int) -> NSView? {
        guard let index = selectedGroup, fileOrder.indices.contains(row) else { return nil }
        let group = review.groups[index]
        let member = fileOrder[row]
        let keep = review.effectiveKeep(inGroup: index)
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
            button.state = keep.contains(member) ? .on : .off
            button.tag = row
            return button
        }
        if column == "takeName" {
            let radio =
                fileTable.makeView(withIdentifier: .init("takeName"), owner: self) as? NSButton
                ?? {
                    let created = NSButton(
                        radioButtonWithTitle: "", target: self, action: #selector(nameChosen(_:)))
                    created.identifier = .init("takeName")
                    return created
                }()
            // **Only with one file kept**: with two, "this file under that name" names no file. The kept file's own
            // radio is on until another is chosen. Each cell is its own superview, so AppKit does not group these:
            // the table redraws them all from the state on every change.
            let holder = review.nameSource(inGroup: index) ?? (keep.count == 1 ? keep.first : nil)
            radio.state = member == holder ? .on : .off
            radio.isEnabled = keep.count == 1
            radio.tag = row
            return radio
        }
        let cell = labelCell(in: fileTable, identifier: .init(column))
        let path = group.files[member]
        cell.textField?.stringValue = (path as NSString).lastPathComponent
        cell.textField?.toolTip = path
        cell.textField?.textColor = keep.contains(member) ? .labelColor : .secondaryLabelColor
        return cell
    }

    private func labelCell(
        in tableView: NSTableView, identifier: NSUserInterfaceItemIdentifier
    )
        -> NSTableCellView
    {
        tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? {
                let created = NSTableCellView()
                created.identifier = identifier
                let field = NSTextField(labelWithString: "")
                // **Middle truncation.** Copies of one file share a long prefix and differ at the end -- `clip.mp4`
                // against `clip (1).mp4` -- so cutting either end hides the one thing that tells them apart.
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
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        if table === fileTable {
            // A row is the file the space bar acts on, and the file to compare: the right pane follows it, unless
            // it is the keeper already on the left. **The row stays selected even then**, or the keyboard could never
            // reach the keeper to uncheck it (#219): the list used to bounce the selection back to the right pane's.
            let row = fileTable.selectedRow
            guard fileOrder.indices.contains(row), let index = selectedGroup else { return }
            let member = fileOrder[row]
            cursor = member
            guard member != compared, member != reference else { return }
            compared = member
            showPanes(group: review.groups[index])
            refreshAdvice(index: index)
        } else {
            refreshDetail()
        }
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
    /// **A way to the file itself** (#226): the thumbnail says the two look alike; opening one is how to be sure. These
    /// existed only as ⌘Y and a menu item, which nothing on screen pointed to.
    private let openButton = NSButton()
    private let revealButton = NSButton()
    var onOpen: ((String) -> Void)?
    var onReveal: ((String) -> Void)?
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
        }
        // **Nothing in a pane decides how wide the window is.** Below the priority `fittingSize` presses with, so
        // the thumbnail and a full path give way to the window instead of setting its minimum. At `.defaultLow`
        // each pane was as wide as its thumbnail -- 218 points, an image's pixels read as points -- and with the
        // group's file list beside the panes (#217) the viewer demanded 728 points against the 720 it advertises.
        let yielding = NSLayoutConstraint.Priority(
            NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        for view in [imageView, nameLabel, pathLabel, stateLabel, metadataLabel] as [NSView] {
            view.setContentCompressionResistancePriority(yielding, for: .horizontal)
        }

        openButton.title = Strings.string("similar.pane.open")
        openButton.target = self
        openButton.action = #selector(openPressed(_:))
        // Same title as the menu item, on purpose: two names for one action is how someone looks for a second thing.
        revealButton.title = Strings.string("menu.group.revealFile")
        revealButton.target = self
        revealButton.action = #selector(revealPressed(_:))
        for button in [openButton, revealButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        let actions = NSStackView(views: [openButton, revealButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        // As wide as its two buttons, and below their resistance, or its width is ambiguous (#214).
        actions.setHuggingPriority(.init(740), for: .horizontal)

        let stack = NSStackView(views: [
            imageView, nameLabel, pathLabel, metadataLabel, stateLabel, actions,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        // The picture takes the pane's spare height; the lines under it keep to their text (#214).
        stack.distribution = .fill
        imageView.setContentHuggingPriority(.init(1), for: .vertical)
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

    @objc private func openPressed(_ sender: Any?) {
        if let currentPath { onOpen?(currentPath) }
    }

    @objc private func revealPressed(_ sender: Any?) {
        if let currentPath { onReveal?(currentPath) }
    }

    var buttonsEnabled: [Bool] { [openButton.isEnabled, revealButton.isEnabled] }
    func pressOpenForSelftest() { openButton.performClick(nil) }
    func pressRevealForSelftest() { revealButton.performClick(nil) }

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
        openButton.isEnabled = false
        revealButton.isEnabled = false
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
        // A file that is gone has nothing to open and no folder to be selected in.
        openButton.isEnabled = exists
        revealButton.isEnabled = exists
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
            Strings.count(
                "similar.header.bitsDiffer", Int(((1.0 - pair.similarity) * 64.0).rounded()))
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
