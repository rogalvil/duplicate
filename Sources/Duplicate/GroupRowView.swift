import AppKit

/// One row of the group sidebar: a title line and a detail line.
///
/// A plain `NSTableCellView` with one label had to cram the group number, the size and the file count into
/// 230 points, and clipped to "Grupo 864 - 41.1 KB - 2 ar…". Two lines fit all three and make the number
/// scannable down the column.
@MainActor
final class GroupRowView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        detailField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detailField.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [titleField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        textField = titleField
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used: this view is built in code, there is no nib")
    }
}
