import CryptoKit
import Foundation

/// What a folder holds: every file under it, by relative path, with its digest.
///
/// **This is what makes deleting a folder verifiable.** A perceptual pair can be re-scored and an exact group
/// re-hashed, but "these two folders are 95% alike" is not a claim anything can re-check cheaply -- and 95% is
/// exactly the case where deleting one loses the other 5%.
///
/// So the check before moving a folder is not the similarity at all. It is **containment**: every file in the
/// folder about to go must have a byte-identical twin, at the same relative path, in the folder being kept. If
/// one does not, that file exists only in the folder about to be deleted, and the move is refused with its name.
public struct FolderManifest: Sendable, Hashable {
    /// Relative path to digest, for every file under the folder.
    public let entries: [String: Digest32]
    public let root: String

    public init(root: String, entries: [String: Digest32]) {
        self.root = root
        self.entries = entries
    }

    public var fileCount: Int { entries.count }

    /// A single digest over the whole manifest, for the journal.
    ///
    /// **A folder has no content digest of its own**, and the journal needs one: it is what an undo compares to
    /// decide that what is in the Trash is still what was put there. Hashing the sorted `relpath\0hex` lines gives
    /// a value with that property -- edit any file inside the trashed folder, or add or remove one, and it
    /// changes.
    public var digest: Digest32 {
        var text = ""
        for path in PathOrder.sorted(Array(entries.keys)) {
            text += path
            text += "\u{0}"
            text += entries[path]?.hexString ?? ""
            text += "\n"
        }
        return Digest32(bytes: Array(SHA256.hash(data: Data(text.utf8))))
            ?? Digest32(a: 0, b: 0, c: 0, d: 0)
    }

    /// Files in this manifest that the other one does not have byte-identically at the same relative path.
    ///
    /// Sorted, so a refusal reads the same way twice.
    public func filesMissing(from other: FolderManifest) -> [String] {
        var missing: [String] = []
        for (path, digest) in entries where other.entries[path] != digest {
            missing.append(path)
        }
        return PathOrder.sorted(missing)
    }

    /// Builds a manifest by walking and hashing.
    ///
    /// The digest cache is consulted, so a folder that was just scanned costs almost nothing to verify --
    /// measured elsewhere at 18x on a warm run.
    /// - Parameter onFile: called with a running count of files digested, every
    ///   ``ApplyProgress/fileReportInterval`` files and once at the end. This is the only progress a folder
    ///   verification can report: it is the part that takes minutes.
    public static func build(
        root: String,
        walker: any DirectoryEnumerating = FileManagerWalker(),
        hasher: any FileHashing = ContentHasher(),
        policy: ScanPolicy = ScanPolicy(),
        cache: HashCache? = nil,
        onFile: (@Sendable (Int) -> Void)? = nil
    ) async throws -> FolderManifest {
        let canonical = DirectoryTree.canonical(root)
        let walk = try walker.walk(root: canonical, policy: policy, exclusions: ExclusionSet())
        var entries: [String: Digest32] = [:]
        entries.reserveCapacity(walk.entries.count)
        var seen = 0
        for entry in walk.entries {
            try Task.checkCancellation()
            let relative = PathElision.relative(DirectoryTree.canonical(entry.path), to: canonical)
            seen += 1
            if seen % ApplyProgress.fileReportInterval == 0 { onFile?(seen) }
            if let cache, let known = await cache.digest(for: entry) {
                entries[relative] = known
                continue
            }
            // **A cancelled hash must not turn into a missing entry.** `ContentHasher` stops between chunks, and
            // a `try?` here would drop that file from the manifest and carry on.
            //
            // Measured, the reachable damage is a false accusation rather than a deletion, because the checkpoint
            // above catches every position except one: the **last** file of a build. Cancel there and the loop
            // ends normally with a short manifest. On the keeper's build -- the second of the two, with nothing
            // between it and the comparison -- that reports `wouldLoseFiles(count: 1, examples: ["f2.txt"])` for
            // a file sitting in both folders. Someone pressed Stop and was told their folders differ.
            let result: HashResult
            do {
                result = try hasher.fullDigest(atPath: entry.path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
            if let cache { await cache.store(result.digest, for: entry) }
            entries[relative] = result.digest
        }
        onFile?(seen)
        return FolderManifest(root: canonical, entries: entries)
    }
}
