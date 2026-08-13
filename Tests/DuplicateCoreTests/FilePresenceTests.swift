import Foundation
import Synchronization
import Testing

@testable import DuplicateCore

private func digest(_ seed: String) -> Digest32 {
    Digest32(hexString: String(repeating: seed, count: 64))!
}

/// A real tree, because this type exists to report what the filesystem says.
private struct PresenceScratch {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-presence-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func write(_ name: String, bytes: Int) throws -> String {
        let path = root + "/" + name
        try Data(repeating: 0x41, count: bytes).write(to: URL(filePath: path))
        return path
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

@Suite("FilePresence")
struct FilePresenceTests {

    @Test("A file that is there with the recorded size is present")
    func reportsPresent() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let path = try scratch.write("a.bin", bytes: 100)

        let presence = FilePresence.check(path: path, expectedSize: 100)
        #expect(presence.state == .present)
        #expect(presence.state.isActionable)
        #expect(presence.modifiedAt != nil)
    }

    /// **The common case on any scan more than a few weeks old.** Of one real scan's 501 paths on this
    /// machine, 473 no longer exist.
    @Test("A file that is gone is missing")
    func reportsMissing() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }

        let presence = FilePresence.check(path: scratch.root + "/never.bin", expectedSize: 100)
        #expect(presence.state == .missing)
        #expect(presence.state.isActionable == false)
        #expect(presence.modifiedAt == nil)
    }

    /// A group whose file changed is a group that is no longer true. Deciding to remove a "duplicate" of it
    /// would remove something that is not a duplicate any more.
    @Test("A file whose length changed is reported as changed, with the new length")
    func reportsSizeChange() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let path = try scratch.write("a.bin", bytes: 120)

        let presence = FilePresence.check(path: path, expectedSize: 100)
        #expect(presence.state == .sizeChanged(onDisk: 120))
        #expect(presence.state.isActionable == false)
    }

    /// A directory where the scan recorded a file is not a file to act on, and saying "missing" would be a
    /// lie the user could check.
    @Test("A directory where a file was is reported as not a file")
    func reportsADirectory() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let path = scratch.root + "/was-a-file"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)

        #expect(FilePresence.check(path: path, expectedSize: 100).state == .notAFile)
    }

    /// **A symlink is not the file, and `attributesOfItem` does not follow one** -- measured, and the
    /// opposite is the easy assumption. The behaviour is what this needs: `WalkFilter` refuses symlinks, so
    /// one is never a scan member, and a symlink sitting at a recorded path means the file was replaced.
    /// Calling that `.present` would be actively wrong, because `trashItem` on a symlink moves the link and
    /// leaves the bytes alone -- space "freed" that no `df` would confirm.
    @Test("A symlink standing where the file was is not a file to act on")
    func refusesSymlinks() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let target = try scratch.write("target.bin", bytes: 100)
        let link = scratch.root + "/link.bin"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

        let presence = FilePresence.check(path: link, expectedSize: 100)
        #expect(presence.state == .notAFile)
        #expect(presence.state.isActionable == false)
        // And the target itself is still perfectly actionable.
        #expect(FilePresence.check(path: target, expectedSize: 100).state == .present)
    }

    @Test("A dangling symlink is not a file either")
    func reportsADanglingLink() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let link = scratch.root + "/dangling.bin"
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: scratch.root + "/gone.bin")

        // Something is there -- a link -- so "missing" would be a lie the user could check with `ls`.
        #expect(FilePresence.check(path: link, expectedSize: 100).state == .notAFile)
    }
}

@Suite("GroupPresence")
struct GroupPresenceTests {

    private func group(_ files: [String], size: Int64 = 100) -> DuplicateGroup {
        DuplicateGroup(size: size, digest: digest("a"), files: files)
    }

    @Test("A group whose files are all there is not stale")
    func reportsAHealthyGroup() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let a = try scratch.write("a.bin", bytes: 100)
        let b = try scratch.write("b.bin", bytes: 100)

