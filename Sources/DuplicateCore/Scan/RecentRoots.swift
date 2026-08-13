import Foundation

/// A folder that was scanned before.
public struct RecentRoot: Sendable, Hashable {
    public let path: String
    /// When it was last scanned, in the same shape as every other timestamp here.
    public let lastUsed: String

    public init(path: String, lastUsed: String) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

/// Remembers the folders that were scanned, so choosing one again is a click.
///
/// **Deliberately not security-scoped bookmarks**, which is what the plan called for and what an app like
/// this is usually written with. Bookmarks with `.withSecurityScope` exist so a *sandboxed* app can reach a
/// folder the user picked in an open panel after a relaunch, because a sandbox forgets. This app is not
/// sandboxed -- verified: no `com.apple.security.app-sandbox` entitlement in the signature -- because the
/// shared state directory lives outside a container and that requirement decided it.
///
/// What governs access here is TCC, which remembers per *app*, keyed on the designated requirement, not per
/// folder selection. So a bookmark would buy nothing that TCC does not already provide, and writing one
/// would be ceremony that looks like security.
///
/// What was actually missing is far smaller: the panel forgot where you scanned last, so every scan started
/// by navigating the open panel again. That is what this fixes.
///
/// Lives in `Application Support`, not `Caches`: a list of folders the user chose is not derived data that
/// can be rebuilt, and macOS may purge `Caches` whenever it likes.
public struct RecentRootsStore: Sendable {
    /// How many to keep.
    ///
    /// Ten because this is a convenience list, not a history: a menu longer than that is one nobody reads,
    /// and the scan window is not the place to browse the past.
    public static let capacity = 10

    private let url: URL

    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> URL {
        let base =
            environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home + "/Library/Application Support"
        return URL(filePath: base + "/com.rogalvil.duplicate/recent-roots.json")
    }

    public init(url: URL = RecentRootsStore.defaultURL()) {
        self.url = url
    }

    /// Everything remembered, most recent first.
    ///
    /// A file that cannot be read or parsed comes back empty rather than throwing: this is a convenience
    /// list, and failing to open a scan window because a preferences file is corrupt would be absurd.
    public func load() -> [RecentRoot] {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
            let value = try? JSONReader.parse(data),
            let items = value["roots"]?.arrayValue
        else { return [] }
        return items.compactMap { item in
            guard let path = item["path"]?.stringValue,
                let used = item["last_used"]?.stringValue
            else { return nil }
            return RecentRoot(path: path, lastUsed: used)
        }
    }

    public func save(_ roots: [RecentRoot]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let document = JSONValue.object([
            JSONMember(key: "format_version", value: .int(1)),
            JSONMember(
                key: "roots",
                value: .array(
                    roots.map { root in
                        .object([
                            JSONMember(key: "path", value: .string(root.path)),
                            JSONMember(key: "last_used", value: .string(root.lastUsed)),
                        ])
                    }
                )
            ),
        ])
        try JSONWriter.document(document).write(to: url, options: .atomic)
    }

    /// Records a scan of `path` and returns the new list.
    ///
    /// Compared by **bytes**, like every other path comparison here: `String ==` would fold two spellings of
    /// the same accented folder name into one entry and lose whichever the user did not pick.
    @discardableResult
    public func remember(_ path: String, at timestamp: String) -> [RecentRoot] {
        var roots = load().filter { !PathOrder.equal($0.path, path) }
        roots.insert(RecentRoot(path: path, lastUsed: timestamp), at: 0)
        if roots.count > Self.capacity { roots.removeLast(roots.count - Self.capacity) }
        try? save(roots)
        return roots
    }

    /// Forgets one entry, for a folder that no longer exists.
    @discardableResult
    public func forget(_ path: String) -> [RecentRoot] {
        let roots = load().filter { !PathOrder.equal($0.path, path) }
        try? save(roots)
        return roots
    }

    /// The remembered roots that are still directories on disk right now.
    ///
    /// An unmounted external drive is the common case, and it is not an error: the entry stays in the file
    /// so it comes back when the drive does. Offering it as scannable is what would be wrong.
    public func available(fileManager: FileManager = .default) -> [RecentRoot] {
        load().filter { root in
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }
}
