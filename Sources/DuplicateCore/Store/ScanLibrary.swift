import Foundation

/// How the library list is ordered.
public enum LibrarySort: String, Sendable, CaseIterable {
    case newest
    case oldest
    case mostGroups
    case mostReclaimable
}

/// The list of scans, sorted and filtered, with no window attached.
///
/// A thin type on purpose: `ScanStore` already reads the documents, so what is left is the ordering and
/// the search, and both are worth owning here rather than in a table view's data source. The sorting rule
/// in particular is not obvious -- see ``rows(sortedBy:filter:)``.
public struct ScanLibrary: Sendable {
    private let store: ScanStore
    /// Every readable scan, as of the last refresh.
    public private(set) var summaries: [ScanStore.Summary]

    public init(store: ScanStore) {
        self.store = store
        self.summaries = store.summaries()
    }

    /// Re-reads the directory.
    ///
    /// - Returns: `true` when the set of scans changed, so a caller can skip reloading a table for a
    ///   change that does not concern it -- a decisions file being re-saved fires the watcher but leaves
    ///   every row identical.
    @discardableResult
    public mutating func refresh() -> Bool {
        let fresh = store.summaries()
        guard fresh != summaries else { return false }
        summaries = fresh
        return true
    }

    /// The rows to show.
    ///
    /// **Every ordering breaks ties on the scan id, and that is not decoration.** `Array.sort` is not
    /// stable, so a comparator that reports two rows as equal is free to return them in either order --
    /// and a list that reorders its own rows every time a watcher fires is a list nobody can click on.
    /// Two scans with the same group count are common; two with the same identifier are impossible.
    ///
    /// - Parameter filter: matched against the root path, case- and diacritic-insensitively. **This is the
    ///   one place a path is compared as text rather than as bytes**, and it is safe because the result is
    ///   only ever shown, never used as identity: somebody typing `suarez` should find `Suárez`, while
    ///   `PathOrder` still decides what counts as the same file.
    public func rows(
        sortedBy sort: LibrarySort = .newest, filter: String = ""
    ) -> [ScanStore.Summary] {
        var rows = summaries
        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            rows = rows.filter {
                $0.root.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.scanID.contains(needle)
            }
        }
        switch sort {
        case .newest:
            rows.sort { $0.scanID > $1.scanID }
        case .oldest:
            rows.sort { $0.scanID < $1.scanID }
        case .mostGroups:
            rows.sort {
                $0.groupCount == $1.groupCount
                    ? $0.scanID > $1.scanID : $0.groupCount > $1.groupCount
            }
        case .mostReclaimable:
            rows.sort {
                $0.reclaimableBytes == $1.reclaimableBytes
                    ? $0.scanID > $1.scanID : $0.reclaimableBytes > $1.reclaimableBytes
            }
        }
        return rows
    }

    /// The numbers for a footer.
    public struct Totals: Sendable, Hashable {
        public let scanCount: Int
        public let groupCount: Int
        public let fileCount: Int
        public let reclaimableBytes: Int64
        /// `false` when any scan's figure is an upper bound, so the UI can label it instead of rounding it
        /// off to a confident number.
        public let isReclaimExact: Bool
    }

    public var totals: Totals {
        Totals(
            scanCount: summaries.count,
            groupCount: summaries.reduce(0) { $0 + $1.groupCount },
            fileCount: summaries.reduce(0) { $0 + $1.fileCount },
            reclaimableBytes: summaries.reduce(0) { $0 + $1.reclaimableBytes },
            isReclaimExact: summaries.allSatisfy(\.isReclaimExact)
        )
    }
}
