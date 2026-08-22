import AppKit
@preconcurrency import Quartz

/// Drives the system's Quick Look panel for a window.
///
/// **The gesture the app was missing, and the reason it exists instead of the CLI.** All three viewers draw
/// thumbnails capped at 280 points, which is enough to tell two photographs apart and not always enough to
/// decide between them -- the difference the perceptual detector found can be finer than the thumbnail. Quick
/// Look is the full-size look, in the panel a macOS user already knows, with the arrow keys already wired.
///
/// **A shared object rather than three implementations.** `QLPreviewPanel` talks to whatever object claims
/// control of it, and all three windows want the same behaviour over a different list of paths: hand it the
/// paths, let it answer the panel's questions. `QLPreviewItem` is a protocol on `NSObject`, so the items are a
/// tiny box around a URL.
///
/// **It shows missing files as missing rather than hiding them.** Of the pairs in this user's real perceptual
/// scans, one side of the very first one is already gone, so filtering absent paths out would silently turn a
/// two-item panel into a one-item panel and leave someone arrowing between one picture wondering which side
/// they were looking at. Absent paths are dropped only when *every* path is absent, which is the case where
/// there is nothing a panel could show.
@MainActor
final class QuickLookCoordinator: NSObject {
    /// What the panel is showing, in order. Set before the panel is opened.
    private var items: [QuickLookItem] = []

    /// Points the coordinator at a list of paths, keeping the order the window shows them in.
    ///
    /// - Returns: false when there is nothing on disk to show, so a caller can decline to open a panel that
    ///   would come up empty.
    @discardableResult
    func present(paths: [String]) -> Bool {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }
        items = existing.map { QuickLookItem(path: $0) }
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.reloadData()
        return !items.isEmpty && panel.dataSource === self
    }

    /// Opens or closes the panel.
    func toggle(paths: [String], controller: NSResponder) -> Bool {
        guard let panel = QLPreviewPanel.shared() else { return false }
        if panel.isVisible {
            panel.orderOut(nil)
            return true
        }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return false }
        items = existing.map { QuickLookItem(path: $0) }
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
        return true
    }

    /// Whether the panel currently has anything to show. Read by the selftest.
    var itemCount: Int { items.count }

    var itemPaths: [String] { items.map(\.path) }

    fileprivate var previewItems: [QuickLookItem] { items }
}

/// **The conformance sits outside the `@MainActor` class on purpose.** `QLPreviewPanelDataSource` is not
/// annotated, so declaring it on an isolated type is a hard error about crossing into actor-isolated code --
/// the same class of SDK-annotation gap this project already hits with AVFoundation and ImageIO. The panel only
/// ever asks on the main thread, which is what `assumeIsolated` states.
extension QuickLookCoordinator: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, previewItemAt index: Int
    )
        -> QLPreviewItem!
    {
        MainActor.assumeIsolated {
            let items = previewItems
            return items.indices.contains(index) ? items[index] : nil
        }
    }
}

/// One row in the panel.
///
/// `QLPreviewItem` needs an `NSObject`, and the URL has to survive as long as the panel holds it, so this is a
/// class and not a struct.
final class QuickLookItem: NSObject, QLPreviewItem {
    let path: String

    init(path: String) {
        self.path = path
    }

    var previewItemURL: URL! { URL(filePath: path) }
    var previewItemTitle: String! { (path as NSString).lastPathComponent }
}
