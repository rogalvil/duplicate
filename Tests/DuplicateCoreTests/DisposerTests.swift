import Foundation
import Testing

@testable import DuplicateCore

@Suite("CollisionResolver")
struct CollisionResolverTests {
    @Test("Returns the preferred name when it is free")
    func returnsPreferredWhenFree() {
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/photo.jpg", exists: { _ in false })
                == "/q/photo.jpg"
        )
    }

    @Test("Counts from two, before the extension")
    func countsFromTwo() {
        // Ports unique_destination (src/rav/core/duplicates.py:172-186). Starting at 2 rather than 1 is
        // what the CLI does, and a quarantine directory the two tools disagree about is worse than an odd
        // starting number.
        var taken: Set<String> = ["/q/photo.jpg"]
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/photo.jpg", exists: { taken.contains($0) })
                == "/q/photo-2.jpg"
        )
        taken.insert("/q/photo-2.jpg")
        taken.insert("/q/photo-3.jpg")
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/photo.jpg", exists: { taken.contains($0) })
                == "/q/photo-4.jpg"
        )
    }

    @Test("Turns archive.tar.gz into archive.tar-2.gz, deliberately")
    func preservesTheTarGzQuirk() {
        // Python's Path.stem and Path.suffix see only the last dot, so this is what the CLI produces.
        // Reproducing it is the point: a different name for the same collision would make a quarantine
        // directory the two tools disagree about.
        #expect(
            CollisionResolver.uniqueDestination(
                for: "/q/archive.tar.gz", exists: { $0.hasSuffix(".gz") && !$0.contains("-2") })
                == "/q/archive.tar-2.gz"
        )
    }

    @Test("A leading dot is not an extension")
    func leadingDotIsNotAnExtension() {
        // .DS_Store has no suffix. Treating the leading dot as one would produce "-2.DS_Store" with an
        // empty stem, which is not a filename anybody wants to see in a quarantine folder.
        var taken: Set<String> = ["/q/.DS_Store"]
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/.DS_Store", exists: { taken.contains($0) })
                == "/q/.DS_Store-2"
        )
        taken.insert("/q/.DS_Store-2")
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/.DS_Store", exists: { taken.contains($0) })
                == "/q/.DS_Store-3"
        )
    }

    @Test("A name with no extension still gets a suffix")
    func handlesNamesWithoutExtension() {
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/README", exists: { $0 == "/q/README" })
                == "/q/README-2"
        )
    }

    @Test("Gives up rather than searching forever")
    func givesUpAtTheLimit() {
        // A directory holding -2 through -1000 is not a collision, it is something else going wrong, and
        // silently working around it would hide that.
        #expect(
            CollisionResolver.uniqueDestination(for: "/q/x.bin", limit: 5, exists: { _ in true })
                == nil
        )
    }

    @Test("Only the last path component is examined")
    func ignoresDotsInDirectories() {
        // A dot in a directory name must not be mistaken for the file's extension.
        let (stem, suffix) = CollisionResolver.split("/q/v1.2/README")
        #expect(stem == "/q/v1.2/README")
        #expect(suffix == "")
    }
}

@Suite("TrashDisposer")
struct TrashDisposerTests {
    /// Removes whatever the Trash was handed, so a test run leaves nothing behind in the user's Trash.
    private func cleanUp(_ outcome: DisposalOutcome) {
        try? FileManager.default.removeItem(atPath: outcome.resultingPath)
    }

