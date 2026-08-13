import AppKit
import DuplicateCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var libraryWindow: LibraryWindowController?
    private let stateDirectory: StateDirectory

    init(stateDirectory: StateDirectory = .current()) {
        self.stateDirectory = stateDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // **The library is the app's home, and it comes back rather than letting the app disappear.**
        //
        // Two complaints from real use pulled in opposite directions: first the app stayed alive with no
        // window and no way back, so closing the last window was made to quit; then it quit when a review
        // window was closed after the library already was, which reads as closing by itself.
        //
        // Both are answered by one rule: closing anything that is not the library brings the library back,
        // so the app is always either showing its home or gone on purpose. Quitting stays an explicit act --
        // closing the library, or Command-Q.
        // `NotificationCenter` hands the block a non-Sendable `self`, so the observer stays a plain
        // selector on this object rather than a closure capturing it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        Log.app.info(
            "state directory resolved to \(self.stateDirectory.duplicateRootPath, privacy: .public)"
        )
        showLibrary()
    }

    @MainActor
    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow else { return }
        guard closing !== libraryWindow?.window else { return }
        // A sheet closing is not a window closing.
        guard closing.sheetParent == nil else { return }
        let othersVisible = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel)
        }
        if !othersVisible { showLibrary() }
    }

    /// Opens the library, or raises the one already open.
    @MainActor
    private func showLibrary() {
        if let libraryWindow {
            libraryWindow.showWindow(nil)
            libraryWindow.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = LibraryWindowController(stateDirectory: stateDirectory)
            controller.showWindow(nil)
            libraryWindow = controller
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings a window back when the app is running without one.
    ///
    /// **Two real problems, one fix.** Clicking the Dock icon of a windowless app did nothing, so the only
    /// way out was Quit; and `make run` uses `open`, which activates the running instance instead of
    /// launching a new one -- so nothing appeared until the app was quit first. Both were reported from real
    /// use. Handling the reopen event answers both.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        if !hasVisibleWindows { showLibrary() }
        return true
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
        let state = stateDirectory
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
        // Any open review of the affected scan is now showing rows about files that moved back.
        libraryWindow?.reloadOpenReviews()

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

    // MARK: - Selftest hooks

    // `@MainActor` explicitly on both, not inherited: on the macOS 15 SDK that CI compiles against,
    // `NSWindowController.window` is not inferred as main-actor-isolated the way it is locally, so these are
    // hard errors there and clean here. Same family as the other SDK divergences.
    @MainActor
    var hasLibraryWindow: Bool { libraryWindow?.window != nil }

    @MainActor
    func closeLibraryForSelftest() {
        libraryWindow?.window?.close()
        libraryWindow = nil
    }

    /// Shows the About panel with the build date and build number the Makefile stamped in.
    ///
    /// `@MainActor` explicitly, not inherited: an `@objc` menu action is called through the responder
    /// chain, and Swift will not assume the caller is on the main actor without being told.
    @MainActor
    @objc func showAboutPanel(_ sender: Any?) {
        AboutPanel.show()
    }

    /// Closing every window quits.
    ///
    /// **Reversed from the original choice, because real use showed what it cost.** The app was staying
    /// alive with no window and no way to get one back except quitting from the Dock -- there is nothing for
    /// it to do without a window. An apply already in flight is protected separately, by
    /// `applicationShouldTerminate` returning `.terminateLater`.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
