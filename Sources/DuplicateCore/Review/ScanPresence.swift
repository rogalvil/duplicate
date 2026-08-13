import Foundation

/// Checks a whole scan against the filesystem.
///
/// **The most useful filter for an old scan, and the most expensive.** A `stat` per file: 2,259 for one of
/// this user's scans, 9,949 for another. That is why it is a thing the user asks for rather than something
/// the window does on its own -- and why it is cancellable and reports progress instead of blocking.
///
/// Why it is worth the wait: measured on this machine, a sample of twelve scans from May found **73 of
/// 10,934 paths still on disk, 0.67%**. Without this, a review of one of those scans is 880 rows about
/// files that are already gone.
public enum ScanPresence {

    /// What a whole-scan check found.
    public struct Result: Sendable {
        /// By group index.
        public let groups: [Int: GroupPresence]

        public init(groups: [Int: GroupPresence]) {
            self.groups = groups
        }

        /// Whether each group still has at least two files on disk, by index.
        ///
        /// The shape ``GroupFilter`` wants.
        public var stillDuplicate: [Int: Bool] {
            groups.mapValues(\.isStillADuplicate)
        }

        public var checkedCount: Int { groups.count }
        public var stillDuplicateCount: Int { groups.values.filter(\.isStillADuplicate).count }
        public var goneCount: Int { groups.values.filter { $0.presentCount == 0 }.count }
        /// Groups that lost some files but not all.
        public var partialCount: Int {
            groups.values.filter { $0.presentCount > 0 && $0.isStale }.count
        }
    }

    /// Checks every group.
    ///
    /// - Parameter onProgress: called with how many groups are done and how many there are, at most once
    ///   per group. On the calling task.
    /// - Throws: `CancellationError` when the task is cancelled. Checked once per group, which bounds the
    ///   wait to one group's worth of `stat` calls -- a handful.
    public static func check(
        scan: DuplicateScan,
        fileManager: FileManager = .default,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> Result {
        var groups: [Int: GroupPresence] = [:]
        groups.reserveCapacity(scan.groups.count)
        for (index, group) in scan.groups.enumerated() {
            try Task.checkCancellation()
            groups[index] = GroupPresence.check(group: group, fileManager: fileManager)
            onProgress?(index + 1, scan.groups.count)
        }
        return Result(groups: groups)
    }
}
