import Foundation

/// Whether a file the scan listed is still there, and still the file the scan measured.
///
/// **The corpus made this necessary rather than nice.** The oldest scans on this machine are from May, and
/// of one scan's 501 paths, **473 no longer exist**. A review pane that draws a blank for those is asking
/// the user to decide about files that are already gone; worse, a scan whose file has since *changed* is a
/// group that is no longer true, and deciding to remove a "duplicate" of it would remove something that is
/// not a duplicate any more.
///
/// The apply path re-hashes before it moves anything, so a stale scan cannot cause data loss. But
/// discovering it at apply time, after the user has reviewed two thousand groups, is much worse than being
/// told while looking at the file.
public struct FilePresence: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// There, and the size still matches what the scan recorded.
        case present
        /// Gone. The common case on any scan more than a few weeks old.
        case missing
        /// There, but a different length, so the content changed and the group is stale.
        case sizeChanged(onDisk: Int64)
        /// There, but cannot be read -- a permission the app does not have.
        case unreadable
        /// Not a regular file any more: a directory, or replaced by a symlink.
        case notAFile

        public var isActionable: Bool { self == .present }
    }

    public let path: String
    public let state: State
    /// Modification time as reported now, for display. `nil` when the file is gone or unreadable.
    public let modifiedAt: Date?

    public init(path: String, state: State, modifiedAt: Date? = nil) {
        self.path = path
        self.state = state
        self.modifiedAt = modifiedAt
    }

    /// Checks one path against the size the scan recorded.
    ///
    /// - Parameter expectedSize: the group's size. A mismatch is what makes a stale scan detectable
    ///   without re-reading the whole file -- content cannot change without the length changing *or* the
    ///   digest changing, and the second is what the apply path verifies. This catches the cheap half.
    public static func check(
        path: String,
        expectedSize: Int64,
        fileManager: FileManager = .default
    ) -> FilePresence {
        // **`attributesOfItem` does not follow symlinks** -- measured, and worth stating because the
        // opposite is easy to assume. That is the behaviour this needs. A symlink is never a scan member:
        // `WalkFilter` refuses them outright, matching the CLI's `is_symlink()` skip. So a symlink sitting
        // at a recorded path means the file was replaced by one, and calling that `.present` would be
        // actively wrong -- `trashItem` on a symlink moves the link and leaves the bytes where they are,
        // so the app would report space freed that no `df` would confirm.
        guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
            // Distinguish "not there" from "there and refused", because the user can act on the second.
            return FilePresence(
                path: path,
                state: fileManager.fileExists(atPath: path) ? .unreadable : .missing
            )
        }
        let modified = attributes[.modificationDate] as? Date
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            return FilePresence(path: path, state: .notAFile, modifiedAt: modified)
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size == expectedSize else {
            return FilePresence(path: path, state: .sizeChanged(onDisk: size), modifiedAt: modified)
        }
        return FilePresence(path: path, state: .present, modifiedAt: modified)
    }
}

/// What a whole group looks like on disk right now.
public struct GroupPresence: Sendable, Equatable {
    public let files: [FilePresence]

    public init(files: [FilePresence]) {
        self.files = files
    }

    /// Checks every member of a group.
    public static func check(
        group: DuplicateGroup,
        fileManager: FileManager = .default
    ) -> GroupPresence {
        GroupPresence(
            files: group.files.map {
                FilePresence.check(path: $0, expectedSize: group.size, fileManager: fileManager)
            }
        )
    }

    public var presentCount: Int { files.filter { $0.state == .present }.count }
    public var missingCount: Int { files.filter { $0.state == .missing }.count }
    public var changedCount: Int {
        files.filter {
            if case .sizeChanged = $0.state { return true }
            return false
        }.count
    }

    /// Whether the group is still worth acting on.
    ///
    /// **Two files, not one.** A group with a single surviving member is not a duplicate group any more:
    /// there is nothing to remove and nothing to keep, and offering it would invite the user to delete
    /// their only copy.
    public var isStillADuplicate: Bool { presentCount >= 2 }

    /// Whether anything about the group changed since the scan.
    public var isStale: Bool { presentCount != files.count }
}
