import Foundation

/// Computes what an undo needs to know before it can plan, using the cache.
///
/// **This exists because a directory has no digest of its own.** An undo verifies that what is in the Trash is
/// still what was put there, and for a folder that means rebuilding its manifest -- walking it and hashing every
/// file. That used to happen inside the planner's environment closure, which is synchronous, which meant it ran
/// on the main thread and could not consult the digest cache, because the cache is an actor.
///
/// Measured: 979 MB/s over 200 three-megabyte files, which extrapolates to **33.8 seconds** for a 10,506-file
/// photo folder -- a frozen window, right after the apply that filled the cache with exactly those digests.
///
/// So the manifests are built here instead: `async`, cached, and cancellable per file. The planner stays a pure
/// synchronous function over an environment, which is what lets the decision be reviewed apart from the
/// mutation.
public enum UndoPreflight {

    /// Manifest digests for every directory the journal moved, keyed by canonical path.
    ///
    /// Files are skipped: the planner hashes those itself, one read each, which needs no cache to be cheap.
    /// A folder that cannot be read is simply absent from the result, and the planner treats an absent digest
    /// as a reason to block -- it could not verify, so it does not act.
    public static func directoryDigests(
        for entries: [JournalEntry],
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: any FileHashing = ContentHasher(),
        cache: HashCache? = nil
    ) async -> [String: Digest32] {
        var digests: [String: Digest32] = [:]
        for entry in entries {
            // The path an undo has to verify is where the file *went*, and the path it restores to is where it
            // came from. Both can be directories, and both are cheap to skip when they are not.
            for path in [entry.resultingPath, entry.originalPath] {
                let canonical = DirectoryTree.canonical(path)
                guard digests[canonical] == nil else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { continue }
                guard
                    let manifest = try? await FolderManifest.build(
                        root: path, walker: walker, hasher: hasher, cache: cache)
                else { continue }
                digests[canonical] = manifest.digest
            }
        }
        return digests
    }
}
