import Foundation
import Testing

@testable import DuplicateCore

/// Builds real trees in a temporary directory. The walk's rules have to match a filesystem's
/// behaviour, so mocking the filesystem away would test the wrong thing.
struct WalkFixture {
    let root: String
    private let manager = FileManager.default

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-walk-\(UUID().uuidString)"
        try manager.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func remove() {
        // Restore any permissions the test removed, or the cleanup itself fails.
        if let all = manager.enumerator(atPath: root) {
            for case let name as String in all {
                try? manager.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: root + "/" + name)
            }
        }
        try? manager.removeItem(atPath: root)
    }

    @discardableResult
    func directory(_ relative: String) throws -> String {
        let path = root + "/" + relative
        try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 8) throws -> String {
        let path = root + "/" + relative
        let parent = (path as NSString).deletingLastPathComponent
        try manager.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: URL(filePath: path))
        return path
    }

    func symlink(_ relative: String, to target: String) throws {
        try manager.createSymbolicLink(atPath: root + "/" + relative, withDestinationPath: target)
    }

    func fifo(_ relative: String) throws {
        _ = (root + "/" + relative).withCString { mkfifo($0, 0o644) }
    }

    func chmod(_ relative: String, _ mode: Int) throws {
        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: root + "/" + relative)
    }

    func names(_ result: WalkResult) -> [String] {
        result.entries.map { ($0.path as NSString).lastPathComponent }.sorted()
    }

    func relativePaths(_ result: WalkResult) -> [String] {
        result.entries.map { String($0.path.dropFirst(root.count + 1)) }.sorted()
    }
}

private let runningAsRoot = getuid() == 0

@Suite("FileManagerWalker")
struct FileManagerWalkerTests {
    private let walker = FileManagerWalker()

    @Test("Keeps enumerating past a directory it cannot read")
    func continuesPastUnreadableDirectory() throws {
        // Two assertions, and only the second has teeth on this SDK. The plan claimed an error handler
        // returning false stops the enumeration; measured, it does not -- an EACCES on a subdirectory
        // yields the same file list whether the handler returns true, false, or is absent. What does
        // change is whether the caller can *report* the gap: with errorHandler nil, inaccessiblePaths
        // comes back empty and "no duplicates found" becomes indistinguishable from "could not look
        // inside 47 protected directories".
        try #require(
            !runningAsRoot, "root can read a 0o000 directory, so this proves nothing there")
        let fixture = try WalkFixture()
        defer { fixture.remove() }

