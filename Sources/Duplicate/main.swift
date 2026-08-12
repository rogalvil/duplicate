import AppKit
import Foundation

// Top-level code rather than @main, so the selftest can run and exit before any window exists.

// Touching NSApplication.shared first is what opens the window-server connection. Several AppKit
// and Quick Look calls abort the process with CGS_REQUIRE_INIT without it, and the failure points
// nowhere near the cause.
// Raised before anything opens a file. See `DescriptorLimit` for why 256 is not enough and why the
// failure it prevents looks like a smaller answer rather than an error.
DescriptorLimit.raiseIfNeeded()

let application = NSApplication.shared

// .regular, not .accessory: this is a windowed app with a Dock icon and a main menu. Set here as
// well as via the absence of LSUIElement, so `make run-debug` behaves like a double-click.
application.setActivationPolicy(.regular)

if CommandLine.arguments.contains("--selftest") {
    let status = await SelfTest.run(arguments: CommandLine.arguments)
    exit(status)
}

let mainMenu = MainMenuBuilder.build()
application.mainMenu = mainMenu
// Assigning windowsMenu is what makes macOS list open windows in it and add the standard separator.
// Without it the Window menu is whatever was built and nothing more, and a user with three review
// windows open has no way to reach the one behind.
application.windowsMenu =
    mainMenu.items.first { $0.submenu?.title == Strings.string("menu.window") }?
    .submenu

let delegate = AppDelegate()
application.delegate = delegate
application.run()
