import AppKit

/// Builds the main menu bar programmatically.
///
/// `NSApplication` does not synthesise a main menu without a nib, and this app has no nib, so
/// without this the window would have no menu bar at all -- not even Quit.
///
/// **The Edit menu is not decoration.** `NSUndoManager` reaches the user through `undo:`/`redo:` on the
/// first responder, and without menu items carrying ⌘Z there is no undo at all -- the manager records
/// perfectly and nobody can invoke it. Same for ⌘C in the search field: `NSTextField` implements
/// `copy:` and relies on a menu item to send it.
///
/// **⌘Z is review undo and never apply undo.** Undoing a checkbox and undoing four thousand files moved
/// to the Trash are not the same kind of act, and every other Mac app has taught the user that ⌘Z means
/// "the thing I just typed". Session undo lives in its own menu with no key equivalent.
@MainActor
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()
        for submenu in [applicationMenu(), fileMenu(), editMenu(), groupMenu(), windowMenu()] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    private static func applicationMenu() -> NSMenu {
        let menu = NSMenu()

        // Routed through AboutPanel rather than straight to the system selector, so the build date and
        // the commit reach the panel. The system version shows only what Info.plist happens to carry.
        let about = menu.addItem(
            withTitle: Strings.string("menu.app.about"),
            action: #selector(AppDelegate.showAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = NSApp.delegate
        menu.addItem(.separator())

        menu.addItem(
            withTitle: Strings.string("menu.app.hide"),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthers = menu.addItem(
            withTitle: Strings.string("menu.app.hideOthers"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(
            withTitle: Strings.string("menu.app.showAll"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        menu.addItem(
            withTitle: Strings.string("menu.app.quit"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: Strings.string("menu.file"))
        menu.addItem(
            withTitle: Strings.string("menu.file.saveDecisions"),
            action: #selector(ReviewWindowController.saveDecisions(_:)),
            keyEquivalent: "s"
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Strings.string("menu.file.close"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: Strings.string("menu.edit"))
        menu.addItem(
            withTitle: Strings.string("menu.edit.undo"),
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = menu.addItem(
            withTitle: Strings.string("menu.edit.redo"),
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Strings.string("menu.edit.cut"),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        menu.addItem(
            withTitle: Strings.string("menu.edit.copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        menu.addItem(
            withTitle: Strings.string("menu.edit.paste"),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        menu.addItem(
            withTitle: Strings.string("menu.edit.selectAll"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        return menu
    }

    /// The review actions.
    ///
    /// Return and space are **not** here on purpose. A menu key equivalent is global, so Return as a
    /// shortcut would fire while the user is typing in the search field. Those two live in
    /// ``ReviewTableView/keyDown(with:)``, where they only mean something because a file list has focus.
    ///
    /// "Discard the whole group" has no key equivalent, deliberately: it is the one action here that
    /// proposes removing every copy, and it asks first.
    private static func groupMenu() -> NSMenu {
        let menu = NSMenu(title: Strings.string("menu.group"))
        let confirm = menu.addItem(
            withTitle: Strings.string("menu.group.confirm"),
            action: #selector(ReviewWindowController.confirmGroup(_:)),
            keyEquivalent: "\r"
        )
        confirm.keyEquivalentModifierMask = [.command]

        let skip = menu.addItem(
            withTitle: Strings.string("menu.group.skip"),
            action: #selector(ReviewWindowController.skipGroup(_:)),
            keyEquivalent: "k"
        )
        skip.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(
            withTitle: Strings.string("menu.group.clearDecision"),
            action: #selector(ReviewWindowController.clearDecision(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        menu.addItem(
            withTitle: Strings.string("menu.group.keepAll"),
            action: #selector(ReviewWindowController.keepAll(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: Strings.string("menu.group.discardAll"),
            action: #selector(ReviewWindowController.discardEntireGroup(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        menu.addItem(
            withTitle: Strings.string("menu.group.previous"),
            action: #selector(ReviewWindowController.previousGroup(_:)),
            keyEquivalent: "["
        )
        menu.addItem(
            withTitle: Strings.string("menu.group.next"),
            action: #selector(ReviewWindowController.nextGroup(_:)),
            keyEquivalent: "]"
        )
        menu.addItem(.separator())

        menu.addItem(
            withTitle: Strings.string("menu.group.revealFile"),
            action: #selector(ReviewWindowController.revealSelectedFile(_:)),
            keyEquivalent: "r"
        )
        return menu
    }

    /// Assigned to `NSApp.windowsMenu` by the caller, which is what makes macOS list open windows in it.
    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: Strings.string("menu.window"))
        menu.addItem(
            withTitle: Strings.string("menu.window.minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: Strings.string("menu.window.zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Strings.string("menu.window.bringAllToFront"),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        return menu
    }
}
