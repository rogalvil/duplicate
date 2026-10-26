import Foundation
import Synchronization

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
        public let hasDecisions: Bool
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
                hasRelativePaths: scan.hasRelativePaths,
                hasDecisions: hasFolderDecisions(scanID: scan.scanID)
            )
        }
    }

    // MARK: - Similar scans

    @discardableResult
    public func save(_ scan: SimilarScan) throws -> String {
        try state.create(.similarScans)
        let path = try state.filePath(for: .similarScans, id: scan.scanID)
        let data = try JSONWriter.document(SimilarScanCodec.encode(scan))
        try data.write(to: URL(filePath: path), options: .atomic)
        return path
    }

    public func loadSimilarScan(id: String) throws -> SimilarScan {
        let path = try state.filePath(for: .similarScans, id: id)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StoreError.notFound(kind: .similarScans, id: id)
        }
        return try SimilarScanCodec.decode(JSONReader.parse(data))
    }

    /// A summary of one perceptual scan for a list.
    public struct SimilarSummary: Sendable, Hashable {
        public let scanID: String
        public let root: String
        public let createdAt: String
        public let imageThreshold: Int
        public let videoThreshold: Double
        public let pairCount: Int
        public let imagePairCount: Int
        public let videoPairCount: Int
        public let involvedFileCount: Int
        public let hasRelativePaths: Bool
        /// Whether a review of this scan is already on disk, so a list can badge it.
        public let hasDecisions: Bool
    }

    /// Summaries for every readable perceptual scan.
    ///
    /// The image and video counts are separate because the two are judged against different thresholds and this
    /// app can only produce one of them so far. A single total would hide which.
    public func similarSummaries() -> [SimilarSummary] {
        identifiers(in: .similarScans).compactMap { id in
            guard let scan = try? loadSimilarScan(id: id) else { return nil }
            return SimilarSummary(
                scanID: scan.scanID,
                root: scan.root,
                createdAt: scan.createdAt,
                imageThreshold: scan.imageThreshold,
                videoThreshold: scan.videoThreshold,
                pairCount: scan.pairCount,
                imagePairCount: scan.pairCount(of: .image),
                videoPairCount: scan.pairCount(of: .video),
                involvedFileCount: scan.involvedFileCount,
                hasRelativePaths: scan.hasRelativePaths,
                hasDecisions: hasSimilarDecisions(scanID: scan.scanID)
            )
        }
    }

    // MARK: - Folder decisions

    @discardableResult
    public func save(_ decisions: FolderDecisionsDocument) throws -> String {
        try state.create(.folderDecisions)
        let path = try state.filePath(for: .folderDecisions, id: decisions.scanID)
        let data = try JSONWriter.document(FolderDecisionsCodec.encode(decisions))
        try data.write(to: URL(filePath: path), options: .atomic)
        return path
    }

    public func loadFolderDecisions(scanID: String) throws -> FolderDecisionsDocument {
        let path = try state.filePath(for: .folderDecisions, id: scanID)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StoreError.notFound(kind: .folderDecisions, id: scanID)
        }
        return try FolderDecisionsCodec.decode(JSONReader.parse(data))
    }

    /// Decisions already on disk for a folder scan, or an empty map.
    ///
    /// **`folder-decisions/` does not exist on this machine** -- the CLI has the slot and has never written one --
    /// so the ordinary case here is genuinely "no file", not "a file this build has not seen".
    public func priorFolderDecisions(scanID: String) -> [String: [String]] {
        (try? loadFolderDecisions(scanID: scanID))?.byKey ?? [:]
    }

    public func hasFolderDecisions(scanID: String) -> Bool {
        guard let path = try? state.filePath(for: .folderDecisions, id: scanID) else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
    }

    // MARK: - Similar decisions

    /// Saves a perceptual review's decisions under the scan's own identifier.
    @discardableResult
    public func save(_ decisions: SimilarDecisionsDocument, scanID: String) throws -> String {
        try state.create(.similarDecisions)
        let path = try state.filePath(for: .similarDecisions, id: scanID)
        let data = try JSONWriter.document(SimilarDecisionsCodec.encode(decisions))
        try data.write(to: URL(filePath: path), options: .atomic)
        return path
    }

    public func loadSimilarDecisions(scanID: String) throws -> SimilarDecisionsDocument {
        let path = try state.filePath(for: .similarDecisions, id: scanID)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw StoreError.notFound(kind: .similarDecisions, id: scanID)
        }
        return try SimilarDecisionsCodec.decode(JSONReader.parse(data))
    }

    /// Decisions already on disk for a perceptual scan, or an empty map.
    ///
    /// Empty rather than throwing: a scan with no review yet is the ordinary case, and the caller wants to know
    /// what was decided, not whether a file exists.
    public func priorSimilarDecisions(scanID: String) -> [String: SimilarDecision] {
        (try? loadSimilarDecisions(scanID: scanID))?.byKey ?? [:]
    }

    /// Saves the names a perceptual review chose (#228), or removes the document when none is left.
    ///
    /// Removed rather than written empty: a scan reviewed without renaming anything should not grow a file that says so.
    public func save(_ renames: SimilarRenamesDocument, scanID: String) throws {
        let path = try state.filePath(for: .similarRenames, id: scanID)
        guard !renames.renames.isEmpty else {
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
            return
        }
        try state.create(.similarRenames)
        let data = try JSONWriter.document(SimilarRenamesCodec.encode(renames))
        try data.write(to: URL(filePath: path), options: .atomic)
    }

    /// The names chosen for a perceptual scan, or none.
    ///
    /// Empty rather than throwing, like ``priorSimilarDecisions(scanID:)``: no document is the ordinary case, and one
    /// this build cannot read costs a choice of name, never a file.
    public func priorSimilarRenames(scanID: String) -> [SimilarRename] {
        guard let path = try? state.filePath(for: .similarRenames, id: scanID),
            let data = FileManager.default.contents(atPath: path),
            let document = try? SimilarRenamesCodec.decode(JSONReader.parse(data))
        else { return [] }
        return document.renames
    }

    /// Whether a perceptual scan has a decisions document beside it.
    public func hasSimilarDecisions(scanID: String) -> Bool {
        guard let path = try? state.filePath(for: .similarDecisions, id: scanID) else {
            return false
        }
        return FileManager.default.fileExists(atPath: path)
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
        try delete(id: id, scan: .scans, decisions: .decisions)
    }

    /// Removes the decisions saved for a scan, and nothing else.
    ///
    /// For a review that took back every decision it had. The file is what tells the CLI, and the library's
    /// "reviewed" badge, that the scan was reviewed, so writing an empty one would say something false.
    @discardableResult
    public func deleteDecisions(scanID: String) throws -> Bool {
        let path = try state.filePath(for: .decisions, id: scanID)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        try FileManager.default.removeItem(atPath: path)
        return true
    }

    /// Removes a folder scan and the decisions saved beside it, for the reason ``delete(id:)`` removes both.
    @discardableResult
    public func deleteFolderScan(id: String) throws -> Bool {
        try delete(id: id, scan: .folderScans, decisions: .folderDecisions)
    }

    /// Removes a perceptual scan and the decisions saved beside it, for the reason ``delete(id:)`` removes both.
    @discardableResult
    public func deleteSimilarScan(id: String) throws -> Bool {
        try delete(
            id: id, scan: .similarScans, decisions: .similarDecisions, also: [.similarRenames])
    }

    private func delete(
        id: String, scan: StateDirectory.Slot, decisions: StateDirectory.Slot,
        also others: [StateDirectory.Slot] = []
    ) throws -> Bool {
        var removed = false
        for slot in [scan, decisions] + others {
            let path = try state.filePath(for: slot, id: id)
            guard FileManager.default.fileExists(atPath: path) else { continue }
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
    ///
    /// - Parameter cache: summaries already read. A document whose size, modification time and inode all match
    ///   is not decoded again; see ``SummaryCache``.
    public func summaries(cache: SummaryCache? = nil) -> [Summary] {
        let ids = identifiers(in: .scans)
        let result: [Summary] = ids.compactMap { id in
            // Read every time, cached or not: a decisions file comes and goes without touching the scan.
            let hasDecisions = FileManager.default.fileExists(
                atPath: (try? state.filePath(for: .decisions, id: id)) ?? "")
            // **Stamped before reading, not after.** A document rewritten in between is stored under the old
            // stamp, which the next reload no longer matches -- one extra decode, never a stale row.
            let stamp = cache.flatMap { _ in
                (try? state.filePath(for: .scans, id: id)).flatMap(SummaryCache.Stamp.init(path:))
            }
            if let stamp, let known = cache?.summary(for: id, stamp: stamp) {
                return known.with(hasDecisions: hasDecisions)
            }
            guard let scan = try? loadScan(id: id) else { return nil }
            let summary = Summary(
                scanID: scan.scanID,
                root: scan.root,
                createdAt: scan.createdAt,
                groupCount: scan.groups.count,
                fileCount: scan.fileCount,
                reclaimableBytes: scan.reclaimableBytes,
                isReclaimExact: scan.isReclaimExact,
                hasDecisions: hasDecisions,
                hasRelativePaths: scan.hasRelativePaths
            )
            if let stamp { cache?.store(summary, for: id, stamp: stamp) }
            return summary
        }
        cache?.keep(only: Set(ids))
        return result
    }
}

extension ScanStore.Summary {
    fileprivate func with(hasDecisions: Bool) -> ScanStore.Summary {
        ScanStore.Summary(
            scanID: scanID, root: root, createdAt: createdAt, groupCount: groupCount,
            fileCount: fileCount, reclaimableBytes: reclaimableBytes,
            isReclaimExact: isReclaimExact,
            hasDecisions: hasDecisions, hasRelativePaths: hasRelativePaths)
    }
}

/// Summaries already read, by scan, so a reload decodes only the documents that changed (#162).
///
/// The library re-reads the directory every time its watcher fires, and a summary used to cost a full decode of
/// every group of every scan: 3.2 s on this user's 134 scans, 194 MB of them in one document, for a handful of
/// counts that had not changed. A document is matched by size, modification time and inode -- an atomic rewrite
/// changes the inode, one in place the time -- so an unchanged scan costs a `stat`.
///
/// **Memory only, on purpose.** An index on disk would be state the CLI does not know about, and the CLI
/// rewriting a scan would leave it stale for whoever reads it next.
public final class SummaryCache: Sendable {
    struct Stamp: Hashable, Sendable {
        let size: Int64
        let modified: Date
        let inode: UInt64

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = (attributes[.size] as? NSNumber)?.int64Value,
                let modified = attributes[.modificationDate] as? Date,
                let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            else { return nil }
            self.size = size
            self.modified = modified
            self.inode = inode
        }
    }

    private let entries = Mutex<[String: (stamp: Stamp, summary: ScanStore.Summary)]>([:])

    public init() {}

    /// How many scans are held, for the tests.
    var count: Int { entries.withLock { $0.count } }

    func summary(for id: String, stamp: Stamp) -> ScanStore.Summary? {
        entries.withLock { held in
            guard let entry = held[id], entry.stamp == stamp else { return nil }
            return entry.summary
        }
    }

    func store(_ summary: ScanStore.Summary, for id: String, stamp: Stamp) {
        entries.withLock { $0[id] = (stamp, summary) }
    }

    /// Forgets scans that are no longer on disk.
    func keep(only ids: Set<String>) {
        entries.withLock { held in held = held.filter { ids.contains($0.key) } }
    }
}

public enum StoreError: Error, Equatable, Sendable {
    case notFound(kind: StateDirectory.Slot, id: String)
}
