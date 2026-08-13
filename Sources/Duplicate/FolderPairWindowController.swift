import AppKit
import DuplicateCore

/// Shows what a folder scan found.
///
/// **Read-only, and that is a deliberate stopping point.** Removing a folder is not removing a file: a
/// folder that is 95% a copy of another still holds the 5% that is not, and a single click that trashes a
/// tree would be the most dangerous button in the app. Reviewing and applying folder pairs needs its own
/// design and its own decisions format; this window exists so a scan is useful before that lands.
///
/// What it offers instead: the pairs, their overlap, what each side has that the other does not, and Finder.
@MainActor
final class FolderPairWindowController: NSWindowController {
    private let scan: FolderScan
    private var pairs: [FolderPair] = []

    private let table = NSTableView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let detailView = NSTextView()
    private let footerLabel = NSTextField(labelWithString: "")

    init(scan: FolderScan) {
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
        build()
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
        for label in [headerLabel, footerLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.lineBreakMode = .byTruncatingMiddle
        }

        let content = NSStackView(views: [scroll, headerLabel, detailScroll, footerLabel])
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

    private func refreshDetail() {
        guard let pair = selectedPair else {
            headerLabel.stringValue = Strings.string("folders.empty")
            detailView.string = ""
            footerLabel.stringValue = String(
                format: Strings.string("folders.footer"), pairs.count,
                Int(scan.threshold * 100)
            )
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

        footerLabel.stringValue = String(
            format: Strings.string("folders.footer"), pairs.count, Int(scan.threshold * 100))
    }

    @objc private func revealA(_ sender: Any?) {
        guard let pair = selectedPair else { return }
        Reveal.folder(at: pair.folderA)
    }

    @objc private func revealB(_ sender: Any?) {
        guard let pair = selectedPair else { return }
        Reveal.folder(at: pair.folderB)
    }

    // MARK: - Selftest hooks

    var pairRowCount: Int { table.numberOfRows }
    var headerText: String { headerLabel.stringValue }
    var detailText: String { detailView.string }
    var footerText: String { footerLabel.stringValue }
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