        try fixture.file("a-before/one.txt")
        try fixture.directory("m-locked")
        try fixture.file("m-locked/hidden-from-us.txt")
        try fixture.file("z-after/two.txt")
        try fixture.chmod("m-locked", 0o000)

        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())

        #expect(fixture.names(result).contains("one.txt"))
        #expect(
            fixture.names(result).contains("two.txt"), "enumeration stopped at the locked directory"
        )
        #expect(result.inaccessiblePaths.count == 1)
        #expect(result.inaccessiblePaths[0].hasSuffix("m-locked"))
    }

    @Test("Prunes the directories the CLI prunes")
    func prunesIgnoredDirectories() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("keep.txt")
        for ignored in [".git", ".venv", "__pycache__", "node_modules"] {
            try fixture.file("\(ignored)/inside.txt")
        }
        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.names(result) == ["keep.txt"])
        #expect(result.skipped[.ignoredDirectory] == 4)
    }

    @Test("Skips hidden files and directories by default, and keeps them on request")
    func handlesHiddenEntries() throws {
        // A divergence from the CLI, which has no hidden filter at all. The toggle restores its
        // behaviour exactly, so the two tools can be compared on the same tree.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("visible.txt")
        try fixture.file(".hidden-file")
        try fixture.file(".hidden-dir/inside.txt")

        let strict = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.names(strict) == ["visible.txt"])

        let permissive = try walker.walk(
            root: fixture.root,
            policy: ScanPolicy.cliCompatible,
            exclusions: .init()
        )
        #expect(fixture.names(permissive) == [".hidden-file", "inside.txt", "visible.txt"])
    }

    @Test("Drops .DS_Store even when hidden files are included")
    func dropsNoiseFiles() throws {
        // Finder writes one per folder and they are frequently byte-identical, so a home-directory scan
        // can surface a single group with hundreds of members that buries every real finding.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("real.txt")
        try fixture.file(".DS_Store")
        try fixture.file("sub/.DS_Store")

        var policy = ScanPolicy()
        policy.includesHiddenFiles = true
        let result = try walker.walk(root: fixture.root, policy: policy, exclusions: .init())
        #expect(fixture.names(result) == ["real.txt"])
        #expect(result.skipped[.noise] == 2)
    }

    @Test("Never follows a symlink, to a file or to a directory")
    func neverFollowsSymlinks() throws {
        // Matching followlinks=False. A symlink has no content of its own, so hashing it would report a
        // duplicate of a file that is really one file.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        let target = try fixture.file("real/target.txt")
        try fixture.symlink("link-to-file", to: target)
        try fixture.symlink("link-to-dir", to: fixture.root + "/real")

        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.relativePaths(result) == ["real/target.txt"])
        #expect(result.skipped[.symbolicLink] != nil)
    }

    @Test("A symlink cycle terminates")
    func symlinkCycleTerminates() throws {
        // Whether NSDirectoryEnumerator follows symlinked directories is not something worth taking on
        // faith when the cost of being wrong is a walk that never returns.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("dir/file.txt")
        try fixture.symlink("dir/loop", to: fixture.root)

        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.relativePaths(result) == ["dir/file.txt"])
    }

    @Test("Skips a package by default and descends into it on request")
    func handlesPackages() throws {
        // Pulling one file out of a .photoslibrary or an .app corrupts the bundle silently, so the safe
        // default is to leave them alone.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("plain.txt")
        try fixture.file("Thing.rtfd/TXT.rtf")

        let skipping = try walker.walk(
            root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.names(skipping) == ["plain.txt"])
        #expect(skipping.skipped[.package] == 1)

        var policy = ScanPolicy()
        policy.packageHandling = .descend
        let descending = try walker.walk(root: fixture.root, policy: policy, exclusions: .init())
        #expect(fixture.names(descending) == ["TXT.rtf", "plain.txt"])
    }

    @Test("Skips anything that is not a regular file")
    func skipsNonRegularFiles() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("regular.txt")
        try fixture.fifo("pipe")

        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.names(result) == ["regular.txt"])
        #expect(result.skipped[.notRegularFile] == 1)
    }

    @Test("Honours the minimum size, excluding zero-byte files by default")
    func honoursMinimumSize() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("empty.txt", bytes: 0)
        try fixture.file("small.txt", bytes: 4)
        try fixture.file("large.txt", bytes: 100)

        let byDefault = try walker.walk(
            root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(fixture.names(byDefault) == ["large.txt", "small.txt"])
        #expect(byDefault.skipped[.tooSmall] == 1)

        var policy = ScanPolicy()
        policy.minimumSize = 50
        let filtered = try walker.walk(root: fixture.root, policy: policy, exclusions: .init())
        #expect(fixture.names(filtered) == ["large.txt"])
    }

    @Test("Populates the identity and clone fields the later stages need")
    func populatesIdentityFields() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        let original = try fixture.file("original.txt", bytes: 32)
        // A hardlink: same inode, two names. Removing one frees nothing, and reporting it as
        // recoverable space is a claim `df` can falsify.
        try FileManager.default.linkItem(
            atPath: original,
            toPath: fixture.root + "/hardlink.txt"
        )

        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        #expect(result.entries.count == 2)
        let identities = Set(result.entries.compactMap(\.identity))
        #expect(identities.count == 1, "two names for one inode must share an identity")
        for entry in result.entries {
            #expect(entry.linkCount == 2)
            #expect(!entry.isCertainlyUnlinked)
            #expect(entry.generation != nil)
            #expect(entry.modifiedNanoseconds != nil)
            #expect(entry.size == 32)
        }
    }

    @Test("Reports a root that cannot be enumerated at all")
    func reportsMissingRoot() throws {
        // enumerator(at:) hands back a perfectly good enumerator for a path that does not exist and
        // reports the problem only through its error handler, so a typo'd root would look like an empty
        // one. The root is probed before enumerating for exactly that reason.
        let missing = "/nonexistent-root-\(UUID().uuidString)"
        #expect(throws: WalkError.rootNotEnumerable(missing)) {
            _ = try FileManagerWalker().walk(
                root: missing, policy: ScanPolicy(), exclusions: .init())
        }

        // A file where a directory belongs is also not enumerable, and is a distinct user mistake.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        let file = try fixture.file("not-a-dir.txt")
        #expect(throws: WalkError.rootNotEnumerable(file)) {
            _ = try FileManagerWalker().walk(root: file, policy: ScanPolicy(), exclusions: .init())
        }
    }

    @Test("Records paths under the root it was given, not the resolved one")
    func preservesRequestedRootPrefix() throws {
        // A real interop break if it were wrong, not a cosmetic one. FileManager.enumerator resolves
        // symlinks in the root, so a walk of /var/x yields /private/var/x, while Python's os.walk
        // string-joins the root it was given. The CLI matches the kept paths in a decisions file back to
        // a group **by string equality** (src/rav/core/duplicate_review.py:76-83), so a review done in
        // the app would silently fail to apply in the CLI for any root under /tmp, /etc or /var.
        //
        // NSTemporaryDirectory() lives under /var, which is a symlink to /private/var, so this fixture
        // exercises the case by construction on any Mac.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("sub/f.txt")

        let result = try FileManagerWalker().walk(
            root: fixture.root,
            policy: ScanPolicy(),
            exclusions: .init()
        )
        #expect(result.entries.count == 1)
        #expect(result.entries[0].path == fixture.root + "/sub/f.txt")
        #expect(!result.entries[0].path.hasPrefix("/private/var"))

        // And the resolution really does differ here, or the assertion above proves nothing.
        #expect(RealPath.resolve(fixture.root) != fixture.root)
    }

    @Test("Tolerates a trailing slash on the root")
    func toleratesTrailingSlash() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("f.txt")
        let result = try FileManagerWalker().walk(
            root: fixture.root + "/",
            policy: ScanPolicy(),
            exclusions: .init()
        )
        #expect(result.entries.map(\.path) == [fixture.root + "/f.txt"])
    }

    @Test("Counts every entry it visited, kept or not")
    func countsVisitedEntries() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("a.txt")
        try fixture.file("sub/b.txt")
        try fixture.file(".hidden")

        let result = try walker.walk(root: fixture.root, policy: ScanPolicy(), exclusions: .init())
        // a.txt, sub, sub/b.txt, .hidden
        #expect(result.visitedCount == 4)
        #expect(result.entries.count == 2)
        #expect(result.skippedCount == 1)
    }
}

