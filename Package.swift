// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Duplicate",
    // English is the development language: identifiers, comments and the base string table.
    // Spanish ships alongside it. See Resources/en.lproj and Resources/es.lproj.
    defaultLocalization: "en",
    platforms: [
        // Synchronization's Atomic and Mutex require macOS 15. The scanner's progress counters
        // are built on them, so this floor is load-bearing rather than aspirational.
        .macOS(.v15)
    ],
    targets: [
        // Pure logic: no AppKit, no NSWindow, no NSWorkspace. Frameworks used for values --
        // CryptoKit, Accelerate, ImageIO, AVFoundation on a file URL -- are welcome here,
        // because everything in this target must be reachable from tests without a display.
        .target(name: "DuplicateCore"),

        // AppKit glue: windows, menus, panels, Quick Look. Not importable by tests, by design.
        .executableTarget(
            name: "Duplicate",
            dependencies: ["DuplicateCore"]
        ),

        .testTarget(
            name: "DuplicateCoreTests",
            dependencies: ["DuplicateCore"],
            // Read through #filePath, not Bundle.module. They are interop fixtures written by
            // Python's json.dumps and only ever compared byte for byte; copying them into a
            // resource bundle would add a build step and change nothing.
            exclude: ["Fixtures"]
        ),
    ]
)
