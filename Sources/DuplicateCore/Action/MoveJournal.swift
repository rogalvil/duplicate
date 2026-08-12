import Foundation

/// One line in a session's journal: a file that was removed, and everything needed to put it back.
public struct JournalEntry: Hashable, Sendable {
    /// Bumped if the meaning of a field ever changes, so an old journal is recognised rather than misread.
    public var formatVersion: Int = 1
    public let originalPath: String
    /// Where it went. For the Trash this is what macOS reported, which is not always the basename.
    public let resultingPath: String
    public let mechanism: DisposalMechanism
    public let byteCount: Int64
    /// The digest the scan recorded, so an undo can prove it is putting back the same bytes.
    public let digest: Digest32
    /// `"<size>:<sha256>"`, so an entry can be traced to the group it came from.
    public let groupKey: String
    public let scanID: String
    /// ISO-8601 with a `Z` suffix, in the same shape the shared scan format uses.
    public let timestamp: String

    public init(
        formatVersion: Int = 1,
        originalPath: String,
        resultingPath: String,
        mechanism: DisposalMechanism,
        byteCount: Int64,
        digest: Digest32,
        groupKey: String,
        scanID: String,
        timestamp: String
    ) {
        self.formatVersion = formatVersion
        self.originalPath = originalPath
        self.resultingPath = resultingPath
        self.mechanism = mechanism
        self.byteCount = byteCount
        self.digest = digest
        self.groupKey = groupKey
        self.scanID = scanID
        self.timestamp = timestamp
    }
}

/// An append-only record of what one apply session moved.
///
/// **JSON Lines, not a JSON array, and the extension says so.** A pretty-printed `[…]` cannot be appended
/// to without rewriting it, and a crash mid-write has to leave every prior entry readable. `.jsonl` is
/// also the honest signal that this is not the CLI's format: the CLI performs a different action --
/// `shutil.move` into a quarantine -- and has no concept of a journal at all.
///
/// **App-only, but under the shared state root.** The CLI reads only its six known subdirectories, so a
/// sibling `journal/` is invisible to it and cannot confuse it. It still lives beside the scans rather
/// than in Application Support, because the paths it references are the same paths the scans reference:
/// splitting them across two roots means a user who moves `XDG_STATE_HOME` gets an undo log pointing at
/// scans that are no longer there.
public enum MoveJournal {
    /// Where a session's journal lives.
    public static func url(sessionID: String, in state: StateDirectory) throws -> URL {
        URL(
            filePath: try state.filePath(for: .journal, id: sessionID, extension: "jsonl"),
            directoryHint: .notDirectory
        )
    }

    // MARK: - Encoding

    /// One entry as a single line, with no trailing newline.
    ///
    /// Uses the same writer as the shared scan format, so the escaping rules are identical -- a path with
    /// a combining accent is written the same way in both files, which matters because the two are read
    /// side by side when an undo is planned.
    public static func encode(_ entry: JournalEntry) throws -> String {
        try JSONWriter.encode(
            .object([
                JSONMember(key: "format_version", value: .int(Int64(entry.formatVersion))),
                JSONMember(key: "original_path", value: .string(entry.originalPath)),
                JSONMember(key: "resulting_path", value: .string(entry.resultingPath)),
                JSONMember(key: "mechanism", value: .string(entry.mechanism.rawValue)),
                JSONMember(key: "size", value: .int(entry.byteCount)),
                JSONMember(key: "sha256", value: .string(entry.digest.hexString)),
                JSONMember(key: "group_key", value: .string(entry.groupKey)),
                JSONMember(key: "scan_id", value: .string(entry.scanID)),
                JSONMember(key: "timestamp", value: .string(entry.timestamp)),
            ]),
            indent: nil
        )
    }

