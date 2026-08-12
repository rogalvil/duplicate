/// Maps ``DuplicateScan`` to and from the JSON the `rav duplicate` CLI reads and writes.
///
/// Field names come from the CLI's `to_dict`/`load_scan` (`src/rav/core/duplicates.py:27-33`,
/// `:114-133`). Note `sha256`: the JSON key does not match the dataclass field, which is called
/// `digest`. Automatic key strategies cannot produce that, which is why the mapping is written out.
///
/// **Encoding order is the format.** Python writes dictionary keys in insertion order, so
/// `scan_id, root, created_at, groups` and `size, sha256, files` are not stylistic -- reordering them
/// produces a file that is valid JSON and not byte-identical.
///
/// **Decoding tolerates unknown keys.** The CLI's `load_scan` reads only the keys it knows and
/// ignores the rest, so the app can add namespaced keys of its own without breaking the CLI, and must
/// return the favour.
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
        .object([
            JSONMember(key: "size", value: .int(group.size)),
            JSONMember(key: "sha256", value: .string(group.digest.hexString)),
            JSONMember(key: "files", value: .array(group.files.map(JSONValue.string))),
        ])
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
        return DuplicateGroup(size: size, digest: digest, files: files)
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
}
