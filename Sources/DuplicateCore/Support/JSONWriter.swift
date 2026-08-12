import Foundation

/// Writes JSON byte-for-byte the way Python's `json.dumps(obj, indent=2)` writes it.
///
/// Hand-rolled because neither Foundation encoder can produce these bytes, and the format is a
/// contract shared with a tool that is already in use. Five differences, every one verified against
/// the files the CLI actually wrote:
///
/// 1. **Non-ASCII is escaped.** Python defaults to `ensure_ascii=True`, so `é` is written `é`
///    and an emoji becomes a surrogate pair. `JSONEncoder` emits raw UTF-8.
/// 2. **Whole floats keep their point.** A similarity of exactly 1 is written `1.0`;
///    `JSONEncoder` writes `1`. Swift's `Double.description` already matches Python's `repr`
///    for every value tested, including the exponent forms `1e-05` and `1e+16`.
/// 3. **Two-space indent, `": "` after a key, `,` then a newline between items**, and empty
///    containers inline as `[]` and `{}`.
/// 4. **Key order is insertion order**, never sorted.
/// 5. **`/` is not escaped**, and control characters use the short forms `\b \f \n \r \t` where
///    they exist and lowercase `\u00XX` otherwise.
///
/// `JSONSerialization` with `.prettyPrinted` was rejected for the same reasons as `JSONEncoder`,
/// plus it has no way to control key order at all.
public enum JSONWriter {
    /// The `json.dumps(value, indent=2)` equivalent, with no trailing newline.
    public static func encode(_ value: JSONValue) throws -> String {
        var output = ""
        try append(value, depth: 0, into: &output)
        return output
    }

    /// The full file contents the CLI writes: `json.dumps(..., indent=2) + "\n"`.
    ///
    /// `save_scan` in `src/rav/core/duplicates.py:107` appends that newline, so a document without
    /// it differs from the CLI's output in its last byte.
    public static func document(_ value: JSONValue) throws -> Data {
        Data((try encode(value) + "\n").utf8)
    }

    // MARK: - Serialisation

    private static func append(_ value: JSONValue, depth: Int, into output: inout String) throws {
        switch value {
        case .null:
            output += "null"
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .int(let number):
            output += String(number)
        case .double(let number):
            guard number.isFinite else {
                // Python would happily write NaN or Infinity, which are not valid JSON. Refusing is
                // the honest choice: a non-finite similarity is a bug upstream, and writing it would
                // produce a file only Python could read back.
                throw JSONWriterError.nonFiniteNumber(number)
            }
            output += number.description
        case .string(let text):
            appendEscaped(text, into: &output)
        case .array(let elements):
            if elements.isEmpty {
                output += "[]"
                return
            }
            let inner = String(repeating: " ", count: (depth + 1) * 2)
            output += "[\n"
            for (index, element) in elements.enumerated() {
                output += inner
                try append(element, depth: depth + 1, into: &output)
                output += index == elements.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: depth * 2) + "]"
        case .object(let members):
            if members.isEmpty {
                output += "{}"
                return
            }
            let inner = String(repeating: " ", count: (depth + 1) * 2)
            output += "{\n"
            for (index, member) in members.enumerated() {
                output += inner
                appendEscaped(member.key, into: &output)
                output += ": "
                try append(member.value, depth: depth + 1, into: &output)
                output += index == members.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: " ", count: depth * 2) + "}"
        }
    }

    /// Escapes exactly as `json.encoder.py_encode_basestring_ascii` does.
    private static func appendEscaped(_ text: String, into output: inout String) {
        output.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            default:
                let code = scalar.value
                if code >= 0x20, code < 0x7F {
                    // Printable ASCII, including '/', which Python does not escape.
                    output.unicodeScalars.append(scalar)
                } else if code <= 0xFFFF {
                    output += escapeUnit(UInt16(code))
                } else {
                    // Astral plane: Python emits a UTF-16 surrogate pair, not \U0001f600.
                    let offset = code - 0x10000
                    output += escapeUnit(UInt16(0xD800 + (offset >> 10)))
                    output += escapeUnit(UInt16(0xDC00 + (offset & 0x3FF)))
                }
            }
        }
        output.append("\"")
    }

    /// `\uXXXX` with lowercase hex, which is what Python emits.
    private static func escapeUnit(_ unit: UInt16) -> String {
        let digits = Array("0123456789abcdef")
        var result = "\\u"
        for shift in [12, 8, 4, 0] {
            result.append(digits[Int((unit >> UInt16(shift)) & 0xF)])
        }
        return result
    }
}

public enum JSONWriterError: Error, Equatable, Sendable {
    /// A NaN or infinite double, which has no valid JSON representation.
    case nonFiniteNumber(Double)
}
