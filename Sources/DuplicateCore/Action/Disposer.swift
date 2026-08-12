import Foundation

/// How a file was removed.
public enum DisposalMechanism: String, Sendable, Codable, CaseIterable {
    /// `FileManager.trashItem`. Finder's "Put Back" works, which is the undo the CLI never had.
    case trash
    /// Moved into a quarantine directory, because the Trash was not available.
    case quarantine
}

/// What happened to one file.
public struct DisposalOutcome: Hashable, Sendable {
    public let originalPath: String
    /// Where it ended up, so it can be put back.
    public let resultingPath: String
    public let mechanism: DisposalMechanism
    public let byteCount: Int64

    public init(
        originalPath: String,
        resultingPath: String,
        mechanism: DisposalMechanism,
        byteCount: Int64
    ) {
        self.originalPath = originalPath
        self.resultingPath = resultingPath
        self.mechanism = mechanism
        self.byteCount = byteCount
    }
}

/// Why a file could not be removed.
public enum DisposalError: Error, Equatable, Sendable {
    /// Nothing at that path. Treated as already done by the planner, not as a failure.
    case missing(path: String)
    /// The Trash refused, which happens on network and read-only volumes.
    case trashUnavailable(path: String, reason: String)
    /// The quarantine move failed too.
    case quarantineFailed(path: String, reason: String)
    /// Every candidate name was taken.
    case noFreeName(path: String)
    /// The file on disk no longer matches the digest the scan recorded.
    case contentChanged(path: String)
}

/// Removes one file. Injected so the planner and the UI can be driven without touching a filesystem.
public protocol ItemDisposing: Sendable {
    func dispose(path: String) throws -> DisposalOutcome
}

/// Moves a file to the Trash.
///
/// The primary mechanism, and it earns that place by giving Finder's "Put Back" for free -- the undo the
/// CLI never had. Verified on this machine against every mounted volume:
///
/// | scanned from | landed in |
/// |---|---|
/// | boot volume, `/tmp` | `~/.Trash/` |
/// | home | `~/.Trash/` |
/// | `/Volumes/WD12TB` (external, case-sensitive APFS) | `/Volumes/WD12TB/.Trashes/501/` |
/// | `/Volumes/SED4TB` (external APFS) | `/Volumes/SED4TB/.Trashes/501/` |
///
/// That measurement mattered: the plan's largest open risk was that the external volume holding the real
/// corpus would be exFAT, where `trashItem` fails outright and the fallback would have been the primary
/// path for the user's actual data. It is not.
///
/// **This lives in Core, not the executable.** It takes a plain path, needs no device, opens no window and
/// triggers no TCC prompt -- only ordinary write access, which a test target has in `tmp`. It is the
/// riskiest component in the app, which is exactly why it belongs on the testable side.
public struct TrashDisposer: ItemDisposing {
    // `FileManager` is not Sendable, so it is not stored. Injecting one was only for testability, and
    // these tests use real files in a temporary directory anyway -- mocking the filesystem away would
    // test the wrong thing for the one component whose whole job is to move a real file.
    public init() {}

    public func dispose(path: String) throws -> DisposalOutcome {
        let fileManager = FileManager.default
        guard let size = Self.byteCount(of: path, using: fileManager) else {
            throw DisposalError.missing(path: path)
        }
        var resulting: NSURL?
        do {
            try fileManager.trashItem(at: URL(filePath: path), resultingItemURL: &resulting)
        } catch {
            throw DisposalError.trashUnavailable(
                path: path,
                reason: (error as NSError).localizedDescription
            )
        }
        guard let landed = (resulting as URL?)?.path(percentEncoded: false) else {
            // The move succeeded but macOS did not say where it went. Without a destination the move
            // cannot be undone, and reporting success would be a promise the journal cannot keep.
            throw DisposalError.trashUnavailable(
                path: path,
                reason: "the Trash did not report a destination"
            )
        }
        return DisposalOutcome(
            originalPath: path,
            resultingPath: landed,
            mechanism: .trash,
            byteCount: size
        )
    }

    static func byteCount(of path: String, using fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
            let size = attributes[.size] as? NSNumber
        else { return nil }
        return size.int64Value
    }
}

