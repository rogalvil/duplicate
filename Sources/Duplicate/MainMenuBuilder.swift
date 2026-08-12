import AppKit

/// Builds the main menu bar programmatically.
///
/// `NSApplication` does not synthesise a main menu without a nib, and this app has no nib, so
/// without this the window would have no menu bar at all -- not even Quit.
///
/// Only the application menu exists at this stage. File, Edit, View, Group, Sessions, Window and
/// Help arrive with the features they drive; adding empty shells now would put items in the menu
/// bar that do nothing.
enum MainMenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = applicationMenu()
        mainMenu.addItem(appMenuItem)

        return mainMenu
    }

    private static func applicationMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(
            withTitle: Strings.string("menu.app.about"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
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
}