        let presence = GroupPresence.check(group: group([a, b]))
        #expect(presence.presentCount == 2)
        #expect(presence.missingCount == 0)
        #expect(presence.isStale == false)
        #expect(presence.isStillADuplicate)
    }

    /// **Two survivors, not one.** A group with a single remaining member is not a duplicate group any
    /// more: there is nothing to remove and nothing to keep, and offering it would invite the user to
    /// delete their only copy.
    @Test("A group down to one surviving file is no longer a duplicate")
    func refusesASingleSurvivor() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let a = try scratch.write("a.bin", bytes: 100)

        let presence = GroupPresence.check(group: group([a, scratch.root + "/gone.bin"]))
        #expect(presence.presentCount == 1)
        #expect(presence.missingCount == 1)
        #expect(presence.isStale)
        #expect(presence.isStillADuplicate == false)
    }

    @Test("A group counts its changed files separately from its missing ones")
    func countsChangedAndMissing() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let same = try scratch.write("same.bin", bytes: 100)
        let grown = try scratch.write("grown.bin", bytes: 101)

        let presence = GroupPresence.check(
            group: group([same, grown, scratch.root + "/gone.bin"]))
        #expect(presence.presentCount == 1)
        #expect(presence.changedCount == 1)
        #expect(presence.missingCount == 1)
        #expect(presence.isStale)
        #expect(presence.isStillADuplicate == false)
    }

    @Test("A group whose files are all gone is stale and not a duplicate")
    func handlesAnEmptyGroup() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }

        let presence = GroupPresence.check(
            group: group([scratch.root + "/x.bin", scratch.root + "/y.bin"]))
        #expect(presence.presentCount == 0)
        #expect(presence.isStillADuplicate == false)
    }
}

@Suite("ScanPresence")
struct ScanPresenceTests {

    private func digest(_ seed: String) -> Digest32 {
        Digest32(hexString: String(repeating: seed, count: 64))!
    }

    @Test("Every group is checked and classified")
    func checksEveryGroup() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let a = try scratch.write("a.bin", bytes: 100)
        let b = try scratch.write("b.bin", bytes: 100)
        let c = try scratch.write("c.bin", bytes: 50)

        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: scratch.root,
            createdAt: "2026-08-12T12:00:00.000000Z",
            groups: [
                // Both there.
                DuplicateGroup(size: 100, digest: digest("a"), files: [a, b]),
                // One there, one gone.
                DuplicateGroup(size: 50, digest: digest("b"), files: [c, scratch.root + "/gone"]),
                // Both gone.
                DuplicateGroup(
                    size: 10, digest: digest("c"),
                    files: [scratch.root + "/x", scratch.root + "/y"]),
            ]
        )

        let result = try ScanPresence.check(scan: scan)
        #expect(result.checkedCount == 3)
        #expect(result.stillDuplicateCount == 1)
        #expect(result.goneCount == 1)
        #expect(result.partialCount == 1)
        #expect(result.stillDuplicate == [0: true, 1: false, 2: false])
    }

    @Test("Progress is reported once per group")
    func reportsProgress() throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let path = try scratch.write("a.bin", bytes: 10)
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: scratch.root,
            createdAt: "2026-08-12T12:00:00.000000Z",
            groups: (0..<4).map { _ in
                DuplicateGroup(size: 10, digest: digest("a"), files: [path, path])
            }
        )

        let seen = Mutex<[Int]>([])
        _ = try ScanPresence.check(scan: scan) { done, total in
            seen.withLock { $0.append(done) }
            #expect(total == 4)
        }
        #expect(seen.withLock { $0 } == [1, 2, 3, 4])
    }

    /// 9,949 paths in one of this user's scans. A check that could not be stopped would be a window that
    /// stops responding for as long as an external drive takes.
    @Test("A cancelled check throws instead of finishing")
    func stopsWhenCancelled() async throws {
        let scratch = try PresenceScratch()
        defer { scratch.remove() }
        let path = try scratch.write("a.bin", bytes: 10)
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: scratch.root,
            createdAt: "2026-08-12T12:00:00.000000Z",
            groups: (0..<500).map { _ in
                DuplicateGroup(size: 10, digest: digest("a"), files: [path, path])
            }
        )

        let task = Task { try ScanPresence.check(scan: scan) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("An empty scan checks nothing")
    func handlesAnEmptyScan() throws {
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000", root: "/r",
            createdAt: "2026-08-12T12:00:00.000000Z", groups: []
        )
        let result = try ScanPresence.check(scan: scan)
        #expect(result.checkedCount == 0)
        #expect(result.stillDuplicate.isEmpty)
    }
}
