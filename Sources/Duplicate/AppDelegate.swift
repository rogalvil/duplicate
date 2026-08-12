import AppKit
import DuplicateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var libraryWindow: LibraryWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stateDirectory = StateDirectory.current()
        Log.app.info(
            "state directory resolved to \(stateDirectory.duplicateRootPath, privacy: .public)"
        )

        let controller = LibraryWindowController(stateDirectory: stateDirectory)
        controller.showWindow(nil)
        libraryWindow = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Starts a new scan, in the library window that owns the state directory.
    ///
    /// On the delegate rather than the window so ⌘N works with no window focused, which is the state the
    /// app is in right after launch on a machine with no scans yet.
    @MainActor
    @objc func newScan(_ sender: Any?) {
        libraryWindow?.beginScan()
    }

    /// Shows the About panel with the build date and build number the Makefile stamped in.
    ///
    /// `@MainActor` explicitly, not inherited: an `@objc` menu action is called through the responder
    /// chain, and Swift will not assume the caller is on the main actor without being told.
    @MainActor
    @objc func showAboutPanel(_ sender: Any?) {
        AboutPanel.show()
    }

    /// Closing the library window should not quit: this is a library-style app, and sessions,
    /// history and review windows outlive it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
