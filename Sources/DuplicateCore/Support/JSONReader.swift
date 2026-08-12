import Foundation

/// Parses JSON into a ``JSONValue``, preserving key order and the integer/float distinction.
///
/// Exists for one reason: to make byte-for-byte compatibility with the `rav duplicate` CLI a
/// measurement rather than an argument. Reading a real scan file, re-encoding it with
/// ``JSONWriter``, and diffing the bytes proves the contract holds on data that already exists.
/// `JSONSerialization` cannot serve that purpose -- it returns an unordered `NSDictionary` and
/// collapses `1` and `1.0` into the same `NSNumber`, so a re-encode could never be byte-identical.
///
/// Deliberately strict: no comments, no trailing commas, no unquoted keys, no NaN or Infinity
/// literals. Python's `json.loads` accepts the last of those; this does not, because a non-finite
/// similarity in a scan file is a bug to surface rather than a value to carry forward.
public enum JSONReader {
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw JSONReaderError.trailingData(offset: parser.offset)
        }
        return value
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset >= bytes.count }

        mutating func skipWhitespace() {
            while offset < bytes.count {
                switch bytes[offset] {
                case 0x20, 0x09, 0x0A, 0x0D: offset += 1
                default: return
                }
            }
        }

        mutating func parseValue() throws -> JSONValue {
            guard offset < bytes.count else {
                throw JSONReaderError.unexpectedEnd(offset: offset)
            }
            switch bytes[offset] {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try parseNumber()
            }
        }

        mutating func parseObject() throws -> JSONValue {
            offset += 1  // '{'
            var members: [JSONMember] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "}") {
                offset += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else {
                    throw JSONReaderError.expectedKey(offset: offset)
                }
                let key = try parseString()
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else {
                    throw JSONReaderError.expectedColon(offset: offset)
                }
                offset += 1
                skipWhitespace()
                members.append(JSONMember(key: key, value: try parseValue()))
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","):
                    offset += 1
                case UInt8(ascii: "}"):
                    offset += 1
                    return .object(members)
                default:
                    throw JSONReaderError.expectedCommaOrEnd(offset: offset)
                }
            }
        }

        mutating func parseArray() throws -> JSONValue {
            offset += 1  // '['
            var elements: [JSONValue] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") {
                offset += 1
                return .array(elements)
            }
            while true {
                skipWhitespace()
                elements.append(try parseValue())
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","):
                    offset += 1
                case UInt8(ascii: "]"):
                    offset += 1
                    return .array(elements)
                default:
                    throw JSONReaderError.expectedCommaOrEnd(offset: offset)
                }
            }
        }

        mutating func parseString() throws -> String {
            offset += 1  // opening quote
            var units: [UInt16] = []
            var literal: [UInt8] = []

            func flushLiteral() {
                guard !literal.isEmpty else { return }
                units.append(contentsOf: Array(String(decoding: literal, as: UTF8.self).utf16))
                literal.removeAll(keepingCapacity: true)
            }

            while offset < bytes.count {
                let byte = bytes[offset]
                if byte == UInt8(ascii: "\"") {
                    offset += 1
                    flushLiteral()
                    guard let text = String(units: units) else {
                        throw JSONReaderError.invalidEscape(offset: offset)
                    }
                    return text
                }
                if byte == UInt8(ascii: "\\") {
                    flushLiteral()
                    offset += 1
                    guard offset < bytes.count else {
                        throw JSONReaderError.unexpectedEnd(offset: offset)
                    }
                    let escape = bytes[offset]
                    offset += 1
                    switch escape {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        // Kept as a raw UTF-16 unit rather than decoded here, so a surrogate pair
                        // written as two separate escapes reassembles correctly.
                        units.append(try parseHex4())
                    default:
                        throw JSONReaderError.invalidEscape(offset: offset - 1)
                    }
                    continue
                }
                if byte < 0x20 {
                    throw JSONReaderError.unescapedControlCharacter(offset: offset)
                }
                literal.append(byte)
                offset += 1
            }
            throw JSONReaderError.unexpectedEnd(offset: offset)
        }

        mutating func parseHex4() throws -> UInt16 {
            guard offset + 4 <= bytes.count else {
                throw JSONReaderError.unexpectedEnd(offset: offset)
            }
            var value: UInt16 = 0
            for _ in 0..<4 {
                guard let nibble = Self.nibble(bytes[offset]) else {
                    throw JSONReaderError.invalidEscape(offset: offset)
                }
                value = value << 4 | UInt16(nibble)
                offset += 1
            }
            return value
        }

        /// Reads a number, and keeps Python's distinction: an integer literal has no `.`, `e` or `E`.
        mutating func parseNumber() throws -> JSONValue {
            let start = offset
            var isFloat = false
            if peek() == UInt8(ascii: "-") { offset += 1 }
            while offset < bytes.count {
                let byte = bytes[offset]
                if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                    offset += 1
                } else if byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e")
                    || byte == UInt8(ascii: "E")
                {
                    isFloat = true
                    offset += 1
                } else if byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") {
                    // Only valid inside an exponent; the conversion below rejects anything else.
                    offset += 1
                } else {
                    break
                }
            }
            guard offset > start else {
                throw JSONReaderError.invalidNumber(offset: start)
            }
            let text = String(decoding: bytes[start..<offset], as: UTF8.self)
            if isFloat {
                guard let value = Double(text), value.isFinite else {
                    throw JSONReaderError.invalidNumber(offset: start)
                }
                return .double(value)
            }
            guard let value = Int64(text) else {
                throw JSONReaderError.invalidNumber(offset: start)
            }
            return .int(value)
        }

        mutating func expect(_ literal: String) throws {
            let expected = Array(literal.utf8)
            guard offset + expected.count <= bytes.count,
                Array(bytes[offset..<(offset + expected.count)]) == expected
            else {
                throw JSONReaderError.invalidLiteral(offset: offset)
            }
            offset += expected.count
        }

        func peek() -> UInt8? { offset < bytes.count ? bytes[offset] : nil }

        static func nibble(_ ascii: UInt8) -> UInt8? {
            switch ascii {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): ascii - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): ascii - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): ascii - UInt8(ascii: "A") + 10
            default: nil
            }
        }
    }
}

public enum JSONReaderError: Error, Equatable, Sendable {
    case unexpectedEnd(offset: Int)
    case trailingData(offset: Int)
    case expectedKey(offset: Int)
    case expectedColon(offset: Int)
    case expectedCommaOrEnd(offset: Int)
    case invalidEscape(offset: Int)
    case invalidLiteral(offset: Int)
    case invalidNumber(offset: Int)
    case unescapedControlCharacter(offset: Int)
}

extension String {
    /// Builds a string from UTF-16 units, returning `nil` on an unpaired surrogate.
    fileprivate init?(units: [UInt16]) {
        var scalars = String.UnicodeScalarView()
        var index = 0
        while index < units.count {
            let unit = units[index]
            if unit >= 0xD800, unit <= 0xDBFF {
                guard index + 1 < units.count,
                    units[index + 1] >= 0xDC00, units[index + 1] <= 0xDFFF
                else { return nil }
                let high = UInt32(unit - 0xD800) << 10
                let low = UInt32(units[index + 1] - 0xDC00)
                guard let scalar = Unicode.Scalar(high + low + 0x10000) else { return nil }
                scalars.append(scalar)
                index += 2
                continue
            }
            if unit >= 0xDC00, unit <= 0xDFFF { return nil }
            guard let scalar = Unicode.Scalar(unit) else { return nil }
            scalars.append(scalar)
            index += 1
        }
        self = String(scalars)
    }
}
