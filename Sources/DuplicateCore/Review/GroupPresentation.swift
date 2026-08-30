import Foundation

/// Shortens a path for a column too narrow to hold it.
///
/// In Core rather than the window because it is a value transform with edge cases worth testing, and
/// because it produces no prose: `…` is the same character in English and Spanish.
public enum PathElision {
    /// The horizontal ellipsis, as its own component.
    public static let ellipsis = "\u{2026}"

    /// Keeps the first `leading` and last `trailing` components, eliding the middle.
    ///
    /// Elides the **middle**, not the end. The tail of a path is what identifies it -- twenty files under
    /// `/Volumes/Externo/Fotos/2019/` truncated at the end are twenty identical cells -- and the head says
    /// which volume it is on, which is the other thing a person needs. What nobody needs is the four
    /// directory levels in between.
    ///
    /// Splits on `/` over the raw bytes, so a path is never normalised on its way to being displayed.
    public static func elide(_ path: String, leading: Int = 2, trailing: Int = 2) -> String {
        guard leading >= 0, trailing >= 1 else { return path }
        let isAbsolute = path.hasPrefix("/")
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > leading + trailing else { return path }

        let head = parts.prefix(leading)
        let tail = parts.suffix(trailing)
        parts = Array(head) + [ellipsis] + Array(tail)
        return (isAbsolute ? "/" : "") + parts.joined(separator: "/")
    }

    /// The deepest directory every path is inside, or `nil` when they share none.
    ///
    /// **Compared component by component, not byte by byte.** `/a/bc/x` and `/a/bd/y` share the byte prefix
    /// `/a/b`, which is not a directory either file is in -- hoisting it into a header would put a path on
    /// screen that does not exist. The answer here is `/a`.
    ///
    /// Returns `nil` for a single path, for an empty list, and when the only shared ancestor is `/` -- a
    /// header reading `/` tells the reader nothing and costs a line.
    public static func commonParent(of paths: [String]) -> String? {
        guard paths.count > 1 else { return nil }
        let allAbsolute = paths.allSatisfy { $0.hasPrefix("/") }
        let allRelative = paths.allSatisfy { !$0.hasPrefix("/") }
        // A mix of absolute and relative paths has no common ancestor that can be named.
        guard allAbsolute || allRelative else { return nil }

        var shared: [String]?
        for path in paths {
            // The last component is the file name, never part of the parent.
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .dropLast()
            guard let current = shared else {
                shared = Array(components)
                continue
            }
            var prefix: [String] = []
            for (mine, theirs) in zip(current, components) {
                // Byte comparison, because two spellings of the same accented directory name are two
                // different directories to the filesystem this scan came from.
                guard PathOrder.equal(mine, theirs) else { break }
                prefix.append(mine)
            }
            shared = prefix
            if prefix.isEmpty { break }
        }
        guard let shared, !shared.isEmpty else { return nil }
        return (allAbsolute ? "/" : "") + shared.joined(separator: "/")
    }

    /// `path` with `parent` removed from its front, or `path` unchanged when it is not inside `parent`.
    public static func relative(_ path: String, to parent: String) -> String {
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        let pathBytes = Array(path.utf8)
        let prefixBytes = Array(prefix.utf8)
        guard pathBytes.count > prefixBytes.count,
            PathOrder.equal(
                String(decoding: pathBytes[..<prefixBytes.count], as: UTF8.self), prefix)
        else { return path }
        return String(decoding: pathBytes[prefixBytes.count...], as: UTF8.self)
    }
}

/// Everything a window needs to draw one group, and nothing a window has to work out for itself.
///
/// In Core so the rules are covered by tests rather than by looking at the screen. Produces numbers,
/// flags and paths -- never a sentence. The window turns `sharesStorageWithKeeper` into "same file as the
/// one you are keeping" in whichever language is running.
public struct GroupPresentation: Sendable, Equatable {

