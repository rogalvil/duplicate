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

/// The names chosen for one perceptual scan: for each group, the member whose name its kept file takes.
///
/// **Only that member, not the kept file.** A choice is set aside, not lost, while its group keeps two files -- and
/// then there is no single kept file to write down. The file that stays comes from the decisions; the member
/// identifies its group, since a file is in one group only (found in review on #229: a document of `keep`/`name_from`
/// pairs could only hold choices that were active, so keeping a second file erased the name from disk).
///
/// **A list, not a set of `String`s**, which would compare canonical equivalence and merge an NFC and an NFD spelling
/// of two files.
public struct SimilarRenamesDocument: Hashable, Sendable {
    public let nameSources: [String]

    public init(nameSources: [String]) {
        self.nameSources = nameSources
    }
}

/// `similar-renames/<scan_id>.json`: `{"format_version": 1, "name_from": [...]}`.
public enum SimilarRenamesCodec {
    public static let formatVersion = 1

    public static func encode(_ document: SimilarRenamesDocument) -> JSONValue {
        .object([
            JSONMember(key: "format_version", value: .int(Int64(formatVersion))),
            JSONMember(key: "name_from", value: .array(document.nameSources.map { .string($0) })),
        ])
    }

    public static func decode(_ value: JSONValue) throws -> SimilarRenamesDocument {
        // A document from a future layout is refused rather than half-read.
        guard value["format_version"]?.intValue == Int64(formatVersion) else {
            throw ScanDecodingError.notAnObject(field: "format_version")
        }
        guard let items = value["name_from"]?.arrayValue else {
            throw ScanDecodingError.notAnObject(field: "name_from")
        }
        return SimilarRenamesDocument(
            nameSources: try items.map { item in
                guard let path = item.stringValue else {
                    throw ScanDecodingError.notAString(field: "name_from")
                }
                return path
            })
    }
}
