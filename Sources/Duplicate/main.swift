import AppKit
import Foundation

// Top-level code rather than @main, so the selftest can run and exit before any window exists.

// Touching NSApplication.shared first is what opens the window-server connection. Several AppKit
// and Quick Look calls abort the process with CGS_REQUIRE_INIT without it, and the failure points
// nowhere near the cause.
let application = NSApplication.shared

// .regular, not .accessory: this is a windowed app with a Dock icon and a main menu. Set here as
// well as via the absence of LSUIElement, so `make run-debug` behaves like a double-click.
application.setActivationPolicy(.regular)

if CommandLine.arguments.contains("--selftest") {
    let status = await SelfTest.run(arguments: CommandLine.arguments)
    exit(status)
}

application.mainMenu = MainMenuBuilder.build()

let delegate = AppDelegate()
application.delegate = delegate
application.run()
