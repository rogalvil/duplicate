import Foundation
import Testing

@testable import DuplicateCore

/// Collects watcher callbacks so a test can await the first one without polling a mutable variable.
private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        lock.lock()
        count += 1
        let resuming = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resuming { waiter.resume() }
    }

    var observed: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    /// Waits for a callback, or gives up. Returns `false` on timeout, so the failure names the deadline
    /// rather than hanging the suite.
    func waitForChange(within deadline: Duration = .seconds(5)) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            let before = observed
            if before > 0 { return true }
            // Poll the clock, not the filesystem: a 50 ms sleep between checks costs nothing and keeps the
            // test from depending on continuation timing.
            try? await Task.sleep(for: .milliseconds(50))
        }
        return observed > 0
    }
}

private struct WatchScratch {
    let path: String

    init() throws {
        path = NSTemporaryDirectory() + "/duplicate-watch-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func write(_ name: String, _ text: String = "x", atomic: Bool = false) throws {
        try Data(text.utf8).write(
            to: URL(filePath: path + "/" + name), options: atomic ? [.atomic] : [])
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite("DirectoryWatcher")
struct DirectoryWatcherTests {

    @Test("A new file in the directory is reported")
    func reportsANewFile() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(30)) {
            recorder.record()
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        try scratch.write("scan.json")
        #expect(await recorder.waitForChange())
    }

    /// The event that matters most in practice: the CLI writes a scan while the app is open.
    @Test("A file written atomically is reported once, not twice")
    func coalescesAnAtomicWrite() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(80)) {
            recorder.record()
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        try scratch.write("scan.json", atomic: true)
        #expect(await recorder.waitForChange())
        // An atomic write is two events on the directory -- measured. Let the debounce window pass and
        // check it stayed one report.
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.observed == 1)
    }

    /// A burst -- what a batch of CLI saves looks like -- must not become a table reload per file.
    @Test("Twenty files in a burst report far fewer than twenty times")
    func coalescesABurst() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(100)) {
            recorder.record()
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        for index in 0..<20 { try scratch.write("scan-\(index).json") }
        #expect(await recorder.waitForChange())
        try await Task.sleep(for: .milliseconds(400))
        let observed = recorder.observed
        #expect(observed >= 1)
        #expect(observed <= 3, "20 files produced \(observed) reports")
    }

    @Test("A deleted file is reported")
    func reportsADeletion() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }
        try scratch.write("scan.json")

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(30)) {
            recorder.record()
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        try FileManager.default.removeItem(atPath: scratch.path + "/scan.json")
        #expect(await recorder.waitForChange())
    }

    /// **Measured, and the reason `.delete` is handled at all**: a descriptor to a removed directory stays
    /// open and stops delivering anything. Without reopening by path, the app would look healthy and never
    /// update again. Asserted on `reopenCount` rather than on a callback, because a callback also arrives
    /// for the delete itself and would not prove the watch came back.
    @Test("The watch survives the directory being replaced")
    func recoversFromAReplacedDirectory() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(30)) {
            recorder.record()
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        try FileManager.default.removeItem(atPath: scratch.path)
        try FileManager.default.createDirectory(
            atPath: scratch.path, withIntermediateDirectories: true)

        var attempts = 0
        while watcher.reopenCount == 0, attempts < 100 {
            try await Task.sleep(for: .milliseconds(50))
            attempts += 1
        }
        #expect(watcher.reopenCount >= 1)

        // And it really is watching the new directory, not just counting.
        let seenBefore = recorder.observed
        try scratch.write("after.json")
        var later = 0
        while recorder.observed <= seenBefore, later < 100 {
            try await Task.sleep(for: .milliseconds(50))
            later += 1
        }
        #expect(recorder.observed > seenBefore)
    }

    /// A slot the CLI has never created is the normal state of `folder-decisions/` on this machine, so a
    /// missing directory is a `false`, not a crash and not a throw.
    @Test("Starting on a directory that does not exist returns false")
    func refusesAMissingDirectory() {
        let watcher = DirectoryWatcher(path: "/nonexistent-\(UUID().uuidString)") {}
        #expect(watcher.start() == false)
        #expect(watcher.isWatching == false)
    }

    @Test("Stopping is idempotent and silences the watcher")
    func stopsCleanly() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(30)) {
            recorder.record()
        }
        #expect(watcher.start())
        watcher.stop()
        watcher.stop()
        #expect(watcher.isWatching == false)

        try scratch.write("after-stop.json")
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.observed == 0)
    }

    /// **The limitation, asserted rather than described.** A directory watch sees entries, not contents, so
    /// the CLI overwriting an existing document in place fires nothing. This test exists so the gap is a
    /// checked fact instead of a sentence in a doc comment that could quietly stop being true.
    @Test("Changing an existing file's contents is deliberately not reported")
    func doesNotSeeContentChanges() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }
        try scratch.write("scan.json", "before")

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(30)) {
            recorder.record()
        }
        #expect(watcher.start())
        defer { watcher.stop() }

        // Not `Data.write`, which would replace the entry: an in-place rewrite, which is what
        // Python's `Path.write_text` does.
        let handle = try #require(FileHandle(forWritingAtPath: scratch.path + "/scan.json"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("-after".utf8))
        try handle.close()

        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.observed == 0)
    }

    /// Stopping inside the debounce window has to swallow the report already in flight. A callback arriving
    /// after `stop()` would reach a window controller that is being torn down -- the watcher is stopped
    /// from `windowWillClose`.
    ///
    /// Teeth: drop the `isStopped = true` and `pending?.cancel()` from `stop()` and this fails with one
    /// report observed. Measured -- an earlier version of this comment named the work item's own `isStopped`
    /// check instead, and removing that one changes nothing here, because a cancelled item never runs.
    @Test("A report in flight is dropped when the watcher stops")
    func dropsAReportInFlight() async throws {
        let scratch = try WatchScratch()
        defer { scratch.remove() }

        let recorder = ChangeRecorder()
        let watcher = DirectoryWatcher(path: scratch.path, debounce: .milliseconds(400)) {
            recorder.record()
        }
        #expect(watcher.start())

        try scratch.write("scan.json")
        // Well inside the 400 ms window: the event has been delivered, the report has not.
        try await Task.sleep(for: .milliseconds(100))
        watcher.stop()

        try await Task.sleep(for: .milliseconds(600))
        #expect(recorder.observed == 0)
    }

    @Test("Duration converts to seconds for the Dispatch APIs")
    func convertsDurations() {
        #expect(Duration.milliseconds(150).timeInterval == 0.15)
        #expect(Duration.seconds(2).timeInterval == 2.0)
        #expect(Duration.microseconds(1).timeInterval == 0.000001)
    }
}
