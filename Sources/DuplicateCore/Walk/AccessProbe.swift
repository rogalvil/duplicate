import Foundation

/// What happened when the app tried to look inside a directory.
public enum DirectoryAccess: Equatable, Sendable {
    /// Readable, with at least this many entries seen (capped by the probe's sample size).
    case readable(sampleCount: Int)
    /// Readable and genuinely empty.
    case empty
    /// Exists, is a directory, and the process is not allowed to list it.
    case denied
    /// Nothing at that path.
    case missing
    /// Something is there, but it is not a directory.
    case notADirectory
}

/// Distinguishes "this directory is empty" from "macOS will not let me look".
///
/// This exists because of one specific failure. `FileManager.enumerator` yields nothing for a
/// TCC-protected directory, and its error handler is the only place the denial appears. A scan that
/// treats an empty enumeration as an empty directory reports "no duplicates found" for
/// `~/Library/Messages` -- which looks exactly like a correct answer and is not one.
///
/// Called before a scan starts, so the app can say what it will not be able to see up front rather
/// than after twenty minutes of hashing. Pure decision logic over one `FileManager` call, so it lives
/// in Core; the executable turns `.denied` into a banner and a link to System Settings.
public enum AccessProbe {
    /// Looks at `path` without walking it.
    ///
    /// - Parameter sampleLimit: stop after this many entries. The question is whether the directory can
    ///   be read, not what is in it, and a probe that enumerated `$HOME` would defeat its own purpose.
    public static func probe(
        path: String,
        sampleLimit: Int = 4,
        using fileManager: FileManager = .default
    ) -> DirectoryAccess {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return .notADirectory
        }

        // contentsOfDirectory throws on a denial, which is exactly the distinction being drawn.
        // The shallow variant is used on purpose: no recursion, no resource values, one syscall's worth
        // of work.
        do {
            let names = try fileManager.contentsOfDirectory(atPath: path)
            return names.isEmpty ? .empty : .readable(sampleCount: min(names.count, sampleLimit))
        } catch {
            // Any failure to list a directory that exists is treated as a denial. The alternative --
            // inspecting the errno -- would classify an I/O error on a failing disk as "empty", which is
            // the mistake this type exists to prevent.
            return .denied
        }
    }

    /// Probes several roots at once, keeping only the ones that cannot be read.
    ///
    /// The shape the UI needs: a list to name in a banner, not a boolean.
    public static func unreadable(
        among paths: [String],
        using fileManager: FileManager = .default
    ) -> [(path: String, access: DirectoryAccess)] {
        paths.compactMap { path in
            let access = probe(path: path, using: fileManager)
            switch access {
            case .denied, .missing, .notADirectory: return (path, access)
            case .readable, .empty: return nil
            }
        }
    }
}
