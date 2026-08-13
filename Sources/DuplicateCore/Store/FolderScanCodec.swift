import Foundation

/// One folder-similarity scan, as stored in `folder-scans/<scan_id>.json`.
public struct FolderScan: Sendable, Hashable {
    public let scanID: String
    public let root: String
    /// An opaque string, like every other timestamp here.
    public let createdAt: String
    /// The Dice threshold the scan was run at.
    public let threshold: Double
    public let pairs: [FolderPair]

    public init(
        scanID: String, root: String, createdAt: String, threshold: Double, pairs: [FolderPair]
    ) {
        self.scanID = scanID
        self.root = root
        self.createdAt = createdAt
        self.threshold = threshold
        self.pairs = pairs
    }

    public var pairCount: Int { pairs.count }
    /// How many folders appear in at least one pair.
    public var involvedFolderCount: Int {
        var folders: Set<String> = []
        for pair in pairs {
            folders.insert(pair.folderA)
            folders.insert(pair.folderB)
        }
        return folders.count
    }
    public var hasRelativePaths: Bool {
        !root.hasPrefix("/") || pairs.contains { !$0.folderA.hasPrefix("/") }
    }
}

/// Maps ``FolderScan`` to and from the JSON the `rav duplicate folders` command reads and writes.
///
/// The shape is from `folder_duplicates.py:172-186` and was verified against the four real documents on this
/// machine: `{scan_id, root, created_at, threshold, pairs[]}` with pair keys `folder_a`, `folder_b`,
/// `similarity`, `matching`, `only_in_a`, `only_in_b`, `changed`, `total_a`, `total_b`.
///
/// **Two number types, and mixing them breaks the byte comparison.** `similarity` and `threshold` are
/// floats -- and `"similarity": 1.0` really happens, 1,107 times across the real documents, because an
/// identical pair is the common case. `matching`, `total_a` and `total_b` are integers, and emitting `5.0`
/// for one of those is the same class of error in the other direction. Both mistakes exist; this writes
/// each field in its own type.
public enum FolderScanCodec {

    public static func encode(_ scan: FolderScan) -> JSONValue {
        .object([
            JSONMember(key: "scan_id", value: .string(scan.scanID)),
            JSONMember(key: "root", value: .string(scan.root)),
            JSONMember(key: "created_at", value: .string(scan.createdAt)),
            JSONMember(key: "threshold", value: .double(scan.threshold)),
            JSONMember(key: "pairs", value: .array(scan.pairs.map(encodePair))),
        ])
    }

    private static func encodePair(_ pair: FolderPair) -> JSONValue {
        .object([
            JSONMember(key: "folder_a", value: .string(pair.folderA)),
            JSONMember(key: "folder_b", value: .string(pair.folderB)),
            JSONMember(key: "similarity", value: .double(pair.similarity)),
            JSONMember(key: "matching", value: .int(Int64(pair.matching))),
            JSONMember(key: "only_in_a", value: .array(pair.onlyInA.map(JSONValue.string))),
            JSONMember(key: "only_in_b", value: .array(pair.onlyInB.map(JSONValue.string))),
            JSONMember(key: "changed", value: .array(pair.changed.map(JSONValue.string))),
            JSONMember(key: "total_a", value: .int(Int64(pair.totalA))),
            JSONMember(key: "total_b", value: .int(Int64(pair.totalB))),
        ])
    }

    public static func decode(_ value: JSONValue) throws -> FolderScan {
        guard value.objectValue != nil else {
            throw ScanDecodingError.notAnObject(field: "<root>")
        }
        guard let scanID = value["scan_id"]?.stringValue else {
            throw ScanDecodingError.missingField("scan_id")
        }
        guard ScanIdentifier.isValid(scanID) else {
            throw ScanDecodingError.malformedScanIdentifier(scanID)
        }
        guard let root = value["root"]?.stringValue else {
            throw ScanDecodingError.missingField("root")
        }
        guard let createdAt = value["created_at"]?.stringValue else {
            throw ScanDecodingError.missingField("created_at")
        }
        guard let threshold = value["threshold"]?.doubleValue else {
            throw ScanDecodingError.missingField("threshold")
        }
        guard let rawPairs = value["pairs"]?.arrayValue else {
            throw ScanDecodingError.missingField("pairs")
        }
        return FolderScan(
            scanID: scanID,
            root: root,
            createdAt: createdAt,
            threshold: threshold,
            pairs: try rawPairs.map(decodePair)
        )
    }

    private static func decodePair(_ value: JSONValue) throws -> FolderPair {
        guard let folderA = value["folder_a"]?.stringValue else {
            throw ScanDecodingError.missingField("folder_a")
        }
        guard let folderB = value["folder_b"]?.stringValue else {
            throw ScanDecodingError.missingField("folder_b")
        }
        guard let similarity = value["similarity"]?.doubleValue else {
            throw ScanDecodingError.missingField("similarity")
        }
        guard let matching = value["matching"]?.intValue else {
            throw ScanDecodingError.missingField("matching")
        }
        guard let totalA = value["total_a"]?.intValue else {
            throw ScanDecodingError.missingField("total_a")
        }
        guard let totalB = value["total_b"]?.intValue else {
            throw ScanDecodingError.missingField("total_b")
        }
        return FolderPair(
            folderA: folderA,
            folderB: folderB,
            similarity: similarity,
            matching: Int(matching),
            onlyInA: try strings(value["only_in_a"], field: "only_in_a"),
            onlyInB: try strings(value["only_in_b"], field: "only_in_b"),
            changed: try strings(value["changed"], field: "changed"),
            totalA: Int(totalA),
            totalB: Int(totalB)
        )
    }

    private static func strings(_ value: JSONValue?, field: String) throws -> [String] {
        guard let raw = value?.arrayValue else {
            throw ScanDecodingError.missingField(field)
        }
        let items = raw.compactMap(\.stringValue)
        guard items.count == raw.count else {
            throw ScanDecodingError.notAString(field: field)
        }
        return items
    }
}
