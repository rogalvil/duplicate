import Foundation
import os

/// Unified logging handles.
///
/// A windowed app has no console once it is launched from Finder, so this is the only trace that
/// survives a session. Read it back with:
///
///     log show --last 10m --info --predicate 'subsystem == "com.rogalvil.duplicate"'
///
/// The subsystem is read from the bundle rather than hardcoded, so a build with a substituted
/// identifier logs under the identifier it actually shipped with.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.rogalvil.duplicate"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let action = Logger(subsystem: subsystem, category: "action")
}