    /// Appends entries to a session's journal, creating it if needed.
    ///
    /// Appended one line at a time with `O_APPEND`, so a crash between entries truncates at a line
    /// boundary at worst -- and a torn final line is simply skipped when reading.
    @discardableResult
    public static func append(
        _ entries: [JournalEntry],
        sessionID: String,
        in state: StateDirectory
    ) throws -> Int {
        guard !entries.isEmpty else { return 0 }
        try state.create(.journal)
        let path = try state.filePath(for: .journal, id: sessionID, extension: "jsonl")

        var payload = ""
        for entry in entries {
            payload += try encode(entry) + "\n"
        }

        let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard descriptor >= 0 else {
            throw JournalError.cannotWrite(path: path, code: errno)
        }
        defer { close(descriptor) }

        let bytes = Array(payload.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress! + offset, bytes.count - offset)
            }
            if written <= 0 {
                if errno == EINTR { continue }
                throw JournalError.cannotWrite(path: path, code: errno)
            }
            offset += written
        }
        return entries.count
    }

    // MARK: - Decoding

    /// What reading a journal found.
    public struct LoadResult: Sendable, Equatable {
        public var entries: [JournalEntry] = []
        /// Lines that could not be parsed, by line number. A torn final line lands here.
        public var malformedLines: [Int] = []
        /// Original paths that a later `undone_at` record says were already put back.
        public var restoredPaths: Set<String> = []

        public var isClean: Bool { malformedLines.isEmpty }
    }

    /// Reads a session's journal.
    ///
    /// A malformed line is recorded and skipped, never fatal: the whole point of appending line by line is
    /// that a crash costs the last line and nothing else.
    public static func load(sessionID: String, in state: StateDirectory) throws -> LoadResult {
        let path = try state.filePath(for: .journal, id: sessionID, extension: "jsonl")
        guard let data = FileManager.default.contents(atPath: path) else {
            return LoadResult()
        }
        return parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ text: String) -> LoadResult {
        var result = LoadResult()
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let value = try? JSONReader.parse(trimmed) else {
                result.malformedLines.append(index + 1)
                continue
            }
            // An `undone_at` record marks an earlier entry as restored. Appended rather than rewriting the
            // original line, so the journal stays a truthful log of what happened in order instead of a
            // mutable summary of the current state.
            if let restored = value["undone_at"]?.stringValue, !restored.isEmpty,
                let original = value["original_path"]?.stringValue
            {
                result.restoredPaths.insert(original)
                continue
            }
            guard let entry = decode(value) else {
                result.malformedLines.append(index + 1)
                continue
            }
            result.entries.append(entry)
        }
        return result
    }

    static func decode(_ value: JSONValue) -> JournalEntry? {
        guard
            let original = value["original_path"]?.stringValue,
            let resulting = value["resulting_path"]?.stringValue,
            let mechanism = value["mechanism"]?.stringValue.flatMap(
                DisposalMechanism.init(rawValue:)),
            let size = value["size"]?.intValue,
            let hex = value["sha256"]?.stringValue,
            let digest = Digest32(hexString: hex),
            let groupKey = value["group_key"]?.stringValue,
            let scanID = value["scan_id"]?.stringValue,
            let timestamp = value["timestamp"]?.stringValue
        else { return nil }
        let version = value["format_version"]?.intValue ?? 1
        // A journal from a future layout is refused rather than half-read: its fields may be intact and
        // still mean something else.
        guard version == 1 else { return nil }
        return JournalEntry(
            formatVersion: Int(version),
            originalPath: original,
            resultingPath: resulting,
            mechanism: mechanism,
            byteCount: size,
            digest: digest,
            groupKey: groupKey,
            scanID: scanID,
            timestamp: timestamp
        )
    }

    /// Records that an entry was put back, by appending rather than editing.
    @discardableResult
    public static func appendRestoration(
        of entry: JournalEntry,
        at timestamp: String,
        sessionID: String,
        in state: StateDirectory
    ) throws -> Int {
        let line = try JSONWriter.encode(
            .object([
                JSONMember(key: "format_version", value: .int(1)),
                JSONMember(key: "original_path", value: .string(entry.originalPath)),
                JSONMember(key: "undone_at", value: .string(timestamp)),
            ]),
            indent: nil
        )
        try state.create(.journal)
        let path = try state.filePath(for: .journal, id: sessionID, extension: "jsonl")
        let descriptor = path.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
        guard descriptor >= 0 else { throw JournalError.cannotWrite(path: path, code: errno) }
        defer { close(descriptor) }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress!, bytes.count) }
        return 1
    }

    /// Every session that has a journal, newest first.
    public static func sessions(in state: StateDirectory) -> [String] {
        let directory = state.path(for: .journal)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        return
            names
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(6)) }
            .filter(ScanIdentifier.isValid)
            .sorted(by: >)
    }
}

public enum JournalError: Error, Equatable, Sendable {
    case cannotWrite(path: String, code: Int32)
}