@Suite("Trash and quarantine exclusion")
struct ExclusionSetTests {
    private let walker = FileManagerWalker()

    @Test("Excludes a stand-in Trash root, and the duplicate inside it")
    func excludesStandInTrash() throws {
        // A unit test, not a selftest, because the resolver is injected. The real Trash is never
        // touched.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("real/dup.txt", bytes: 16)
        try fixture.file("faketrash/dup.txt", bytes: 16)

        let exclusions = ExclusionSet.forScan(
            of: fixture.root,
            resolver: FixedTrashRootResolver([fixture.root + "/faketrash"])
        )
        let result = try walker.walk(
            root: fixture.root, policy: ScanPolicy(), exclusions: exclusions)

        #expect(fixture.relativePaths(result) == ["real/dup.txt"])
        #expect(result.skipped[.excludedRoot] == 1)
        // And the pair never becomes a group, which is the point: a re-scan must not re-discover what a
        // previous run just removed.
        #expect(SizeBuckets.candidates(in: result.entries).isEmpty)
    }

    @Test("Excludes the target of a symlinked Trash, not just the symlink")
    func excludesSymlinkTarget() throws {
        // The case that proves identity-based pruning rather than path matching. The resolver names
        // `link-trash`; the walk encounters `elsewhere`. A string comparison against the resolver's
        // path would prune neither -- the symlink is skipped for being a symlink, and the real
        // directory would be walked under its own name.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("real/dup.txt", bytes: 16)
        try fixture.file("elsewhere/dup.txt", bytes: 16)
        try fixture.symlink("link-trash", to: fixture.root + "/elsewhere")

        let exclusions = ExclusionSet.forScan(
            of: fixture.root,
            resolver: FixedTrashRootResolver([fixture.root + "/link-trash"])
        )
        // The resolver's path was resolved through the symlink before its identity was read.
        #expect(exclusions.resolvedPaths.contains { $0.hasSuffix("/elsewhere") })

        let result = try walker.walk(
            root: fixture.root, policy: ScanPolicy(), exclusions: exclusions)
        #expect(fixture.relativePaths(result) == ["real/dup.txt"])
    }