    @Test("Moves a real file to the real Trash and says where it went")
    func movesFileToTrash() throws {
        // Against the real API, in Core, because this is the riskiest component in the app. The plan's
        // largest open risk was that the external volume holding the corpus could not trash at all;
        // measured, every mounted volume here can.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let path = try tree.write("doomed.bin", bytes: ScratchTree.pattern(1234))

        let outcome = try TrashDisposer().dispose(path: path)
        defer { cleanUp(outcome) }

        #expect(outcome.mechanism == .trash)
        #expect(outcome.originalPath == path)
        #expect(outcome.byteCount == 1234)
        #expect(!FileManager.default.fileExists(atPath: path), "the original is still there")
        #expect(
            FileManager.default.fileExists(atPath: outcome.resultingPath),
            "nothing at the reported destination \(outcome.resultingPath)"
        )
    }

    @Test("The trashed file is byte-identical, so it can be put back")
    func trashedFileIsIntact() throws {
        // Without this, "undo" is a promise nobody checked.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let bytes = ScratchTree.pattern(4096)
        let path = try tree.write("intact.bin", bytes: bytes)
        let before = ScratchTree.oneShot(bytes)

        let outcome = try TrashDisposer().dispose(path: path)
        defer { cleanUp(outcome) }
        let after = try ContentHasher().fullDigest(atPath: outcome.resultingPath)
        #expect(after.digest == before)
        #expect(after.byteCount == 4096)
    }

    @Test("Reports a missing file as missing, not as a failure to trash")
    func reportsMissingFile() {
        // Ordinary on a live machine: a file can vanish between the review and the apply. The planner
        // treats this as already done, which it can only do if the error says which case it is.
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(throws: DisposalError.missing(path: missing)) {
            _ = try TrashDisposer().dispose(path: missing)
        }
    }

    @Test("Two files with the same name both survive the Trash")
    func handlesNameCollisionInTrash() throws {
        // macOS renames inside the Trash itself. The destination it reports is what the journal records, so
        // an undo has to follow that rather than assume the basename.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let first = try tree.write("same-name.bin", bytes: ScratchTree.pattern(100))
        let outcomeA = try TrashDisposer().dispose(path: first)
        defer { cleanUp(outcomeA) }

        let second = try tree.write("same-name.bin", bytes: ScratchTree.pattern(200))
        let outcomeB = try TrashDisposer().dispose(path: second)
        defer { cleanUp(outcomeB) }

        #expect(outcomeA.resultingPath != outcomeB.resultingPath)
        #expect(FileManager.default.fileExists(atPath: outcomeA.resultingPath))
        #expect(FileManager.default.fileExists(atPath: outcomeB.resultingPath))
        #expect(outcomeB.byteCount == 200)
    }
}

@Suite("QuarantineDisposer")
struct QuarantineDisposerTests {
    @Test("Moves a file into the session directory")
    func movesIntoSessionDirectory() throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let root = tree.root + "/quarantine"
        let path = try tree.write("moved.bin", bytes: ScratchTree.pattern(555))

        let disposer = QuarantineDisposer(root: root, sessionID: "20260511-064716-000001")
        let outcome = try disposer.dispose(path: path)

        #expect(outcome.mechanism == .quarantine)
        #expect(outcome.resultingPath == root + "/20260511-064716-000001/moved.bin")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.fileExists(atPath: outcome.resultingPath))
        #expect(outcome.byteCount == 555)
    }

    @Test("Renames rather than overwriting an existing file")
    func renamesOnCollision() throws {
        // Overwriting here would destroy data on the *recovery* path, which is the worst place for it.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let root = tree.root + "/quarantine"
        let session = root + "/20260511-064716-000001"
        try FileManager.default.createDirectory(atPath: session, withIntermediateDirectories: true)
        try Data("already here".utf8).write(to: URL(filePath: session + "/dup.bin"))
        let existingDigest = try ContentHasher().fullDigest(atPath: session + "/dup.bin")

        let path = try tree.write("dup.bin", bytes: ScratchTree.pattern(300))
        let disposer = QuarantineDisposer(root: root, sessionID: "20260511-064716-000001")
        let outcome = try disposer.dispose(path: path)

        #expect(outcome.resultingPath == session + "/dup-2.bin")
        // And the file that was already there is untouched.
        #expect(
            try ContentHasher().fullDigest(atPath: session + "/dup.bin").digest
                == existingDigest.digest
        )
    }

    @Test("The default root is outside ~/.Trash")
    func defaultRootAvoidsTheTrash() {
        // Defect 6. The CLI defaults to ~/.Trash/rav-duplicates and does not exclude it from its own walk,
        // so running it twice re-discovers everything the first run quarantined.
        let root = QuarantineDisposer.defaultRoot(
            applicationSupport: URL(filePath: "/Users/tester/Library/Application Support")
        )
        #expect(
            root == "/Users/tester/Library/Application Support/com.rogalvil.duplicate/quarantine"
        )
        #expect(!root.contains("/.Trash"))
    }

    @Test("Reports a missing file")
    func reportsMissingFile() throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let disposer = QuarantineDisposer(root: tree.root + "/q", sessionID: "s")
        let missing = tree.root + "/gone.bin"
        #expect(throws: DisposalError.missing(path: missing)) {
            _ = try disposer.dispose(path: missing)
        }
    }
}

/// Fails every disposal, to force the fallback.
private struct AlwaysFailingDisposer: ItemDisposing {
    let reason: String
    func dispose(path: String) throws -> DisposalOutcome {
        throw DisposalError.trashUnavailable(path: path, reason: reason)
    }
}

