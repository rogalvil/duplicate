import Foundation

/// What kind of storage a scan is reading from.
///
/// Read **once per volume**, never per file. Volume properties resolve through `statfs` and disk
/// arbitration rather than the directory attribute batch, so prefetching them alongside the per-entry
/// keys is a classic self-inflicted slowdown.
public struct VolumeTraits: Sendable, Hashable {
    public let isLocal: Bool
    public let isInternal: Bool
    public let isRemovable: Bool
    public let supportsCloning: Bool

    public init(
        isLocal: Bool = true,
        isInternal: Bool = true,
        isRemovable: Bool = false,
        supportsCloning: Bool = true
    ) {
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.supportsCloning = supportsCloning
    }

    /// Reads the traits of the volume holding `path`. `nil` when they cannot be read.
    public static func forItem(at path: String) -> VolumeTraits? {
        guard
            let values = try? URL(filePath: path).resourceValues(forKeys: [
                .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey,
                .volumeSupportsFileCloningKey,
            ])
        else { return nil }
        return VolumeTraits(
            isLocal: values.volumeIsLocal ?? true,
            isInternal: values.volumeIsInternal ?? true,
            isRemovable: values.volumeIsRemovable ?? false,
            supportsCloning: values.volumeSupportsFileCloning ?? false
        )
    }
}

/// How many files to hash at once.
///
/// A pure function, so the whole policy is unit-testable with fabricated traits and no external drive.
/// The constants themselves are a **prediction, not a measurement** -- see the note below.
public enum IOConcurrencyPolicy {
    /// Never fewer than this, so a single stalled read cannot idle the scan.
    public static let minimum = 2
    /// Never more than this. Past it the workers contend for one device queue and burn efficiency cores
    /// on memory bandwidth.
    public static let maximum = 8

    /// The recommended width for a volume.
    ///
    /// **Internal NVMe: `min(max(cores - 2, 2), 8)`.** The reasoning is arithmetic rather than
    /// intuition. Hardware SHA-256 runs at roughly 1.5-2.5 GB/s per performance core, while an
    /// M-series internal SSD reads at 4-7 GB/s sequential -- so single-threaded hashing is *CPU*-bound
    /// by a factor of two to four, and three or four concurrent hashers are needed just to saturate the
    /// device. Two cores are left free so the window stays responsive, which is the premise of a
    /// windowed app.
    ///
    /// **External or removable: 2.** Concurrent readers on a spinning disk turn sequential reads into a
    /// seek storm and throughput collapses by an order of magnitude. `isRemovable` and `isInternal` are
    /// a *proxy* for rotational, not a test, so an external NVMe enclosure is penalised unfairly. That
    /// trade is accepted deliberately: being twice as slow on an external SSD is a smaller loss than
    /// being ten times slower on an external hard disk, and this is the case that matters here -- the
    /// real corpus this app was built for lives on an external volume.
    ///
    /// **Network: 2.** Latency-bound, and scanning a network volume is something the UI should
    /// discourage rather than optimise.
    public static func recommended(for volume: VolumeTraits, processorCount: Int) -> Int {
        if !volume.isLocal { return minimum }
        if volume.isRemovable || !volume.isInternal { return minimum }
        return min(max(processorCount - 2, minimum), maximum)
    }

    /// The width for the volume holding `path`, falling back to the conservative minimum when the
    /// traits cannot be read.
    ///
    /// Falling back *down* rather than up on purpose: guessing "internal NVMe" for an unknown volume
    /// would put eight concurrent readers on what might be a USB hard disk.
    public static func recommended(
        forItemAt path: String,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        guard let traits = VolumeTraits.forItem(at: path) else { return minimum }
        return recommended(for: traits, processorCount: processorCount)
    }
}
