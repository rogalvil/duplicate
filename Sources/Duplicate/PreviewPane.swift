import AppKit
@preconcurrency import CoreGraphics
import DuplicateCore

/// Shows the file under the cursor before the user decides to remove it.
///
/// **The reason the app exists rather than the CLI.** In a terminal you decide between two paths by reading
/// two paths. Here you look at the thing.
///
/// It also carries the line that matters more than the picture: whether the file is **still there**. The
/// oldest scans on this machine are from May and 473 of one scan's 501 paths are gone, so a pane that draws
/// nothing for those would be asking the user to decide about files that no longer exist.
@MainActor
final class PreviewPane: NSView {
    private let imageView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let placeholder = NSTextField(labelWithString: "")

    /// Locale-aware, unlike the byte counts, which are pinned to the CLI's format because they are interop.
    private let dateFormatter: DateFormatter = {
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
    required init?(coder: NSCoder) {
        fatalError("not used: this view is built in code, there is no nib")
    }

    private func build() {
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // No frame drawn: a thumbnail of a photo with a border looks like a photo of a framed photo.
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .systemOrange
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.stringValue = Strings.string("preview.empty")

        let stack = NSStackView(views: [imageView, nameLabel, detailLabel, stateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    /// Shows nothing, for when no row is selected.
    func showPlaceholder() {
        placeholder.isHidden = false
        imageView.isHidden = true
        nameLabel.stringValue = ""
        detailLabel.stringValue = ""
        stateLabel.stringValue = ""
    }

    /// Fills in everything except the image, which arrives separately because it can take time.
    ///
    /// Split on purpose: the name, the size and **whether the file still exists** are known immediately, and
    /// making the user wait on `quicklookd` to learn that the file is gone would be backwards.
    func show(presence: FilePresence, size: Int64) {
        placeholder.isHidden = true
        imageView.isHidden = false
        nameLabel.stringValue = (presence.path as NSString).lastPathComponent
        nameLabel.toolTip = presence.path

        var details = [ByteSize.format(size)]
        if let modified = presence.modifiedAt {
            details.append(dateFormatter.string(from: modified))
        }
        detailLabel.stringValue = details.joined(separator: "  \u{00B7}  ")

        switch presence.state {
        case .present:
            stateLabel.stringValue = ""
        case .missing:
            stateLabel.stringValue = Strings.string("preview.state.missing")
        case .sizeChanged(let onDisk):
            stateLabel.stringValue = String(
                format: Strings.string("preview.state.sizeChanged"),
                ByteSize.format(size), ByteSize.format(onDisk)
            )
        case .unreadable:
            stateLabel.stringValue = Strings.string("preview.state.unreadable")
        case .notAFile:
            stateLabel.stringValue = Strings.string("preview.state.notAFile")
        }
    }

    /// Sets the rendered image, or clears it.
    func show(image: CGImage?) {
        guard let image else {
            imageView.image = nil
            return
        }
        let size = NSSize(width: image.width, height: image.height)
        imageView.image = NSImage(cgImage: image, size: size)
    }

    /// The pane's width in points, for deciding how big a thumbnail to ask for.
    var thumbnailPoints: Double {
        Double(max(64, bounds.width - 16))
    }

    // MARK: - Selftest hooks

    var nameText: String { nameLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    var stateText: String { stateLabel.stringValue }
    var isShowingPlaceholder: Bool { !placeholder.isHidden }
    var hasImage: Bool { imageView.image != nil }
}
