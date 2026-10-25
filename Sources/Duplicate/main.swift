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
    // **A selftest that ends early has to fail, not pass.** The async main exits with status 0 whenever the main run
    // loop stops, and a selftest once stopped it halfway through a mode -- a `performClick` on a window with a sheet
    // attached -- so the process ended with 0, no `OK` and no `FAILED`, and `--mode all` would have skipped every
    // mode after it with CI green (#217). The guard turns any exit that `SelfTest.run` did not return into a failure.
    atexit {
        guard !SelfTest.hasFinished else { return }
        fflush(stdout)
        FileHandle.standardError.write(
            Data("FAILED: the process exited before the selftest finished\n".utf8))
        _exit(1)
    }
    let status = await SelfTest.run(arguments: CommandLine.arguments)
    SelfTest.hasFinished = true
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
