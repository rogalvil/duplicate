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
    /// The **whole** path, not the name.
    ///
    /// Added because of real use: with the group's common parent hoisted into the review's header, the rows
    /// show only the differing tail, and a pane that showed just the file name left no way to tell which of
    /// two identically named files was on screen. Selectable, so it can be copied.
    private let pathLabel = NSTextField(labelWithString: "")
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
        pathLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        // Truncated in the middle: the head says which volume and the tail says which file, and the
        // directory levels between them are what nobody needs.
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.isSelectable = true
        pathLabel.maximumNumberOfLines = 2
        // **Low compression resistance, or a long path widens the whole window.** Without this the label
        // demands its intrinsic width -- a path from this user's corpus is 150 characters -- and the
        // layout's required width jumped to 1,110 points, which is the same class of bug as the square
        // image: content dictating the window instead of the other way round.
        for label in [pathLabel, detailLabel, nameLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .systemOrange
        placeholder.textColor = .tertiaryLabelColor
        placeholder.alignment = .center
        placeholder.stringValue = Strings.string("preview.empty")

        let stack = NSStackView(views: [imageView, nameLabel, pathLabel, detailLabel, stateLabel])
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
            // **Never square-locked to the pane's width.** That was the bug: `height == width` on a pane
            // 1,100 points wide demanded 1,100 points of height, which pushed the file list and the image
            // off the layout and -- because AppKit will not shrink a window below what its constraints
            // require -- made the window impossible to resize down. One cause, both symptoms, and neither
            // was visible from a passing selftest.
            //
            // A cap instead: the image takes what the pane offers up to a point, and `scaleProportionallyUpOrDown`
            // handles the rest.
            imageView.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16),
            imageView.heightAnchor.constraint(lessThanOrEqualToConstant: 280),
            imageView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            // **The labels are capped, not the pane.** Capping the pane is what blocked the window from
            // widening; leaving both uncapped let a 150-character path from this user's corpus dictate a
            // required width of 1,109 points. A ceiling on the text is the one that costs nothing: the full
            // path is still in the tooltip, and middle truncation keeps both ends.
            pathLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -16),
            pathLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            stateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])

        // **The same preference as the perceptual panes**, or "Show File Metadata" would govern one window kind
        // and not the other, which makes the menu item a lie rather than a setting.
        NotificationCenter.default.addObserver(
            forName: MetadataPreference.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMetadataPreference() }
        }
    }

    private func applyMetadataPreference() {
        detailLabel.isHidden = !MetadataPreference.isEnabled || detailLabel.stringValue.isEmpty
    }

    /// Shows nothing, for when no row is selected.
    func showPlaceholder() {
        placeholder.isHidden = false
        imageView.isHidden = true
        nameLabel.stringValue = ""
        pathLabel.stringValue = ""
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
        pathLabel.stringValue = presence.path
        pathLabel.toolTip = presence.path

        var details = [ByteSize.format(size)]
        if let modified = presence.modifiedAt {
            details.append(dateFormatter.string(from: modified))
        }
        detailLabel.stringValue = details.joined(separator: "  \u{00B7}  ")
        applyMetadataPreference()

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
    var pathText: String { pathLabel.stringValue }
    var detailText: String { detailLabel.stringValue }
    var isDetailHidden: Bool { detailLabel.isHidden }
    var stateText: String { stateLabel.stringValue }
    var isShowingPlaceholder: Bool { !placeholder.isHidden }
    var hasImage: Bool { imageView.image != nil }
}
