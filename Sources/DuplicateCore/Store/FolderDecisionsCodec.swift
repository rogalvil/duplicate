import Foundation

/// The decisions of one folder review, as stored in `folder-decisions/<scan_id>.json`.
///
/// **A third shape, different from the other two.** `decisions/` wraps a map of group key to kept paths;
/// `similar-decisions/` is a bare map of pair key to one enum string; this one is **wrapped like the first and
/// keyed like the second**: `{scan_id, created_at, decisions: {"a||b": ["<kept folder>"]}}`
/// (`folder_review.py:95-105`). Three formats, three types.
///
/// **And this is the one with no real file to check against.** `folder-decisions/` does not exist on this
/// machine -- the CLI has the slot and has never written one -- so unlike the other two, the round-trip here is
/// proven against a synthesized document and the CLI's source, not against something the CLI actually wrote.
/// Said plainly because it is the weakest interop claim in the project.
public struct FolderDecisionsDocument: Hashable, Sendable {
    public let scanID: String
    public let createdAt: String
    /// Kept folders by pair key, in the order the document carried them.
    public let decisions: [(key: String, keptPaths: [String])]

    public init(scanID: String, createdAt: String, decisions: [(key: String, keptPaths: [String])])
    {
        self.scanID = scanID
        self.createdAt = createdAt
        self.decisions = decisions
    }

    public var byKey: [String: [String]] {
        Dictionary(
            decisions.map { ($0.key, $0.keptPaths) }, uniquingKeysWith: { first, _ in first })
    }

    public var count: Int { decisions.count }

    public static func == (lhs: FolderDecisionsDocument, rhs: FolderDecisionsDocument) -> Bool {
        lhs.scanID == rhs.scanID && lhs.createdAt == rhs.createdAt
            && lhs.decisions.map(\.key) == rhs.decisions.map(\.key)
            && lhs.decisions.map(\.keptPaths) == rhs.decisions.map(\.keptPaths)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(scanID)
        hasher.combine(createdAt)
        hasher.combine(decisions.map(\.key))
    }
}

/// Maps ``FolderDecisionsDocument`` to and from the JSON `rav duplicate folders-review` reads and writes.
public enum FolderDecisionsCodec {

    public static func encode(_ document: FolderDecisionsDocument) -> JSONValue {
        .object([
            JSONMember(key: "scan_id", value: .string(document.scanID)),
            JSONMember(key: "created_at", value: .string(document.createdAt)),
            JSONMember(
                key: "decisions",
                value: .object(
                    document.decisions.map {
                        JSONMember(
                            key: $0.key, value: .array($0.keptPaths.map(JSONValue.string)))
                    })),
        ])
    }

    public static func decode(_ value: JSONValue) throws -> FolderDecisionsDocument {
        guard value.objectValue != nil else {
            throw ScanDecodingError.notAnObject(field: "<root>")
        }
        guard let scanID = value["scan_id"]?.stringValue else {
            throw ScanDecodingError.missingField("scan_id")
        }
        guard ScanIdentifier.isValid(scanID) else {
            throw ScanDecodingError.malformedScanIdentifier(scanID)
        }
        guard let createdAt = value["created_at"]?.stringValue else {
            throw ScanDecodingError.missingField("created_at")
        }
        guard let members = value["decisions"]?.objectValue else {
            throw ScanDecodingError.missingField("decisions")
        }
        var decisions: [(key: String, keptPaths: [String])] = []
        decisions.reserveCapacity(members.count)
        for member in members {
            guard let raw = member.value.arrayValue else {
                throw ScanDecodingError.notAnObject(field: member.key)
            }
            let paths = raw.compactMap(\.stringValue)
            guard paths.count == raw.count else {
                throw ScanDecodingError.notAString(field: member.key)
            }
            decisions.append((member.key, paths))
        }
        return FolderDecisionsDocument(
            scanID: scanID, createdAt: createdAt, decisions: decisions)
    }
}
