import Foundation

/// The decisions of one perceptual review, as stored in `similar-decisions/<scan_id>.json`.
///
/// **A bare map, with no wrapper, and that is not a style choice.** `decisions/` wraps its map in
/// `{scan_id, created_at, decisions}` (`duplicate_review.py:168-177`) while this file *is* the map
/// (`similar_review.py:310-315`) -- verified against the 17 real documents on this machine. One type cannot
/// represent both honestly, so there are two.
///
/// **The entries are ordered, not a `Dictionary`.** The file's key order is the order the CLI wrote it, and a
/// `Dictionary` has no order at all: re-encoding one would shuffle 943 lines and the byte comparison that proves
/// the two tools are interchangeable would fail on a file whose *content* is identical. Same reason
/// ``JSONValue`` carries ordered members.
public struct SimilarDecisionsDocument: Hashable, Sendable {
    /// Decisions by pair key, in the order the document carried them.
    public let entries: [(key: String, decision: SimilarDecision)]

    public init(entries: [(key: String, decision: SimilarDecision)]) {
        self.entries = entries
    }

    /// A lookup, for rehydrating a review.
    public var byKey: [String: SimilarDecision] {
        Dictionary(entries.map { ($0.key, $0.decision) }, uniquingKeysWith: { first, _ in first })
    }

    public var count: Int { entries.count }

    /// How many entries carry each decision, for a summary that does not have to walk the file again.
    public func count(of decision: SimilarDecision) -> Int {
        entries.count { $0.decision == decision }
    }

    /// Keys that cannot be split back into two paths.
    ///
    /// The separator is two pipes and nothing is escaped, so a path containing `||` produces a key with three
    /// halves. Measured on this machine: **none of the 943 real keys is ambiguous**, and this reports the case
    /// rather than leaving a caller to discover it.
    public var ambiguousKeys: [String] {
        entries.map(\.key).filter {
            $0.components(separatedBy: SimilarPairKey.separator).count != 2
        }
    }

    public static func == (lhs: SimilarDecisionsDocument, rhs: SimilarDecisionsDocument) -> Bool {
        lhs.entries.map(\.key) == rhs.entries.map(\.key)
            && lhs.entries.map(\.decision) == rhs.entries.map(\.decision)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(entries.map(\.key))
        hasher.combine(entries.map(\.decision))
    }
}

/// Maps ``SimilarDecisionsDocument`` to and from the JSON `rav duplicate similar-review` reads and writes.
public enum SimilarDecisionsCodec {

    public static func encode(_ document: SimilarDecisionsDocument) -> JSONValue {
        .object(
            document.entries.map {
                JSONMember(key: $0.key, value: .string($0.decision.rawValue))
            })
    }

    public static func decode(_ value: JSONValue) throws -> SimilarDecisionsDocument {
        guard let members = value.objectValue else {
            throw ScanDecodingError.notAnObject(field: "<root>")
        }
        var entries: [(key: String, decision: SimilarDecision)] = []
        entries.reserveCapacity(members.count)
        for member in members {
            guard let raw = member.value.stringValue else {
                throw ScanDecodingError.notAString(field: member.key)
            }
            // **An unknown decision is refused, not skipped.** Dropping it would silently turn a reviewed pair
            // back into an unreviewed one, and the next apply would leave both files where they are while the
            // window said the pair was decided.
            guard let decision = SimilarDecision(rawValue: raw) else {
                throw ScanDecodingError.unknownDecision(raw, key: member.key)
            }
            entries.append((member.key, decision))
        }
        return SimilarDecisionsDocument(entries: entries)
    }
}
