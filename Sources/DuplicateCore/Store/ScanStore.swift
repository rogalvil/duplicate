import Foundation

/// Reads and writes the documents shared with the `rav duplicate` CLI.
///
/// **Every write is atomic.** The CLI uses `Path.write_text`, which is not
/// (`src/rav/core/duplicates.py:107`): a crash or a full disk mid-write leaves a truncated JSON document
/// where a scan used to be, and the next read of it fails. `Data.write(options: .atomic)` writes a
/// temporary file and renames it, so a reader sees either the old document or the new one. Strict
/// improvement with zero impact on the format.
public struct ScanStore: Sendable {
    private let state: StateDirectory

    public init(state: StateDirectory = .current()) {
        self.state = state
    }

    // MARK: - Scans

    /// Writes a scan, and returns where it went.
    ///
    /// The filename and the `scan_id` inside always agree, because both come from the same value. A
    /// mismatch would mean re-saving this scan either overwrites a different one or silently renames it.
    @discardableResult
    public func save(_ scan: DuplicateScan) throws -> String {
        try state.create(.scans)
        let path = try state.filePath(for: .scans, id: scan.scanID)
        let data = try JSONWriter.document(DuplicateScanCodec.encode(scan))
        try data.write(to: URL(filePath: path), options: .atomic)
        return path
    }

    public func loadScan(id: String) throws -> DuplicateScan {
        let path = try state.filePath(for: .scans, id: id)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StoreError.notFound(kind: .scans, id: id)
        }
        return try DuplicateScanCodec.decode(JSONReader.parse(data))
    }

    // MARK: - Folder scans

    @discardableResult
    public func save(_ scan: FolderScan) throws -> String {
        try state.create(.folderScans)
        let path = try state.filePath(for: .folderScans, id: scan.scanID)
        let data = try JSONWriter.document(FolderScanCodec.encode(scan))
        try data.write(to: URL(filePath: path), options: .atomic)
        return path
    }

    public func loadFolderScan(id: String) throws -> FolderScan {
        let path = try state.filePath(for: .folderScans, id: id)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StoreError.notFound(kind: .folderScans, id: id)
        }
        return try FolderScanCodec.decode(JSONReader.parse(data))
    }

    /// A summary of one folder scan for a list.
    public struct FolderSummary: Sendable, Hashable {
        public let scanID: String
        public let root: String
        public let createdAt: String
        public let threshold: Double
        public let pairCount: Int
        public let involvedFolderCount: Int
        public let hasRelativePaths: Bool
    }

    /// Summaries for every readable folder scan, newest first.
    public func folderSummaries() -> [FolderSummary] {
        identifiers(in: .folderScans).compactMap { id in
            guard let scan = try? loadFolderScan(id: id) else { return nil }
            return FolderSummary(
                scanID: scan.scanID,
                root: scan.root,
                createdAt: scan.createdAt,
                threshold: scan.threshold,
                pairCount: scan.pairCount,
                involvedFolderCount: scan.involvedFolderCount,
                hasRelativePaths: scan.hasRelativePaths
            )
        }
    }

    // MARK: - Decisions

    @discardableResult
    public func save(_ decisions: DecisionsDocument) throws -> String {
        try state.create(.decisions)
        let path = try state.filePath(for: .decisions, id: decisions.scanID)
        let data = try JSONWriter.document(DecisionsCodec.encode(decisions))
        try data.write(to: URL(filePath: path), options: .atomic)
        return path
    }

    public func loadDecisions(scanID: String) throws -> DecisionsDocument {
        let path = try state.filePath(for: .decisions, id: scanID)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StoreError.notFound(kind: .decisions, id: scanID)
        }
        return try DecisionsCodec.decode(JSONReader.parse(data))
    }

    /// The decisions for a scan, or an empty lookup when there are none.
    ///
    /// The shape a review needs: "no saved decisions" and "a saved review with nothing decided" both mean
    /// start fresh, and neither is an error worth surfacing.
    public func priorDecisions(scanID: String) -> [String: [String]] {
        (try? loadDecisions(scanID: scanID))?.byKey ?? [:]
    }

    /// Removes a scan and the decisions saved beside it.
    ///
    /// **Both, because a decisions file without its scan is unreadable.** It is keyed by group digests that
    /// only the scan explains, so leaving it behind would leave a file nothing can interpret and nothing
    /// will ever clean up.
    ///
    /// A missing file is not an error: deleting something already gone is the outcome the caller wanted.
    @discardableResult
    public func delete(id: String) throws -> Bool {
        let scan = try state.filePath(for: .scans, id: id)
        let decisions = try state.filePath(for: .decisions, id: id)
        var removed = false
        for path in [scan, decisions] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            removed = true
        }
        return removed
    }

    // MARK: - Listing

    /// Identifiers in a slot, newest first.
    ///
    /// Sorted descending on the identifier itself, which works because the format is
    /// `%Y%m%d-%H%M%S-%f`: lexicographic order is chronological order. Anything that is not a valid
    /// identifier is ignored rather than guessed at.
    public func identifiers(in slot: StateDirectory.Slot) -> [String] {
        let directory = state.path(for: slot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return
            names
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .filter(ScanIdentifier.isValid)
            .sorted(by: >)
    }

    /// A summary of one scan for a list, without holding every group in memory.
    public struct Summary: Sendable, Hashable {
        public let scanID: String
        public let root: String
        public let createdAt: String
        public let groupCount: Int
        public let fileCount: Int
        public let reclaimableBytes: Int64
        public let isReclaimExact: Bool
        /// Whether a decisions file exists beside it.
        public let hasDecisions: Bool
        /// Whether the scan recorded relative paths, which cannot be acted on as-is.
        public let hasRelativePaths: Bool
    }

    /// Summaries for every readable scan, newest first.
    ///
    /// A scan that fails to decode is skipped rather than aborting the list: one corrupt file must not hide
    /// every other scan the user has.
    public func summaries() -> [Summary] {
        identifiers(in: .scans).compactMap { id in
            guard let scan = try? loadScan(id: id) else { return nil }
            return Summary(
                scanID: scan.scanID,
                root: scan.root,
                createdAt: scan.createdAt,
                groupCount: scan.groups.count,
                fileCount: scan.fileCount,
                reclaimableBytes: scan.reclaimableBytes,
                isReclaimExact: scan.isReclaimExact,
                hasDecisions: FileManager.default.fileExists(
                    atPath: (try? state.filePath(for: .decisions, id: id)) ?? ""
                ),
                hasRelativePaths: scan.hasRelativePaths
            )
        }
    }
}

public enum StoreError: Error, Equatable, Sendable {
    case notFound(kind: StateDirectory.Slot, id: String)
}
