import AppKit
import DuplicateCore

/// The scan library window: the app's home.
///
/// A placeholder at this stage. It exists so the scaffolding is provably runnable -- a window that
/// opens, carries a localised title, and reports where the shared state directory resolved to. The
/// scan list, the detector sidebar and the review split view arrive with their own changes.
final class LibraryWindowController: NSWindowController {
    convenience init(stateDirectory: StateDirectory) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Strings.string("window.library.title")
        window.center()
        window.setFrameAutosaveName("LibraryWindow")

        let label = NSTextField(labelWithString: stateDirectory.duplicateRootPath)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            label.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
        ])
        window.contentView = content

        self.init(window: window)
    }
}
