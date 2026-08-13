import Foundation

/// What a disk check found, and when.
public struct PresenceSnapshot: Sendable, Equatable {
    /// Whether each group still had two or more files on disk, by **group key** rather than by index.
    ///
    /// Keyed on `"<size>:<digest>"` because an index only means something for one exact document, while a
    /// group key survives a rescan of the same content. It costs more bytes and cannot be wrong.
    public let stillDuplicateByKey: [String: Bool]
    /// When the check ran, in the same shape as every other timestamp here.
    public let checkedAt: String

    public init(stillDuplicateByKey: [String: Bool], checkedAt: String) {
        self.stillDuplicateByKey = stillDuplicateByKey
        self.checkedAt = checkedAt
    }

    /// The map ``GroupFilter`` wants, for one scan.
    ///
    /// A group whose key is absent stays absent -- not yet checked is not the same as gone, and the filter
    /// treats a missing entry as still a duplicate for exactly that reason.
    public func stillDuplicate(for scan: DuplicateScan) -> [Int: Bool] {
        var result: [Int: Bool] = [:]
        for (index, group) in scan.groups.enumerated() {
            if let known = stillDuplicateByKey[group.key] { result[index] = known }
        }
        return result
    }

    public var checkedCount: Int { stillDuplicateByKey.count }
    public var stillDuplicateCount: Int { stillDuplicateByKey.values.filter { $0 }.count }
}

/// Keeps the result of a disk check between sessions.
///
/// **Because it takes long enough to be worth not repeating**, and because the answer is useful even when
/// slightly old: a scan from May whose files are gone will still have them gone tomorrow.
///
/// **In `Caches`, never in the shared state directory.** Three reasons, and each alone would decide it: the
/// CLI cannot read it and would not know what it means; it is derived data that a rescan reproduces; and
/// `~/Library/Caches` is exactly the directory macOS may purge under disk pressure, which is the semantics
/// wanted for something that is only true at the instant it was taken.
///
/// **Nothing destructive may trust it.** The apply path re-hashes every file immediately before moving it,
/// so a snapshot that has gone stale costs a refused file and an honest error, never a wrong move. This is
/// a filter for a list, not a fact about the disk.
public struct PresenceCache: Sendable {
    private let directory: URL

    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let base =
            environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/Library/Caches"
        return URL(filePath: base + "/com.rogalvil.duplicate/presence")
    }

    public init(directory: URL = PresenceCache.defaultDirectory()) {
        self.directory = directory
    }

    private func url(for scanID: String) -> URL? {
        guard ScanIdentifier.isValid(scanID) else { return nil }
        return directory.appending(path: scanID + ".json", directoryHint: .notDirectory)
    }

    /// Reads a snapshot, or `nil` when there is none or it cannot be understood.
    ///
    /// A cache that cannot be parsed reads as absent: the worst that costs is one more disk check, and
    /// throwing here would mean a corrupt cache file could stop a review from opening.
    public func load(scanID: String) -> PresenceSnapshot? {
        guard let url = url(for: scanID),
            let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
            let value = try? JSONReader.parse(data),
            let checkedAt = value["checked_at"]?.stringValue,
            let groups = value["groups"]?.objectValue
        else { return nil }

        var map: [String: Bool] = [:]
        for member in groups {
            guard let flag = member.value.boolValue else { continue }
            map[member.key] = flag
        }
        guard !map.isEmpty else { return nil }
        return PresenceSnapshot(stillDuplicateByKey: map, checkedAt: checkedAt)
    }

    @discardableResult
    public func save(_ snapshot: PresenceSnapshot, scanID: String) throws -> String {
        guard let url = url(for: scanID) else {
            throw PresenceCacheError.invalidScanIdentifier(scanID)
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let document = JSONValue.object([
            JSONMember(key: "format_version", value: .int(1)),
            JSONMember(key: "checked_at", value: .string(snapshot.checkedAt)),
            JSONMember(
                key: "groups",
                value: .object(
                    // Sorted so the file is reproducible: two identical checks produce identical bytes,
                    // which makes a diff mean something.
                    snapshot.stillDuplicateByKey.keys.sorted().map { key in
                        JSONMember(
                            key: key, value: .bool(snapshot.stillDuplicateByKey[key] ?? false))
                    }
                )
            ),
        ])
        let path = url.path(percentEncoded: false)
        try JSONWriter.document(document).write(to: url, options: .atomic)
        return path
    }

    /// Forgets one scan's snapshot.
    @discardableResult
    public func forget(scanID: String) -> Bool {
        guard let url = url(for: scanID),
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

public enum PresenceCacheError: Error, Equatable, Sendable {
    case invalidScanIdentifier(String)
}
