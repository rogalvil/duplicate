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

    /// Puts back what the most recent apply moved.
    ///
    /// Confirms first, and says how many files and how many bytes, because this is the one menu item in the
    /// app that moves thousands of files with one click.
    @MainActor
    @objc func undoLastSession(_ sender: Any?) {
        let state = StateDirectory.current()
        guard let session = UndoCoordinator.latestSession(in: state) else {
            let alert = NSAlert()
            alert.messageText = Strings.string("undo.noSessions.title")
            alert.informativeText = Strings.string("undo.noSessions.body")
            alert.addButton(withTitle: Strings.string("button.ok"))
            alert.runModal()
            return
        }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = String(format: Strings.string("undo.confirm.title"), session)
        confirm.informativeText = Strings.string("undo.confirm.body")
        confirm.addButton(withTitle: Strings.string("undo.confirm.restore"))
        confirm.addButton(withTitle: Strings.string("button.cancel"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        let outcome = UndoCoordinator.undo(sessionID: session, in: state)
        let result = NSAlert()
        result.messageText = String(
            format: Strings.string("undo.done.headline"),
            outcome.restoredCount, ByteSize.format(outcome.restoredBytes)
        )
        result.informativeText = outcome.summary
        result.addButton(withTitle: Strings.string("button.ok"))
        result.runModal()
    }

    /// Refuses to quit while an apply is moving files.
    ///
    /// Quitting halfway would leave files half-moved and a journal that stops mid-run. `.terminateLater`
    /// keeps the process alive; the reply comes when the apply finishes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard libraryWindow?.hasApplyInFlight == true else { return .terminateNow }
        Task { @MainActor in
            while libraryWindow?.hasApplyInFlight == true {
                try? await Task.sleep(for: .milliseconds(100))
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