/// Moves a file into a quarantine directory, as a fallback when the Trash is unavailable.
///
/// The layout mirrors the CLI's -- `<root>/<session>/<basename>` with `-2`/`-3` collision suffixes -- so a
/// user who has used both tools recognises what they are looking at.
///
/// **The root is deliberately not under `~/.Trash`.** The CLI defaults to
/// `~/.Trash/rav-duplicates` (`src/rav/commands/duplicate.py:115`) and does not exclude it from its own
/// walk, so running `rav duplicate ~` twice re-discovers everything the first run just quarantined and
/// offers to quarantine it again. Living in Application Support avoids that entirely, and the walker
/// excludes both roots anyway.
public struct QuarantineDisposer: ItemDisposing {
    public static func defaultRoot(
        bundleIdentifier: String = "com.rogalvil.duplicate",
        applicationSupport: URL? = nil
    ) -> String {
        let base =
            applicationSupport
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support")
        return base.path(percentEncoded: false) + "/" + bundleIdentifier + "/quarantine"
    }

    private let root: String
    private let sessionID: String

    public init(root: String, sessionID: String) {
        self.root = root
        self.sessionID = sessionID
    }

    /// Where files from this session go.
    public var sessionDirectory: String { root + "/" + sessionID }

    public func dispose(path: String) throws -> DisposalOutcome {
        let fileManager = FileManager.default
        guard let size = TrashDisposer.byteCount(of: path, using: fileManager) else {
            throw DisposalError.missing(path: path)
        }
        do {
            try fileManager.createDirectory(
                atPath: sessionDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw DisposalError.quarantineFailed(
                path: path,
                reason: (error as NSError).localizedDescription
            )
        }

        let preferred = sessionDirectory + "/" + (path as NSString).lastPathComponent
        guard
            let destination = CollisionResolver.uniqueDestination(
                for: preferred,
                exists: {
                    fileManager.fileExists(atPath: $0)
                })
        else {
            throw DisposalError.noFreeName(path: preferred)
        }

        do {
            try fileManager.moveItem(atPath: path, toPath: destination)
        } catch {
            throw DisposalError.quarantineFailed(
                path: path,
                reason: (error as NSError).localizedDescription
            )
        }
        return DisposalOutcome(
            originalPath: path,
            resultingPath: destination,
            mechanism: .quarantine,
            byteCount: size
        )
    }
}

/// Tries the Trash first, then the quarantine.
///
/// The composition the app actually uses. `trashItem` fails on network mounts and read-only volumes, and a
/// user whose duplicates live on a NAS should not be told the app cannot help them -- but they also should
/// not be told the files went to the Trash when they did not, which is why the mechanism is recorded per
/// file rather than per session.
public struct FallbackDisposer: ItemDisposing {
    private let primary: any ItemDisposing
    private let secondary: any ItemDisposing

    public init(primary: any ItemDisposing, secondary: any ItemDisposing) {
        self.primary = primary
        self.secondary = secondary
    }

    public init(quarantineRoot: String, sessionID: String) {
        self.init(
            primary: TrashDisposer(),
            secondary: QuarantineDisposer(root: quarantineRoot, sessionID: sessionID)
        )
    }

    public func dispose(path: String) throws -> DisposalOutcome {
        do {
            return try primary.dispose(path: path)
        } catch DisposalError.missing(let path) {
            // A file that is already gone is not a reason to try again somewhere else.
            throw DisposalError.missing(path: path)
        } catch {
            return try secondary.dispose(path: path)
        }
    }
}

/// Refuses to remove a file whose content no longer matches what the scan recorded.
///
/// The safety valve, wired in. Every other layer assumes the digest in the scan describes the bytes on
/// disk; this is the only place that checks, and it checks at the last possible moment.
///
/// The cost is one read of only the files being removed, which is trivial next to the scan that found
/// them. What it buys: a stale scan, a file edited while the review window was open, or a corrupt-but-CRC-
/// valid cache row all become an error message naming the file, instead of a file in the Trash that was
/// never a duplicate. Given the app has no undo beyond Finder's, that trade is not close.
public struct VerifyingDisposer: ItemDisposing {
    private let inner: any ItemDisposing
    private let hasher: any FileHashing
    private let expected: [String: Digest32]

    /// - Parameter expected: the digest each path must still hash to. A path absent from this map is
    ///   refused rather than allowed: disposing something nobody vouched for is exactly the mistake this
    ///   type exists to prevent.
    public init(
        wrapping inner: any ItemDisposing,
        hasher: any FileHashing,
        expected: [String: Digest32]
    ) {
        self.inner = inner
        self.hasher = hasher
        self.expected = expected
    }

    public func dispose(path: String) throws -> DisposalOutcome {
        guard let want = expected[path] else {
            throw DisposalError.contentChanged(path: path)
        }
        guard let fresh = try? hasher.fullDigest(atPath: path) else {
            throw DisposalError.missing(path: path)
        }
        guard fresh.digest == want else {
            throw DisposalError.contentChanged(path: path)
        }
        return try inner.dispose(path: path)
    }
}
