/// Turns hashed files into the groups the shared format stores.
///
/// Ports `find_duplicates`' final stage (`src/rav/core/duplicates.py:81-94`). Two orderings are
/// reproduced exactly, because both are part of the format and neither may depend on the order tasks
/// happened to finish in:
///
/// - **Within a group**, paths ascend by UTF-8 byte. The CLI writes `tuple(sorted(duplicate_paths))`
///   over `pathlib.Path` objects, and Python compares those by code point. Swift's `String <` compares
///   under canonical equivalence, which is not the same order, so this goes through ``PathOrder``.
/// - **Between groups**, size descends and the digest ascends. Comparing ``Digest32`` values gives the
///   same order as comparing their lowercase hex strings, so no string is allocated to sort 20,000
///   groups.
public enum GroupBuilder {
    /// Builds the groups for one set of hashed files.
    ///
    /// - Parameter hashed: every candidate that hashed successfully, in any order.
    /// - Returns: only groups with more than one member, in the CLI's order.
    public static func groups(
        from hashed: [(entry: FileEntry, digest: Digest32)]
    ) -> [DuplicateGroup] {
        var indices = Array(hashed.indices)
        // One sort does all the work: it clusters by (size, digest) and leaves each cluster's paths
        // already in byte order, so the run scan below just slices.
        indices.sort { left, right in
            let a = hashed[left]
            let b = hashed[right]
            if a.entry.size != b.entry.size { return a.entry.size > b.entry.size }
            if a.digest != b.digest { return a.digest < b.digest }
            return PathOrder.lessThan(a.entry.path, b.entry.path)
        }

        var result: [DuplicateGroup] = []
        var start = 0
        while start < indices.count {
            var end = start + 1
            let size = hashed[indices[start]].entry.size
            let digest = hashed[indices[start]].digest
            while end < indices.count,
                hashed[indices[end]].entry.size == size,
                hashed[indices[end]].digest == digest
            {
                end += 1
            }
            if end - start > 1 {
                let members = indices[start..<end].map { hashed[$0].entry }
                result.append(
                    DuplicateGroup(
                        size: size,
                        digest: digest,
                        files: members.map(\.path),
                        // Computed here, where the entries with their identity and content identifiers are
                        // still in hand. A group carries only paths, so this is the last moment it can be.
                        storage: StoragePartition.of(members)
                    )
                )
            }
            start = end
        }
        return result
    }

    /// Assembles a complete scan document from the groups.
    public static func scan(
        root: String,
        instant: ScanIdentifier.Instant,
        groups: [DuplicateGroup]
    ) -> DuplicateScan {
        DuplicateScan(
            scanID: instant.identifier,
            root: root,
            createdAt: instant.timestamp,
            groups: groups
        )
    }
}
