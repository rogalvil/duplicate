import Foundation
import Synchronization

/// Notices when the contents of a directory change.
///
/// Exists so a scan the CLI writes in a terminal shows up in the app's library without the user asking.
/// Polling would work too, but a 1-second poll over a directory the user is not looking at is a wakeup
/// per second forever, and a 10-second poll makes the app feel broken next to the terminal that just
/// printed the scan id.
///
/// **Measured, and it decides the shape of this type:**
///
/// | action on the directory | event delivered |
/// |---|---|
/// | an entry is created or deleted | `.write` |
/// | an existing file's *contents* change | **nothing** |
/// | a write with `.atomic` (temp + rename) | `.write` twice |
/// | the watched directory itself is removed | `.write` then `.delete`, and the source keeps running |
///
/// The second row is the load-bearing limitation: a directory watch sees its *entries*, not their
/// contents. The CLI's `Path.write_text` over an existing document fires nothing here. That is fine for
/// what the library shows -- a row is keyed by the file's existence, and a decisions document being
/// re-saved does not change whether it exists -- but it is a real gap and callers must not assume
/// otherwise. Anything that needs to see content change has to re-read, or watch that file.
///
/// The third row is why there is a debounce at all: one save is two events.
///
/// The fourth is why `.delete` re-establishes the watch instead of trusting the source to stop. A
/// descriptor to a deleted directory stays open and silent, so without this the app would look fine and
/// never update again.
public final class DirectoryWatcher: Sendable {
    /// How long to wait for a burst to settle before reporting it.
    ///
    /// One atomic save is two events, and the CLI writing several documents in a row is many. 150 ms is
    /// below the threshold where a person reads the list as stale and far above the gap between the two
    /// halves of one write.
    public static let defaultDebounce: Duration = .milliseconds(150)

    private struct State {
        var source: (any DispatchSourceFileSystemObject)?
        var descriptor: Int32 = -1
        var pending: DispatchWorkItem?
        var isStopped = false
        /// How many times the directory vanished and the watch was re-established.
        var reopenCount = 0
    }

    private let path: String
    private let debounce: Duration
    private let queue: DispatchQueue
    private let onChange: @Sendable () -> Void
    private let state: Mutex<State>

    /// - Parameter onChange: called on `queue` after a burst settles. Never called for a change this
    ///   process cannot distinguish from one made by another -- the watcher does not know who wrote.
    public init(
        path: String,
        debounce: Duration = DirectoryWatcher.defaultDebounce,
        queue: DispatchQueue = DispatchQueue(label: "com.rogalvil.duplicate.watch"),
        onChange: @escaping @Sendable () -> Void
    ) {
        self.path = path
        self.debounce = debounce
        self.queue = queue
        self.onChange = onChange
        self.state = Mutex(State())
    }

    deinit {
        // Not `stop()`: that takes the lock, and a deinit racing a callback that holds it would deadlock.
        // The source and descriptor are torn down directly.
        let carried = state.withLock { current -> (any DispatchSourceFileSystemObject)? in
            current.isStopped = true
            current.pending?.cancel()
            let source = current.source
            current.source = nil
            current.descriptor = -1
            return source
        }
        carried?.cancel()
    }

    /// Begins watching, and reports whether the directory could be opened.
    ///
    /// Returns `false` rather than throwing because a missing directory is the normal state of a slot the
    /// CLI has not created yet -- `folder-decisions/` does not exist on this machine. The caller decides
    /// whether that is worth surfacing.
    @discardableResult
    public func start() -> Bool {
        state.withLock { current in
            guard current.source == nil, !current.isStopped else { return true }
            return open(&current)
        }
    }

    /// Stops watching. Idempotent, and safe to call from any thread.
    public func stop() {
        let carried = state.withLock { current -> (any DispatchSourceFileSystemObject)? in
            current.isStopped = true
            current.pending?.cancel()
            current.pending = nil
            let source = current.source
            current.source = nil
            current.descriptor = -1
            return source
        }
        // Cancelled outside the lock: the cancel handler closes the descriptor and must not need the lock.
        carried?.cancel()
    }

    /// How many times the watched directory vanished and the watch had to be rebuilt.
    ///
    /// Exposed so a test can prove the recovery happened rather than inferring it from a callback that
    /// might have arrived for some other reason.
    public var reopenCount: Int {
        state.withLock { $0.reopenCount }
    }

    public var isWatching: Bool {
        state.withLock { $0.source != nil }
    }

    // MARK: - Private

    /// Opens the directory and arms a source. Caller holds the lock.
    private func open(_ current: inout State) -> Bool {
        let descriptor = Darwin.open(path, O_EVTONLY)
        guard descriptor >= 0 else { return false }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let vanished =
                source.data.contains(.delete) || source.data.contains(.rename)
                || source.data.contains(.revoke)
            self.handleEvent(vanished: vanished)
        }
        // The descriptor belongs to the source once it is armed, so it is closed here and nowhere else.
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()

        current.source = source
        current.descriptor = descriptor
        return true
    }

    private func handleEvent(vanished: Bool) {
        if vanished {
            reestablish()
        }
        scheduleReport()
    }

    /// Rebuilds the watch after the directory was deleted, renamed or replaced.
    ///
    /// A directory swapped out from under an open descriptor -- which is what a delete-and-recreate looks
    /// like, and what any tool that rebuilds the state directory does -- leaves the old source alive and
    /// permanently silent. Reopening by path is the only way back.
    private func reestablish() {
        let carried = state.withLock { current -> (any DispatchSourceFileSystemObject)? in
            guard !current.isStopped else { return nil }
            let previous = current.source
            current.source = nil
            current.descriptor = -1
            current.reopenCount += 1
            // May fail: the directory can be gone for good. `start()` can be called again later.
            _ = open(&current)
            return previous
        }
        carried?.cancel()
    }

    /// Collapses a burst of events into one report.
    private func scheduleReport() {
        state.withLock { current in
            guard !current.isStopped else { return }
            current.pending?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let shouldReport = self.state.withLock { inner -> Bool in
                    // Second guard, and deliberately not the one the test covers: `stop()` cancels this
                    // item, so the only way to get here after a stop is for the item to have been dequeued
                    // already. That race is real and cannot be provoked from a test, which is why it is
                    // guarded rather than asserted.
                    guard !inner.isStopped else { return false }
                    inner.pending = nil
                    return true
                }
                if shouldReport { self.onChange() }
            }
            current.pending = item
            queue.asyncAfter(deadline: .now() + debounce.timeInterval, execute: item)
        }
    }
}

extension Duration {
    /// Seconds as a `Double`, for the Dispatch APIs that predate `Duration`.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
