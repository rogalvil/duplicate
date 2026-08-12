/// The three detectors, and the state subdirectories each one reads and writes.
///
/// The directory names are part of the format shared with the `rav duplicate` CLI, so they are
/// spelled exactly as the CLI spells them -- hyphenated, not camel-cased.
public enum ScanKind: String, CaseIterable, Sendable {
    /// Byte-identical files, grouped by SHA-256.
    case files
    /// Directories compared by Dice coefficient over their {relative path -> digest} maps.
    case folders
    /// Images and videos compared by perceptual hash.
    case media

    /// Where a scan of this kind is stored.
    public var scanSlot: StateDirectory.Slot {
        switch self {
        case .files: .scans
        case .folders: .folderScans
        case .media: .similarScans
        }
    }

    /// Where the review decisions for a scan of this kind are stored.
    public var decisionSlot: StateDirectory.Slot {
        switch self {
        case .files: .decisions
        case .folders: .folderDecisions
        case .media: .similarDecisions
        }
    }
}
