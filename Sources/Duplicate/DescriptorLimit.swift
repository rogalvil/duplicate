import Foundation
import Synchronization

/// Raises the open-file limit at launch, and remembers what it found.
///
/// **Launch Services starts an app with a soft `RLIMIT_NOFILE` of 256.** A scan holds one descriptor per
/// concurrent hash plus the walk's own, and alongside the hash cache, the Quick Look XPC connection and
/// whatever Foundation keeps, 256 is not a comfortable margin. Running out does not crash: it surfaces as
/// an unreadable file, gets counted as a skipped candidate, and **the scan quietly finds less than it
/// should** -- a failure that looks like a smaller answer rather than an error.
///
/// A type rather than a few lines in `main.swift` so the before-and-after is recorded and can be asserted.
/// From a terminal the limit is often already in the millions, so a selftest that only looked at the
/// current value would pass whether or not the raise happens.
enum DescriptorLimit {
    /// What the soft limit was before anything touched it, and what it became.
    ///
    /// In a `Mutex` rather than a plain `static var`: Swift 6 rejects nonisolated global mutable state, and
    /// this is genuinely read from more than one place -- launch writes it, the selftest reads it.
    private static let recorded = Mutex<(original: rlim_t, raised: rlim_t)>((0, 0))

    static var originalSoftLimit: rlim_t { recorded.withLock { $0.original } }
    static var raisedSoftLimit: rlim_t { recorded.withLock { $0.raised } }

    /// How many descriptors to aim for.
    ///
    /// Well above the concurrency window, which tops out at 8. The point is headroom for everything else in
    /// the process, not for the scan alone.
    static let target: rlim_t = 4096

    /// Raises the soft limit toward ``target``, never above the hard limit.
    ///
    /// - Returns: the limit in effect afterwards.
    @discardableResult
    static func raiseIfNeeded() -> rlim_t {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return 0 }
        recorded.withLock { if $0.original == 0 { $0.original = limits.rlim_cur } }

        // Asking for more than `rlim_max` fails outright, which would leave the soft limit where it was.
        let wanted = min(target, limits.rlim_max)
        if limits.rlim_cur < wanted {
            limits.rlim_cur = wanted
            _ = setrlimit(RLIMIT_NOFILE, &limits)
            _ = getrlimit(RLIMIT_NOFILE, &limits)
        }
        recorded.withLock { $0.raised = limits.rlim_cur }
        return limits.rlim_cur
    }

    /// Lowers the soft limit, for a test that needs to see the raise happen.
    ///
    /// Lowering always succeeds; raising back is bounded by the hard limit, which this does not touch.
    static func lowerForTesting(to value: rlim_t) -> Bool {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return false }
        limits.rlim_cur = value
        return setrlimit(RLIMIT_NOFILE, &limits) == 0
    }

    static var current: rlim_t {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return 0 }
        return limits.rlim_cur
    }
}
