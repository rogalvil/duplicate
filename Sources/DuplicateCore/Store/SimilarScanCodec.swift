import Foundation

/// What kind of file a similar pair is made of.
///
/// The CLI writes this as a bare string and reads it back the same way, so the raw values are interop and not
/// a naming choice.
public enum MediaKind: String, Sendable, Hashable, CaseIterable {
    case image
    case video
}

/// Two files that look alike, in the shape the CLI writes.
public struct SimilarPair: Sendable, Hashable {
    public let fileA: String
    public let fileB: String
    /// For images, `1.0 - hamming / 64.0`. For videos, the fraction of frames that matched.
    public let similarity: Double
    public let mediaKind: MediaKind

    public init(fileA: String, fileB: String, similarity: Double, mediaKind: MediaKind) {
        self.fileA = fileA
        self.fileB = fileB
        self.similarity = similarity
        self.mediaKind = mediaKind
    }
}

/// One perceptual scan, as stored in `similar-scans/<scan_id>.json`.
public struct SimilarScan: Sendable, Hashable {
    public let scanID: String
    public let root: String
    /// An opaque string, like every other timestamp here.
    public let createdAt: String
    /// Maximum Hamming distance for images, out of 64. **An integer.**
    public let imageThreshold: Int
    /// Minimum fraction of frames that must match for videos. **A float.**
    public let videoThreshold: Double
    public let pairs: [SimilarPair]

    public init(
        scanID: String,
        root: String,
        createdAt: String,
        imageThreshold: Int,
        videoThreshold: Double,
        pairs: [SimilarPair]
    ) {
        self.scanID = scanID
        self.root = root
        self.createdAt = createdAt
        self.imageThreshold = imageThreshold
        self.videoThreshold = videoThreshold
        self.pairs = pairs
    }

    public var pairCount: Int { pairs.count }
    public func pairCount(of kind: MediaKind) -> Int {
        pairs.count { $0.mediaKind == kind }
    }
    /// How many distinct files appear in at least one pair.
    public var involvedFileCount: Int {
        var files: Set<String> = []
        for pair in pairs {
            files.insert(pair.fileA)
            files.insert(pair.fileB)
        }
        return files.count
    }
    public var hasRelativePaths: Bool {
        !root.hasPrefix("/") || pairs.contains { !$0.fileA.hasPrefix("/") }
    }
}

/// Maps ``SimilarScan`` to and from the JSON `rav duplicate similar` reads and writes.
///
/// The shape is from `perceptual.py:38-64` and was verified against the 31 real documents on this machine:
/// `{scan_id, root, created_at, img_threshold, vid_threshold, pairs[]}` with pair keys `file_a`, `file_b`,
/// `similarity`, `media_type`.
///
/// **Two number types in one document, again, and they are opposites.** `img_threshold` is an **integer** -- a
/// Hamming distance out of 64, measured as `int` in all 31 documents -- while `vid_threshold` is a **float**, a
/// fraction of frames. Emitting `10.0` for the first breaks the byte comparison exactly as emitting `1` for
/// `similarity` would, and `"similarity": 1.0` is the most common value in the corpus: **1,100 of 1,271
/// pairs**, because an identical pair is the ordinary case.
///
/// **No perceptual hash appears here.** That is what makes this app's hash free to differ from
/// `imagehash.phash` -- there is nothing in the shared format that would become unreadable. What *is* shared is
/// `similarity`, which is derived from the hash, so a scan written by Python and one written by Swift can show
/// slightly different numbers for the same pair. Measured: 90.4% of 2,779 real photographs hash bit-identically,
/// so most pairs agree exactly, and the rest differ in the last bits of a number that is only rendered and
/// compared against a threshold.
public enum SimilarScanCodec {

    public static func encode(_ scan: SimilarScan) -> JSONValue {
        .object([
            JSONMember(key: "scan_id", value: .string(scan.scanID)),
            JSONMember(key: "root", value: .string(scan.root)),
            JSONMember(key: "created_at", value: .string(scan.createdAt)),
            JSONMember(key: "img_threshold", value: .int(Int64(scan.imageThreshold))),
            JSONMember(key: "vid_threshold", value: .double(scan.videoThreshold)),
            JSONMember(key: "pairs", value: .array(scan.pairs.map(encodePair))),
        ])
    }

    private static func encodePair(_ pair: SimilarPair) -> JSONValue {
        .object([
            JSONMember(key: "file_a", value: .string(pair.fileA)),
            JSONMember(key: "file_b", value: .string(pair.fileB)),
            JSONMember(key: "similarity", value: .double(pair.similarity)),
            JSONMember(key: "media_type", value: .string(pair.mediaKind.rawValue)),
        ])
    }

    public static func decode(_ value: JSONValue) throws -> SimilarScan {
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
        guard let imageThreshold = value["img_threshold"]?.intValue else {
            throw ScanDecodingError.missingField("img_threshold")
        }
        guard let videoThreshold = value["vid_threshold"]?.doubleValue else {
            throw ScanDecodingError.missingField("vid_threshold")
        }
        guard let rawPairs = value["pairs"]?.arrayValue else {
            throw ScanDecodingError.missingField("pairs")
        }
        return SimilarScan(
            scanID: scanID,
            root: root,
            createdAt: createdAt,
            imageThreshold: Int(imageThreshold),
            videoThreshold: videoThreshold,
            pairs: try rawPairs.map(decodePair)
        )
    }

    private static func decodePair(_ value: JSONValue) throws -> SimilarPair {
        guard let fileA = value["file_a"]?.stringValue else {
            throw ScanDecodingError.missingField("file_a")
        }
        guard let fileB = value["file_b"]?.stringValue else {
            throw ScanDecodingError.missingField("file_b")
        }
        guard let similarity = value["similarity"]?.doubleValue else {
            throw ScanDecodingError.missingField("similarity")
        }
        guard let rawKind = value["media_type"]?.stringValue else {
            throw ScanDecodingError.missingField("media_type")
        }
        // An unknown media type is refused rather than guessed. The value decides which threshold the pair was
        // judged against, so treating an unrecognised one as an image would misreport what the scan found.
        guard let kind = MediaKind(rawValue: rawKind) else {
            throw ScanDecodingError.unknownMediaType(rawKind)
        }
        return SimilarPair(fileA: fileA, fileB: fileB, similarity: similarity, mediaKind: kind)
    }
}
