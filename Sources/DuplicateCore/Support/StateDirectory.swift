import Foundation

/// Resolves the state directory shared with the `rav duplicate` CLI.
///
/// This is a port of `src/rav/config/paths.py:state_dir()`. Everything is injected -- the
/// environment and the home directory -- so the resolution rules can be tested without touching
/// the real `$HOME` or mutating the process environment.
///
/// **Paths are held as strings, and `URL` is only a convenience accessor.** Two reasons, both
/// learned the hard way:
///
/// - `URL(filePath:)` resolves a relative path against the current working directory, which would
///   turn a relative `XDG_STATE_HOME` into an absolute path silently and make it impossible to
///   detect. Callers need to be able to refuse it.
/// - `URL.appending(path:directoryHint: .isDirectory)` appends a trailing slash, and
///   `FileManager.fileExists(atPath:)` never matches a trailing-slash path against a regular file.
///   A file sitting where a directory belongs then reads as "nothing here", and the real failure
///   surfaces later as an opaque Cocoa error that does not mention the collision.
///
/// Two behaviours of the Python are load-bearing and easy to get wrong in Swift:
///
/// 1. **An empty `XDG_STATE_HOME` must fall back.** Python's `os.environ.get` returns `""`, which
///    is falsy, so the CLI falls through to `~/.local/state`. `ProcessInfo`'s equivalent returns
///    `""` too, but an empty Swift `String` is not falsy, so a literal translation would resolve
///    the state directory to `/rav` and silently stop seeing every existing scan.
/// 2. **A leading tilde is expanded.** The CLI applies `Path(base).expanduser()`.
///
/// Two deliberate divergences, documented rather than fixed:
///
/// - `~otheruser` is not expanded. Python's `expanduser` resolves it through the password
///   database; doing the same here would ignore the injected home and make this type untestable.
///   A tilde followed by anything other than `/` is treated as a literal path component.
/// - A relative `XDG_STATE_HOME` is kept relative, exactly as Python keeps it, even though the XDG
///   specification says it must be absolute. Callers that need an absolute path should check
///   ``isAbsolute`` and refuse: Launch Services starts the app with `/` as its working directory,
///   so a relative root points somewhere the CLI never wrote to.
public struct StateDirectory: Sendable, Equatable {
    /// The subdirectories under `<state>/rav/duplicate/`.
    ///
    /// The first six are shared with the CLI. ``journal`` is this app's own: it records what was
    /// moved where so a session can be undone, an action the CLI does not perform.
    public enum Slot: String, CaseIterable, Sendable {
        case scans = "scans"
        case decisions = "decisions"
        case folderScans = "folder-scans"
        case folderDecisions = "folder-decisions"
        case similarScans = "similar-scans"
        case similarDecisions = "similar-decisions"
        case journal = "journal"

        /// Whether the CLI also reads and writes this subdirectory.
        public var isSharedWithCLI: Bool { self != .journal }
    }

    /// The `rav` root as a path string, without a trailing slash.
    public let ravRootPath: String

    /// Resolves the root from an environment and a home directory path.
    ///
    /// - Parameters:
    ///   - environment: usually `ProcessInfo.processInfo.environment`.
    ///   - homePath: usually `NSHomeDirectory()`.
    public init(environment: [String: String], homePath: String) {
        let home = Self.trimmingTrailingSlashes(homePath)
        let base = environment["XDG_STATE_HOME"] ?? ""
        if base.isEmpty {
            ravRootPath = Self.joining(home, ".local", "state", "rav")
        } else {
            ravRootPath = Self.joining(Self.expandingTilde(base, home: home), "rav")
        }
    }

    /// Convenience for callers that already hold the home directory as a `URL`.
    public init(environment: [String: String], home: URL) {
        self.init(environment: environment, homePath: home.path(percentEncoded: false))
    }

    /// Resolves from the current process environment and home directory.
    public static func current() -> StateDirectory {
        StateDirectory(
            environment: ProcessInfo.processInfo.environment, homePath: NSHomeDirectory())
    }

    /// `<rav root>/duplicate`, without a trailing slash.
    public var duplicateRootPath: String { Self.joining(ravRootPath, "duplicate") }

    /// The path of one slot's directory, without a trailing slash. Does not create it.
    public func path(for slot: Slot) -> String {
        Self.joining(duplicateRootPath, slot.rawValue)
    }

    /// The path of the file holding one identified artefact, for example a scan's JSON.
    ///
    /// - Throws: ``StateDirectoryError/invalidIdentifier`` when `id` is not a valid identifier.
    ///   The check is not decoration: an identifier read off disk is interpolated into a path, and
    ///   `../../../etc/passwd` must never resolve to anything.
    public func filePath(
        for slot: Slot, id: String, extension ext: String = "json"
    ) throws -> String {
        guard ScanIdentifier.isValid(id) else {
            throw StateDirectoryError.invalidIdentifier(id)
        }
        return Self.joining(path(for: slot), "\(id).\(ext)")
    }

    /// Whether the resolved root is absolute. See the note on relative `XDG_STATE_HOME`.
    public var isAbsolute: Bool { ravRootPath.hasPrefix("/") }

    // MARK: - URL accessors
    //
    // Only meaningful when `isAbsolute` is true: URL(filePath:) resolves a relative path against
    // the process's working directory.

    public var ravRoot: URL { URL(filePath: ravRootPath, directoryHint: .notDirectory) }
    public var duplicateRoot: URL { URL(filePath: duplicateRootPath, directoryHint: .notDirectory) }

    public func directory(for slot: Slot) -> URL {
        URL(filePath: path(for: slot), directoryHint: .notDirectory)
    }

    public func file(for slot: Slot, id: String, extension ext: String = "json") throws -> URL {
        URL(filePath: try filePath(for: slot, id: id, extension: ext), directoryHint: .notDirectory)
    }

    /// Every slot directory path, in declaration order.
    public var allPaths: [String] { Slot.allCases.map(path(for:)) }

    // MARK: - Creation

    /// Creates one slot directory if it does not exist, and returns its path.
    ///
    /// - Throws: ``StateDirectoryError/notADirectory`` when something that is not a directory
    ///   already occupies the path.
    @discardableResult
    public func create(_ slot: Slot, using fileManager: FileManager = .default) throws -> String {
        let target = path(for: slot)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StateDirectoryError.notADirectory(target)
            }
            return target
        }
        try fileManager.createDirectory(
            atPath: target,
            withIntermediateDirectories: true
        )
        return target
    }

    // MARK: - Path arithmetic
    //
    // Done by hand rather than through URL so that no trailing slash is ever introduced and a
    // relative root stays relative.

    private static func joining(_ base: String, _ components: String...) -> String {
        var result = trimmingTrailingSlashes(base)
        for component in components {
            result += "/" + component
        }
        return trimmingTrailingSlashes(result)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var result = path
        while result.count > 1, result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    /// Expands a leading `~` or `~/` against the injected home. Anything else is literal.
    private static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return joining(home, String(path.dropFirst(2)))
        }
        return trimmingTrailingSlashes(path)
    }
}

/// Failures that come from resolving or preparing the state directory.
public enum StateDirectoryError: Error, Equatable, Sendable {
    /// An identifier that would escape its directory, or is otherwise malformed.
    case invalidIdentifier(String)
    /// Something that is not a directory occupies the path where a directory belongs.
    case notADirectory(String)
}