    @Test("Excludes a configured quarantine root as well")
    func excludesQuarantineRoot() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("keep.txt")
        try fixture.file("quarantine/moved.txt")

        let exclusions = ExclusionSet.forScan(
            of: fixture.root,
            resolver: FixedTrashRootResolver([]),
            quarantineRoots: [fixture.root + "/quarantine"]
        )
        let result = try walker.walk(
            root: fixture.root, policy: ScanPolicy(), exclusions: exclusions)
        #expect(fixture.names(result) == ["keep.txt"])
    }

    @Test("Excludes volume-root stores by name, for directories it cannot stat")
    func excludesVolumeRootNamesByName() throws {
        // The fallback: <volume>/.Trashes often cannot be stat'd by the current user, so its identity is
        // unknown and the name is all there is. Still one comparison per directory, never per file.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("keep.txt")
        try fixture.file(".Trashes/501/removed.txt")
        try fixture.file(".fseventsd/log")

        var policy = ScanPolicy()
        policy.includesHiddenDirectories = true  // prove it is the name rule, not the hidden rule
        let result = try walker.walk(root: fixture.root, policy: policy, exclusions: .init())
        #expect(fixture.names(result) == ["keep.txt"])
    }

    @Test("Drops exclusion paths that do not exist")
    func dropsMissingExclusionPaths() {
        // A machine with no external volume mounted has no <volume>/.Trashes, and that is not a failure.
        let set = ExclusionSet.resolving(["/nonexistent-\(UUID().uuidString)"])
        #expect(set.identities.isEmpty)
        #expect(set.resolvedPaths.isEmpty)
        #expect(!set.excludes(nil))
    }

    @Test("An unknown identity is not excluded")
    func unknownIdentityIsNotExcluded() {
        // Excluding on a missing identity would silently drop every file on a volume that does not
        // report inodes.
        let set = ExclusionSet(identities: [FileIdentity(volume: 1, inode: 2)])
        #expect(set.excludes(FileIdentity(volume: 1, inode: 2)))
        #expect(!set.excludes(FileIdentity(volume: 1, inode: 3)))
        #expect(!set.excludes(nil))
    }

    @Test("The system resolver finds the user's Trash")
    func systemResolverFindsUserTrash() {
        // Reads the path, never writes to it and never lists it.
        let resolver = SystemTrashRootResolver(home: "/Users/tester")
        let roots = resolver.trashRoots(forItemAt: NSTemporaryDirectory())
        #expect(roots.contains("/Users/tester/.Trash"))
    }
}

@Suite("AccessProbe")
struct AccessProbeTests {
    @Test("Distinguishes an empty directory from one it cannot read")
    func distinguishesEmptyFromDenied() throws {
        // The whole reason this type exists. FileManager.enumerator yields nothing in both cases, so a
        // scan that cannot tell them apart reports "no duplicates" for ~/Library/Messages and looks
        // correct doing it.
        try #require(!runningAsRoot, "root can read a 0o000 directory")
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.directory("empty")
        try fixture.directory("locked")
        try fixture.file("locked/inside.txt")
        try fixture.chmod("locked", 0o000)

        #expect(AccessProbe.probe(path: fixture.root + "/empty") == .empty)
        #expect(AccessProbe.probe(path: fixture.root + "/locked") == .denied)
    }