/// Records what it was asked to dispose, and succeeds.
private final class RecordingDisposer: ItemDisposing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seen: [String] = []
    func dispose(path: String) throws -> DisposalOutcome {
        lock.withLock { seen.append(path) }
        return DisposalOutcome(
            originalPath: path,
            resultingPath: "/recorded" + path,
            mechanism: .quarantine,
            byteCount: 0
        )
    }
}

@Suite("FallbackDisposer")
struct FallbackDisposerTests {
    @Test("Falls back to the quarantine when the Trash refuses")
    func fallsBackWhenTrashRefuses() throws {
        // What a network mount or a read-only volume looks like. A user whose duplicates live on a NAS
        // should not be told the app cannot help -- but also must not be told the files went to the Trash
        // when they did not, which is why the mechanism is recorded per file.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let path = try tree.write("f.bin", bytes: ScratchTree.pattern(64))

        let disposer = FallbackDisposer(
            primary: AlwaysFailingDisposer(reason: "read-only volume"),
            secondary: QuarantineDisposer(root: tree.root + "/q", sessionID: "s")
        )
        let outcome = try disposer.dispose(path: path)
        #expect(outcome.mechanism == .quarantine)
        #expect(outcome.resultingPath == tree.root + "/q/s/f.bin")
    }

    @Test("Uses the Trash when it works, without touching the fallback")
    func prefersTheTrash() throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let path = try tree.write("f.bin", bytes: ScratchTree.pattern(64))
        let fallback = RecordingDisposer()

        let outcome = try FallbackDisposer(primary: TrashDisposer(), secondary: fallback)
            .dispose(path: path)
        defer { try? FileManager.default.removeItem(atPath: outcome.resultingPath) }

        #expect(outcome.mechanism == .trash)
        #expect(fallback.seen.isEmpty, "the fallback was consulted even though the Trash worked")
    }

    @Test("A missing file is not retried in the fallback")
    func doesNotRetryMissingFile() throws {
        // A file that is already gone is not a reason to try somewhere else, and doing so would report a
        // quarantine failure for something that was never there.
        let fallback = RecordingDisposer()
        let missing = "/nonexistent-\(UUID().uuidString)"
        #expect(throws: DisposalError.missing(path: missing)) {
            _ = try FallbackDisposer(primary: TrashDisposer(), secondary: fallback)
                .dispose(path: missing)
        }
        #expect(fallback.seen.isEmpty)
    }
}

@Suite("VerifyingDisposer")
struct VerifyingDisposerTests {
    @Test("Removes a file whose content still matches")
    func removesMatchingFile() throws {
        let tree = try ScratchTree()
        defer { tree.remove() }
        let bytes = ScratchTree.pattern(800)
        let path = try tree.write("ok.bin", bytes: bytes)
        let inner = RecordingDisposer()

        let disposer = VerifyingDisposer(
            wrapping: inner,
            hasher: ContentHasher(),
            expected: [path: ScratchTree.oneShot(bytes)]
        )
        _ = try disposer.dispose(path: path)
        #expect(inner.seen == [path])
    }

