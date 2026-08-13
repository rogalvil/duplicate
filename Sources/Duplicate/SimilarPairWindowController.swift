import AppKit
import DuplicateCore

/// Shows the pairs of one perceptual scan, side by side.
///
/// **Two thumbnails, not a list of paths, because that is the only way to judge this detector.** An exact
/// duplicate can be decided from its digest; a perceptual pair cannot. The app is claiming two files *look*
/// alike, and the user is the only one who can say whether that is true -- so the two pictures have to be on
/// screen next to each other, at the same size.
///
/// **Read-only, on purpose, and for a different reason than the folder viewer.** There the danger was deleting
/// a tree that was only mostly a copy; here it is that a pair at distance 5 can be two genuinely different
/// photographs -- a burst of the same scene, two frames of one video, the same product on two backgrounds. A
/// "move the second one to the Trash" button next to a list this app produced would be inviting the user to
/// act on a guess. Deciding these needs its own review flow and its own decisions file
/// (`similar-decisions`, a bare `{"a||b": "keep_a"}` map), which is not this change.
///
/// It shows video pairs too, even though this build cannot produce them: a scan written by `rav duplicate
/// similar` carries them, and refusing to display what the document holds would be its own kind of lie.
@MainActor
final class SimilarPairWindowController: NSWindowController {

    private let scan: SimilarScan
    private let pairs: [SimilarPair]
    private let table = NSTableView()
    private let thumbnailer = QuickLookThumbnailer()
    private let leftPane = SimilarSidePane()
    private let rightPane = SimilarSidePane()
    private let headerLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")

    init(scan: SimilarScan) {
        self.scan = scan
        self.pairs = scan.pairs

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

        for label in [headerLabel, footerLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingMiddle
        }
        footerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        footerLabel.textColor = .secondaryLabelColor

        let panes = NSStackView(views: [leftPane, rightPane])
        panes.orientation = .horizontal
        panes.distribution = .fillEqually
        panes.spacing = 12
        panes.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [scroll, headerLabel, panes, footerLabel])
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

    private var selectedPair: SimilarPair? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return pairs.indices.contains(row) ? pairs[row] : nil
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
    }

    /// The counts, split by kind, and the two thresholds.
    ///
    /// **Split because this build only produces one of the two.** A scan it wrote has no video pairs at all, so
    /// a single total would read as "there is no video here" when it means "this app did not look".
    private func footerString() -> String {
        String(
            format: Strings.string("similar.footer"),
            scan.pairCount(of: .image), scan.imageThreshold,
            scan.pairCount(of: .video), Int(scan.videoThreshold * 100)
        )
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