    /// One member of the group.
    public struct Row: Sendable, Equatable {
        public let path: String
        /// `path` with the group's common parent removed, so the column shows what actually differs.
        public let displayPath: String
        /// Whether the current decision, or the heuristic's preview when there is none, keeps this file.
        public let isKept: Bool
        /// Whether this file shares storage with a kept file, so removing it would free nothing.
        ///
        /// **The number a duplicate finder gets caught lying about.** A hardlink or an APFS clone of the
        /// keeper is the same bytes under another name: trashing it recovers zero, and a user who checks
        /// with `df` stops believing anything else the app says.
        public let sharesStorageWithKeeper: Bool
        /// Whether this file would be removed if the decision were applied now.
        public let isRemovable: Bool
        /// Whether the name looks like a copy, by the same rule the keeper heuristic uses.
        public let looksLikeCopy: Bool
        /// Which storage cluster this file belongs to, or `nil` when the scan did not record any.
        public let storageCluster: Int?
    }

    public let key: String
    public let size: Int64
    /// The directory hoisted out of every row, when they share one.
    public let commonParent: String?
    public let rows: [Row]
    /// How many independent copies exist, which is not the file count when storage is shared.
    public let distinctCopies: Int
    /// Bytes the current decision would free.
    public let reclaimableBytes: Int64
    /// Whether ``reclaimableBytes`` is exact or an upper bound the window must label.
    public let isReclaimExact: Bool
    public let decision: GroupDecision

    /// Builds the presentation of one group under one decision.
    ///
    /// - Parameters:
    ///   - keep: indices the review says to keep. Pass ``ExactReviewState/effectiveKeep(at:)`` so an
    ///     unvisited group previews the heuristic's guess without that guess counting as a decision.
    ///   - root: the scan root, needed only by the copy-name and depth flags.
    public init(
        group: DuplicateGroup,
        keep: Set<Int>,
        decision: GroupDecision,
        root: String
    ) {
        self.key = group.key
        self.size = group.size
        self.decision = decision
        self.distinctCopies = group.storage?.distinctCopies ?? group.files.count
        self.isReclaimExact = group.isReclaimExact

        let parent = PathElision.commonParent(of: group.files)
        self.commonParent = parent

        // The kept file that decides which other files share its storage. The lowest kept index, matching
        // `removalPlan` -- the two must agree or the window would show one plan and the apply run another.
        let keeperIndex = keep.sorted().first
        let keeperPath = keeperIndex.flatMap {
            group.files.indices.contains($0) ? group.files[$0] : nil
        }
        let siblings = keeperPath.map { Set(group.storageSiblings(of: $0)) } ?? []
        let keptOrdered = keep.sorted().compactMap {
            group.files.indices.contains($0) ? group.files[$0] : nil
        }
        // The same call the plan and the byte count make, so the checkboxes, the sentence above them and
        // the sheet that moves files cannot describe three different sets.
        let removable = Set(group.removalCandidates(keepingAll: keptOrdered))
        let keptPaths = Set(keptOrdered)

        var clusterOf: [String: Int] = [:]
        for (index, cluster) in (group.storage?.clusters ?? []).enumerated() {
            for path in cluster { clusterOf[path] = index }
        }

        self.rows = group.files.enumerated().map { index, path in
            let kept = keep.contains(index)
            return Row(
                path: path,
                displayPath: parent.map { PathElision.relative(path, to: $0) } ?? path,
                isKept: kept,
                sharesStorageWithKeeper: !kept && siblings.contains(path),
                isRemovable: !kept && removable.contains(path),
                looksLikeCopy: CopyNamePattern.score(path: path) == 1,
                storageCluster: clusterOf[path]
            )
        }

        switch decision {
        case .discardAll:
            self.reclaimableBytes = group.size * Int64(self.distinctCopies)
        case .decided:
            // **Not `distinctCopies - 1`.** That is "keep one, drop the rest", which is the group's own
            // question and not this decision's. Keeping two files of two removes nothing, and the header
            // used to announce a full copy's worth of savings anyway.
            self.reclaimableBytes = group.reclaimableBytes(keepingAll: keptOrdered)
        case .undecided, .skipped:
            self.reclaimableBytes = 0
        }
    }

    /// How many files the current decision would remove.
    public var removableCount: Int { rows.filter(\.isRemovable).count }
    /// How many files the current decision keeps.
    public var keptCount: Int { rows.filter(\.isKept).count }
    /// Whether any row is the keeper's own storage under another name.
    public var hasSharedStorage: Bool { rows.contains { $0.sharesStorageWithKeeper } }
}
