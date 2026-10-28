/// Maps ``DuplicateScan`` to and from its persisted JSON representation.
///
/// The digest is stored under `sha256`; the mapping to the model is written out explicitly.
///
/// **Encoding order is the format.** Python writes dictionary keys in insertion order, so
/// `scan_id, root, created_at, groups` and `size, sha256, files` are not stylistic -- reordering them
/// produces a file that is valid JSON and not byte-identical.
///
/// **Decoding tolerates unknown keys** so additional metadata does not prevent loading a scan.
public enum DuplicateScanCodec {
    // MARK: - Encoding

    public static func encode(_ scan: DuplicateScan) -> JSONValue {
        .object([
            JSONMember(key: "scan_id", value: .string(scan.scanID)),
            JSONMember(key: "root", value: .string(scan.root)),
            JSONMember(key: "created_at", value: .string(scan.createdAt)),
            JSONMember(key: "groups", value: .array(scan.groups.map(encode(group:)))),
        ])
    }

    public static func encode(group: DuplicateGroup) -> JSONValue {
        var members = [
            JSONMember(key: "size", value: .int(group.size)),
            JSONMember(key: "sha256", value: .string(group.digest.hexString)),
            JSONMember(key: "files", value: .array(group.files.map(JSONValue.string))),
        ]
        // Emitted only when the scan actually knows the partition, and under a namespaced key.
        //
        // Omitting an unknown partition keeps a re-encode of a document without metadata byte-identical.
        if let storage = group.storage {
            members.append(
                JSONMember(
                    key: "duplicate_app",
                    value: .object([
                        JSONMember(
                            key: "storage_clusters",
                            value: .array(
                                storage.clusters.map { cluster in
                                    .array(cluster.map(JSONValue.string))
                                }
                            )
                        ),
                        JSONMember(key: "storage_exact", value: .bool(storage.isExact)),
                    ])
                )
            )
        }
        return .object(members)
    }

    // MARK: - Decoding

    public static func decode(_ value: JSONValue) throws -> DuplicateScan {
        guard value.objectValue != nil else {
            throw ScanDecodingError.notAnObject(field: "<root>")
        }
        let scanID = try string(value, "scan_id")
        // Validated even though nothing here interpolates it: a scan whose identifier does not match
        // its own filename cannot be re-saved without either overwriting a different scan or
        // silently renaming this one.
        guard ScanIdentifier.isValid(scanID) else {
            throw ScanDecodingError.malformedScanIdentifier(scanID)
        }
        guard let rawGroups = value["groups"]?.arrayValue else {
            throw ScanDecodingError.missingField("groups")
        }
        return DuplicateScan(
            scanID: scanID,
            root: try string(value, "root"),
            createdAt: try string(value, "created_at"),
            groups: try rawGroups.enumerated().map { index, element in
                try decode(group: element, at: index)
            }
        )
    }

    public static func decode(group value: JSONValue, at index: Int) throws -> DuplicateGroup {
        guard value.objectValue != nil else {
            throw ScanDecodingError.notAnObject(field: "groups[\(index)]")
        }
        guard let size = value["size"]?.intValue else {
            throw ScanDecodingError.missingField("groups[\(index)].size")
        }
        guard size >= 0 else {
            throw ScanDecodingError.negativeSize(size, index: index)
        }
        guard let hex = value["sha256"]?.stringValue else {
            throw ScanDecodingError.missingField("groups[\(index)].sha256")
        }
        guard let digest = Digest32(hexString: hex) else {
            throw ScanDecodingError.malformedDigest(hex, index: index)
        }
        guard let rawFiles = value["files"]?.arrayValue else {
            throw ScanDecodingError.missingField("groups[\(index)].files")
        }
        let files = try rawFiles.enumerated().map { position, element -> String in
            guard let path = element.stringValue else {
                throw ScanDecodingError.notAString(field: "groups[\(index)].files[\(position)]")
            }
            guard !path.isEmpty else {
                throw ScanDecodingError.emptyPath(index: index, position: position)
            }
            return path
        }
        return DuplicateGroup(
            size: size,
            digest: digest,
            files: files,
            storage: decodeStorage(value, files: files)
        )
    }

    /// Reads the app's own storage partition, when the document carries one.
    ///
    /// Returns `nil` rather than a fabricated partition when the key is absent or malformed. `nil` means
    /// "unknown", not "no sharing", and the difference decides whether the reclaimable figure is exact
    /// or an upper bound.
    private static func decodeStorage(_ value: JSONValue, files: [String]) -> StoragePartition? {
        // Read the historical key only for compatibility. Losing its partition would offer a keeper's
        // hardlinks or clones for removal when an older scan is copied into the current state directory.
        guard
            let app = value["duplicate_app"] ?? value["rav_app"],
            let raw = app["storage_clusters"]?.arrayValue
        else { return nil }
        var clusters: [[String]] = []
        for element in raw {
            guard let paths = element.arrayValue else { return nil }
            let members = paths.compactMap(\.stringValue)
            guard members.count == paths.count, !members.isEmpty else { return nil }
            clusters.append(members)
        }
        // Every member must appear exactly once, or the partition does not describe this group and acting
        // on it would move the wrong files.
        guard clusters.flatMap({ $0 }).count == files.count else { return nil }
        let exact: Bool
        if case .bool(let flag)? = app["storage_exact"] {
            exact = flag
        } else {
            exact = false
        }
        return StoragePartition(clusters: clusters, isExact: exact)
    }

    private static func string(_ value: JSONValue, _ key: String) throws -> String {
        guard let member = value[key] else {
            throw ScanDecodingError.missingField(key)
        }
        guard let text = member.stringValue else {
            throw ScanDecodingError.notAString(field: key)
        }
        return text
    }
}

/// Why a scan document could not be read.
///
/// Every case names the field, because the file was written by another tool and "malformed JSON" is
/// not a diagnosis. Structured rather than prose: the presentation layer turns these into a localised
/// sentence, so `DuplicateCore` stays language-free.
public enum ScanDecodingError: Error, Equatable, Sendable {
    case notAnObject(field: String)
    case missingField(String)
    case notAString(field: String)
    case malformedScanIdentifier(String)
    case malformedDigest(String, index: Int)
    case negativeSize(Int64, index: Int)
    case emptyPath(index: Int, position: Int)
    /// A `media_type` this build does not know. Refused rather than guessed: the value decides which threshold
    /// the pair was judged against.
    case unknownMediaType(String)
    /// A decision string this build does not know. Refused rather than skipped: dropping it would turn a
    /// reviewed pair back into an unreviewed one.
    case unknownDecision(String, key: String)
}