    @Test("Refuses a file that changed since the scan")
    func refusesChangedFile() throws {
        // The safety valve. A stale scan, a file edited while the review window was open, or a
        // corrupt-but-CRC-valid cache row all land here -- and all become an error naming the file instead
        // of a file in the Trash that was never a duplicate.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let path = try tree.write("changed.bin", bytes: ScratchTree.pattern(800))
        let inner = RecordingDisposer()
        let stale = ScratchTree.oneShot(ScratchTree.pattern(799))

        let disposer = VerifyingDisposer(
            wrapping: inner,
            hasher: ContentHasher(),
            expected: [path: stale]
        )
        #expect(throws: DisposalError.contentChanged(path: path)) {
            _ = try disposer.dispose(path: path)
        }
        #expect(inner.seen.isEmpty, "the file was disposed despite failing verification")
    }

    @Test("Refuses a file nobody vouched for")
    func refusesUnvouchedFile() throws {
        // Disposing something absent from the plan is exactly the mistake this type exists to prevent, so
        // an unknown path is refused rather than allowed through.
        let tree = try ScratchTree()
        defer { tree.remove() }
        let path = try tree.write("stranger.bin", bytes: ScratchTree.pattern(10))
        let inner = RecordingDisposer()
        let disposer = VerifyingDisposer(wrapping: inner, hasher: ContentHasher(), expected: [:])
        #expect(throws: DisposalError.contentChanged(path: path)) {
            _ = try disposer.dispose(path: path)
        }
        #expect(inner.seen.isEmpty)
    }

    @Test("Reports a vanished file as missing")
    func reportsVanishedFile() throws {
        let inner = RecordingDisposer()
        let missing = "/nonexistent-\(UUID().uuidString)"
        let disposer = VerifyingDisposer(
            wrapping: inner,
            hasher: ContentHasher(),
            expected: [missing: ScratchTree.oneShot([])]
        )
        #expect(throws: DisposalError.missing(path: missing)) {
            _ = try disposer.dispose(path: missing)
        }
        #expect(inner.seen.isEmpty)
    }

    @Test("A group's removal set survives verification end to end")
    func verifiesAWholeRemovalSet() async throws {
        // The shape production uses: scan, take the group's removal candidates, verify each against the
        // digest the scan recorded, dispose. Nothing here is mocked except the final move.
        let tree = try WalkFixture()
        defer { tree.remove() }
        for name in ["a.bin", "b.bin", "c.bin"] {
            try tree.file(name, bytes: 900)
        }
        let outcome = try await DuplicateFinder().find(
            root: tree.root,
            instant: ScanIdentifier.Instant(
                year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 4
            ),
            configuration: .init(concurrency: 2)
        )
        let group = try #require(outcome.scan.groups.first)
        let keeper = group.files[0]
        let removals = group.removalCandidates(keeping: keeper)
        #expect(removals.count == 2)

        let expected = Dictionary(uniqueKeysWithValues: removals.map { ($0, group.digest) })
        let inner = RecordingDisposer()
        let disposer = VerifyingDisposer(
            wrapping: inner,
            hasher: ContentHasher(),
            expected: expected
        )
        for path in removals {
            _ = try disposer.dispose(path: path)
        }
        #expect(Set(inner.seen) == Set(removals))
        #expect(!inner.seen.contains(keeper), "the keeper was disposed")
    }
}

/// A real read-only APFS volume, made with `hdiutil` and no root.
///
/// **The disposer's error branches are only reachable on a volume that refuses writes**, and mocking the
/// filesystem away would test the wrong thing for the one component whose whole job is to move a real file.
/// So this makes one: a 10 MB disk image, written to while it is writable, then detached and re-attached
/// read-only.
///
/// It skips loudly rather than passing quietly when `hdiutil` is unavailable or the attach fails -- a sandbox
/// or a runner without disk-image support would otherwise report success for a test that never ran.
private struct ReadOnlyVolume {
    let mountPoint: String
    let filePath: String
    private let imagePath: String

    /// - Returns: nil when no volume could be made, which the caller reports as a skip.
    init?(fileNamed name: String = "victim.txt", contents: String = "on a read-only volume") {
        let scratch = NSTemporaryDirectory() + "duplicate-ro-\(UUID().uuidString)"
        guard
            (try? FileManager.default.createDirectory(
                atPath: scratch, withIntermediateDirectories: true)) != nil
        else { return nil }
        imagePath = scratch + "/ro.dmg"
        let volumeName = "RavRO\(abs(name.hashValue % 10_000))"
        mountPoint = "/Volumes/" + volumeName
        filePath = mountPoint + "/" + name

        guard
            ReadOnlyVolume.run(
                "hdiutil",
                [
                    "create", "-size", "10m", "-fs", "APFS", "-volname", volumeName,
                    "-type", "UDIF", "-ov", imagePath,
                ]),
            ReadOnlyVolume.run("hdiutil", ["attach", imagePath, "-nobrowse"]),
            (try? Data(contents.utf8).write(to: URL(filePath: filePath))) != nil,
            ReadOnlyVolume.run("hdiutil", ["detach", mountPoint]),
            ReadOnlyVolume.run("hdiutil", ["attach", imagePath, "-nobrowse", "-readonly"]),
            FileManager.default.fileExists(atPath: filePath)
        else {
            ReadOnlyVolume.run("hdiutil", ["detach", mountPoint, "-force"])
            try? FileManager.default.removeItem(atPath: scratch)
            return nil
        }
    }

