import Foundation

/// Keeping the file of one member of a perceptual group under the name of another (#228).
///
/// The case it is for: "photo copy.jpg" has the better picture and stays, and "photo.jpg" -- the name worth keeping --
/// goes. The kept file is renamed **in its own folder**, and **keeps its own extension**: a PNG under the name of a
/// JPEG would be a file that says it is something it is not.
public struct SimilarRename: Hashable, Sendable {
    /// The file that stays.
    public let keptPath: String
    /// The member whose name it takes.
    public let nameFromPath: String

    public init(keptPath: String, nameFromPath: String) {
        self.keptPath = keptPath
        self.nameFromPath = nameFromPath
    }

    /// Where the kept file goes: its own folder, the other's name without its extension, its own extension.
    ///
    /// **Cut on bytes, not with `NSString`'s path methods**, which tidy what they return: they collapse a `//`, so the
    /// target stopped being, byte for byte, the path the other file left -- and the undo, which matches paths by
    /// bytes, could no longer tell that putting the rename back frees the other file's place.
    public var targetPath: String {
        let kept = Self.split(keptPath)
        let source = Self.split(nameFromPath)
        let name = kept.ext.map { source.stem + [UInt8(ascii: ".")] + $0 } ?? source.stem
        return String(decoding: kept.folder + name, as: UTF8.self)
    }

    /// A path as its folder (with the trailing slash), the name before its last dot, and what follows that dot.
    ///
    /// A dot that starts the name is not an extension: `.profile` has none. Every cut is at an ASCII byte, so each
    /// piece stays valid UTF-8.
    private static func split(_ path: String) -> (folder: [UInt8], stem: [UInt8], ext: [UInt8]?) {
        let bytes = Array(path.utf8)
        let nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        let name = bytes[nameStart...]
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot > nameStart else {
            return (Array(bytes[..<nameStart]), Array(name), nil)
        }
        return (
            Array(bytes[..<nameStart]), Array(bytes[nameStart..<dot]), Array(bytes[(dot + 1)...])
        )
    }

    /// Whether the name would not change: the two already share a name and an extension in one folder.
    public var isNoOp: Bool { PathOrder.equal(targetPath, keptPath) }
}

/// Why an apply left a kept file under its own name.
public enum SimilarRenameRefusal: Sendable, Equatable {
    /// The kept file is gone.
    case keptMissing
    /// The file whose name it was to take is still there: refused, failed, or never reached. Its name is not free.
    case nameSourceStayed
    /// Something else already has the name. **Never overwritten.**
    case nameTaken
    /// The kept file could not be read, so there is no digest to put it back by.
    case unreadable
}

/// The renames chosen for one perceptual scan, in the order they were chosen.
///
/// **A list, not a map keyed by path.** A `String` key compares canonical equivalence, so an NFC and an NFD spelling
/// of two different files would collapse into one entry.
public struct SimilarRenamesDocument: Hashable, Sendable {
    public let renames: [SimilarRename]

    public init(renames: [SimilarRename]) {
        self.renames = renames
    }
}

/// `similar-renames/<scan_id>.json`: `{"format_version": 1, "renames": [{"keep": ..., "name_from": ...}]}`.
public enum SimilarRenamesCodec {
    public static let formatVersion = 1

    public static func encode(_ document: SimilarRenamesDocument) -> JSONValue {
        .object([
            JSONMember(key: "format_version", value: .int(Int64(formatVersion))),
            JSONMember(
                key: "renames",
                value: .array(
                    document.renames.map {
                        .object([
                            JSONMember(key: "keep", value: .string($0.keptPath)),
                            JSONMember(key: "name_from", value: .string($0.nameFromPath)),
                        ])
                    })),
        ])
    }

    public static func decode(_ value: JSONValue) throws -> SimilarRenamesDocument {
        // A document from a future layout is refused rather than half-read.
        guard value["format_version"]?.intValue == Int64(formatVersion) else {
            throw ScanDecodingError.notAnObject(field: "format_version")
        }
        guard let items = value["renames"]?.arrayValue else {
            throw ScanDecodingError.notAnObject(field: "renames")
        }
        return SimilarRenamesDocument(
            renames: try items.map { item in
                guard let keep = item["keep"]?.stringValue else {
                    throw ScanDecodingError.notAString(field: "keep")
                }
                guard let nameFrom = item["name_from"]?.stringValue else {
                    throw ScanDecodingError.notAString(field: "name_from")
                }
                return SimilarRename(keptPath: keep, nameFromPath: nameFrom)
            })
    }
}
