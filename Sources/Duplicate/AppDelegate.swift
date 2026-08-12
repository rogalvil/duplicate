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

    /// Closing the library window should not quit: this is a library-style app, and sessions,
    /// history and review windows outlive it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