    func remove() {
        ReadOnlyVolume.run("hdiutil", ["detach", mountPoint, "-force"])
        try? FileManager.default.removeItem(
            atPath: (imagePath as NSString).deletingLastPathComponent)
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@Suite("Disposer on a volume that refuses writes")
struct ReadOnlyVolumeDisposerTests {

    @Test("The Trash is unavailable on a read-only volume, and it says so")
    func trashRefusesOnAReadOnlyVolume() throws {
        guard let volume = ReadOnlyVolume() else {
            print("SKIPPED: could not make a read-only disk image with hdiutil")
            return
        }
        defer { volume.remove() }

        // The size is readable -- the file is there -- so this is the `trashItem` branch and not `.missing`.
        // That distinction is the point: "I could not reach the Trash" and "that file is gone" call for
        // different things from the reader.
        #expect(throws: DisposalError.self) {
            _ = try TrashDisposer().dispose(path: volume.filePath)
        }
        do {
            _ = try TrashDisposer().dispose(path: volume.filePath)
        } catch let error as DisposalError {
            guard case .trashUnavailable(let path, let reason) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(path == volume.filePath)
            #expect(!reason.isEmpty, "the refusal carries no reason to show")
        }
        #expect(FileManager.default.fileExists(atPath: volume.filePath), "the file left the volume")
    }

    @Test("Quarantine cannot rescue a file it cannot remove, and refuses rather than half-copying")
    func quarantineRefusesWhenTheSourceCannotBeRemoved() throws {
        guard let volume = ReadOnlyVolume(fileNamed: "trapped.txt") else {
            print("SKIPPED: could not make a read-only disk image with hdiutil")
            return
        }
        defer { volume.remove() }

        // **This is the finding, and it is the opposite of what the fallback's name suggests.** A read-only
        // volume is one of the two cases the quarantine exists for -- but a move off such a volume has to
        // delete the source, so the quarantine cannot help either. The honest outcome is a refusal with the
        // file still there, not a copy that leaves two.
        let quarantine = NSTemporaryDirectory() + "duplicate-q-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: quarantine) }
        do {
            let outcome = try FallbackDisposer(quarantineRoot: quarantine, sessionID: "S1")
                .dispose(path: volume.filePath)
            Issue.record("the fallback claimed to move a file off a read-only volume: \(outcome)")
        } catch let error as DisposalError {
            guard case .quarantineFailed(let path, let reason) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(path == volume.filePath)
            #expect(!reason.isEmpty)
        }
        #expect(FileManager.default.fileExists(atPath: volume.filePath), "the file left the volume")
    }

    @Test("A quarantine root that cannot be created is reported, not ignored")
    func quarantineRootOnAReadOnlyVolume() throws {
        guard let volume = ReadOnlyVolume(fileNamed: "doomed.txt") else {
            print("SKIPPED: could not make a read-only disk image with hdiutil")
            return
        }
        defer { volume.remove() }

        let scratch = NSTemporaryDirectory() + "duplicate-src-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let source = scratch + "/movable.txt"
        try Data("movable".utf8).write(to: URL(filePath: source))

        // The file is fine and the destination is impossible. Reported as a quarantine failure naming the
        // source, because that is the path the reader has to go look at.
        do {
            _ = try QuarantineDisposer(root: volume.mountPoint + "/quarantine", sessionID: "S1")
                .dispose(path: source)
            Issue.record("a quarantine on a read-only volume reported success")
        } catch let error as DisposalError {
            guard case .quarantineFailed(let path, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(path == source)
        }
        #expect(FileManager.default.fileExists(atPath: source), "the source moved anyway")
    }

    @Test("A thousand taken names is reported as such, not as a mystery failure")
    func exhaustedSuffixes() throws {
        // The resolver tries `-2` through `-1000`. Filling all of them is the only way to reach the branch, and
        // it is worth reaching: `noFreeName` says "something other than a collision is going on" -- a directory
        // full of a thousand near-identical names -- while a bare move failure would blame the filesystem.
        let scratch = NSTemporaryDirectory() + "duplicate-full-\(UUID().uuidString)"
        let session = scratch + "/S1"
        try FileManager.default.createDirectory(atPath: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        let empty = Data()
        try empty.write(to: URL(filePath: session + "/victim.txt"))
        for counter in 2...1000 {
            try empty.write(to: URL(filePath: session + "/victim-\(counter).txt"))
        }

        let source = scratch + "/victim.txt"
        try Data("real".utf8).write(to: URL(filePath: source))
        do {
            _ = try QuarantineDisposer(root: scratch, sessionID: "S1").dispose(path: source)
            Issue.record("it found a free name in a full directory")
        } catch let error as DisposalError {
            guard case .noFreeName(let path) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(path == session + "/victim.txt")
        }
        #expect(FileManager.default.fileExists(atPath: source), "the source moved anyway")
    }
}