    @Test("Reports a readable directory with a capped sample")
    func reportsReadableWithCappedSample() throws {
        // The question is whether the directory can be read, not what is in it. A probe that enumerated
        // $HOME would defeat its own purpose.
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        for index in 0..<10 { try fixture.file("full/f\(index).txt") }
        #expect(
            AccessProbe.probe(path: fixture.root + "/full", sampleLimit: 4)
                == .readable(sampleCount: 4))
    }

    @Test("Reports a missing path and a non-directory distinctly")
    func reportsMissingAndNonDirectory() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.file("a-file.txt")
        #expect(AccessProbe.probe(path: fixture.root + "/nope") == .missing)
        #expect(AccessProbe.probe(path: fixture.root + "/a-file.txt") == .notADirectory)
    }

    @Test("Filters a list down to the roots that cannot be read")
    func filtersUnreadableRoots() throws {
        let fixture = try WalkFixture()
        defer { fixture.remove() }
        try fixture.directory("fine")
        try fixture.file("fine/x.txt")

        let report = AccessProbe.unreadable(
            among: [fixture.root + "/fine", fixture.root + "/gone"]
        )
        #expect(report.count == 1)
        #expect(report[0].path.hasSuffix("/gone"))
        #expect(report[0].access == .missing)
    }
}

@Suite("WalkFilter")
struct WalkFilterTests {
    private let filter = WalkFilter(policy: ScanPolicy())

    @Test("Reports an excluded root before any other reason")
    func excludedRootWins() {
        // A .git inside the Trash reports as an excluded root, not as an ignored directory, because that
        // is the fact the user needs in the banner.
        let identity = FileIdentity(volume: 1, inode: 1)
        let scoped = WalkFilter(
            policy: ScanPolicy(),
            exclusions: ExclusionSet(identities: [identity])
        )
        let candidate = WalkCandidate(name: ".git", isDirectory: true, identity: identity)
        #expect(scoped.reasonToPrune(candidate) == .excludedRoot)
        #expect(filter.reasonToPrune(candidate) == .ignoredDirectory)
    }

    @Test("Hidden means a leading dot, not the NSURLIsHiddenKey flag")
    func hiddenMeansLeadingDot() {
        // NSURLIsHiddenKey also covers UF_HIDDEN and .hidden-file listings, which is a larger set than
        // the CLI's name.startswith("."). Using it would silently drop files the CLI keeps.
        #expect(WalkFilter.isDotted(".hidden"))
        #expect(!WalkFilter.isDotted("visible"))
        #expect(!WalkFilter.isDotted("mid.dot"))
        // A file flagged hidden but not dot-prefixed is kept.
        let flagged = WalkCandidate(name: "visible", isRegularFile: true, isHidden: true, size: 10)
        #expect(filter.reasonToSkip(flagged) == nil)
    }

    @Test("Refuses to cross a mount point unless asked")
    func refusesToCrossMountPoints() {
        // os.walk crosses them. Descending into a mounted Time Machine volume or a .sparsebundle under
        // the scan root is a catastrophe for a duplicate finder.
        let foreign = WalkCandidate(name: "Volumes", isDirectory: true, isOnForeignVolume: true)
        #expect(filter.reasonToPrune(foreign) == .otherVolume)

        var policy = ScanPolicy()
        policy.crossesMountPoints = true
        #expect(WalkFilter(policy: policy).reasonToPrune(foreign) == nil)
    }

    @Test("Accepts an ordinary file")
    func acceptsOrdinaryFile() {
        let file = WalkCandidate(name: "photo.jpg", isRegularFile: true, size: 1024)
        #expect(filter.reasonToSkip(file) == nil)
    }

    @Test("A file with no size is not judged too small")
    func missingSizeIsNotTooSmall() {
        // A size the walk could not read is unknown, not zero. Dropping it would silently skip files on
        // a volume that reports no sizes.
        let file = WalkCandidate(name: "x.bin", isRegularFile: true, size: nil)
        #expect(filter.reasonToSkip(file) == nil)
    }
}
