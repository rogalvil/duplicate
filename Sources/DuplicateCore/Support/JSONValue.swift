/// A JSON tree that preserves key order.
///
/// Foundation has no such type. `JSONSerialization` hands back an `NSDictionary`, which has no
/// order, and `JSONEncoder` writes keys in declaration or sorted order depending on options. Neither
/// can reproduce a document whose key order is significant -- and the format shared with the
/// `rav duplicate` CLI is exactly that, because Python's `json.dumps` writes dictionary keys in
/// insertion order.
public enum JSONValue: Sendable, Equatable {
    /// Members in document order. Duplicate keys are possible in malformed input and preserved.
    case object([JSONMember])
    case array([JSONValue])
    case string(String)
    /// An integer literal: written with no decimal point, the way Python writes an `int`.
    case int(Int64)
    /// A floating-point literal: `1.0` stays `1.0`, the way Python writes a `float`.
    case double(Double)
    case bool(Bool)
    case null

    /// Builds an object from a literal, preserving the written order.
    ///
    /// `KeyValuePairs` rather than `[(String, JSONValue)]` so the call site reads as a dictionary
    /// literal, and so it cannot be confused with the `[JSONMember]` case at overload resolution.
    /// Unlike `Dictionary`, it keeps the order it was written in -- which is the whole point.
    public static func object(_ pairs: KeyValuePairs<String, JSONValue>) -> JSONValue {
        .object(pairs.map { JSONMember(key: $0.key, value: $0.value) })
    }

    /// The value for `key`, or `nil`. First match wins, as `json.loads` would produce.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    /// The element at `index`, or `nil`.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// The value as an `Int64`, accepting only an integer literal.
    ///
    /// A `double` is deliberately not converted: a size written as `1.0` in a scan file would mean
    /// the file was not written by the CLI, and silently coercing it would hide that.
    public var intValue: Int64? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    /// The value as a `Double`, accepting either literal form, since a threshold of `1` and a
    /// threshold of `1.0` mean the same thing.
    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int(let value): Double(value)
        default: nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let elements) = self else { return nil }
        return elements
    }

    public var objectValue: [JSONMember]? {
        guard case .object(let members) = self else { return nil }
        return members
    }
}

/// One `"key": value` pair, in document order.
public struct JSONMember: Sendable, Equatable {
    public let key: String
    public let value: JSONValue

    public init(key: String, value: JSONValue) {
        self.key = key
        self.value = value
    }
}
