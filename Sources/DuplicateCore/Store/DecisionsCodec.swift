/// One saved review, as stored in `duplicate/decisions/<scan_id>.json`.
public struct DecisionsDocument: Hashable, Sendable {
    public let scanID: String
    /// ISO-8601 with a `Z` suffix, the same shape the scan format uses.
    public let createdAt: String
    /// Kept paths by group key, in the order the document carried them.
    public let decisions: [(key: String, keptPaths: [String])]

    public init(scanID: String, createdAt: String, decisions: [(key: String, keptPaths: [String])])
    {
        self.scanID = scanID
        self.createdAt = createdAt
        self.decisions = decisions
    }

    /// A lookup, for rehydrating a review.
    public var byKey: [String: [String]] {
        Dictionary(
            decisions.map { ($0.key, $0.keptPaths) }, uniquingKeysWith: { first, _ in first })
    }

    public static func == (lhs: DecisionsDocument, rhs: DecisionsDocument) -> Bool {
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

/// Maps ``DecisionsDocument`` to and from its persisted JSON representation.
///
/// The wrapped shape is `{scan_id, created_at, decisions: {…}}`. Media decisions use a bare map instead,
/// so the two formats deliberately have separate types.
///
/// **Absence is the contract.** A group the user never decided has no key here, so applying a partially
/// reviewed scan acts only on reviewed groups.
public enum DecisionsCodec {
    public static func encode(_ document: DecisionsDocument) -> JSONValue {
        .object([
            JSONMember(key: "scan_id", value: .string(document.scanID)),
            JSONMember(key: "created_at", value: .string(document.createdAt)),
            JSONMember(
                key: "decisions",
                value: .object(
                    document.decisions.map { entry in
                        JSONMember(
                            key: entry.key,
                            value: .array(entry.keptPaths.map(JSONValue.string))
                        )
                    }
                )
            ),
        ])
    }

    public static func decode(_ value: JSONValue) throws -> DecisionsDocument {
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
        for member in members {
            guard let raw = member.value.arrayValue else {
                throw ScanDecodingError.notAnObject(field: "decisions.\(member.key)")
            }
            let paths = raw.compactMap(\.stringValue)
            guard paths.count == raw.count else {
                throw ScanDecodingError.notAString(field: "decisions.\(member.key)")
            }
            decisions.append((member.key, paths))
        }
        return DecisionsDocument(scanID: scanID, createdAt: createdAt, decisions: decisions)
    }

    /// Builds a document from a review.
    public static func document(
        from state: ExactReviewState,
        instant: ScanIdentifier.Instant
    ) -> DecisionsDocument {
        DecisionsDocument(
            scanID: state.scan.scanID,
            createdAt: instant.timestamp,
            decisions: state.decisionsForSaving
        )
    }
}
