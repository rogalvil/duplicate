import AppKit
import DuplicateCore
import Foundation

/// Headless checks that assert, and exit non-zero when they fail.
///
/// Unit tests cover `DuplicateCore` directly. This covers what they cannot reach: the assembled
/// bundle. Whether the Makefile substituted the plist placeholders, whether the `.lproj`
/// directories landed where `Bundle.main` looks for them, whether the menu builder produces a menu
/// with no shortcut collisions -- none of that is observable from `swift test`, because there is no
/// bundle there.
///
/// Two rules, both from the project's working agreement:
///
/// - **It must assert.** A mode that prints numbers nobody checks is decoration.
/// - **It must be proven to fail against the broken version.** Each mode below names, in a comment,
///   the change that makes it fail. A harness that passes against broken code is worthless.
///
/// Output is English: this is developer-facing diagnostics, not user-facing UI.
@MainActor
enum SelfTest {
    static func run(arguments: [String]) async -> Int32 {
        let mode = value(for: "--mode", in: arguments) ?? "all"

        let modes: [String]
        switch mode {
        case "all":
            modes = [
                "bundle", "state-dir", "l10n", "menu", "json-roundtrip", "scans", "digest",
                "walk-permissions", "trash-exclusion", "scan",
            ]
        default: modes = [mode]
        }

        for name in modes {
            do {
                switch name {
                case "bundle": try checkBundle()
                case "state-dir": try checkStateDirectory()
                case "l10n": try checkLocalization()
                case "menu": try checkMenu()
                case "json-roundtrip": try checkJSONRoundTrip(arguments: arguments)
                case "scans": try checkTypedScanRoundTrip(arguments: arguments)
                case "digest": try checkDigestAgainstShasum(arguments: arguments)
                case "walk-permissions": try checkWalkPermissions()
                case "trash-exclusion": try checkTrashExclusion(arguments: arguments)
                case "scan": try await checkEndToEndScan(arguments: arguments)
                default:
                    print("FAILED: unknown selftest mode '\(name)'")
                    return 1
                }
                print("OK: \(name)")
            } catch let failure as SelfTestFailure {
                print("FAILED: \(name): \(failure.description)")
                return 1
            } catch {
                print("FAILED: \(name): unexpected error: \(error)")
                return 1
            }
        }
        return 0
    }

    // MARK: - bundle

    /// Proves the Makefile actually substituted the Info.plist template.
    ///
    /// Fails if a `__PLACEHOLDER__` survives, which is what happens when a new key is added to the
    /// template and not to the `sed` invocation. An unsubstituted bundle identifier would silently
    /// orphan every TCC grant.
    ///
    /// Proof of teeth: remove one `-e 's|__VERSION__|...|g'` from the Makefile and this fails.
    private static func checkBundle() throws {
        let required = [
            "CFBundleIdentifier", "CFBundleName", "CFBundleExecutable",
            "CFBundleShortVersionString", "LSMinimumSystemVersion",
            "DUPBuildDate", "DUPGitCommit",
        ]
        guard let info = Bundle.main.infoDictionary else {
            throw SelfTestFailure("no Info.plist in the running bundle")
        }
        for key in required {
            guard let value = info[key] as? String else {
                throw SelfTestFailure("Info.plist has no string for \(key)")
            }
            if value.hasPrefix("__") {
                throw SelfTestFailure("Info.plist \(key) is an unsubstituted placeholder: \(value)")
            }
        }
        guard info["LSUIElement"] == nil else {
            throw SelfTestFailure(
                "LSUIElement is set; this is a windowed app and needs a Dock icon")
        }
        guard let localizations = info["CFBundleLocalizations"] as? [String],
            Set(localizations) == Set(["en", "es"])
        else {
            throw SelfTestFailure("CFBundleLocalizations is not exactly [en, es]")
        }
        print(
            "  bundle \(info["CFBundleIdentifier"] as? String ?? "?") "
                + "\(info["CFBundleShortVersionString"] as? String ?? "?") "
                + "commit \(info["DUPGitCommit"] as? String ?? "?")")
    }

    // MARK: - state-dir

    /// Proves the state directory resolves the way the CLI resolves it.
    ///
    /// The interesting assertion is the empty-`XDG_STATE_HOME` one: Python's `os.environ.get`
    /// returns a falsy `""` and falls back to `~/.local/state`, while an empty Swift `String` is
    /// truthy. A literal translation resolves the root to `/rav` and stops seeing every scan the
    /// CLI ever wrote, while reporting success.
    ///
    /// Proof of teeth: change the `base.isEmpty` guard in StateDirectory to `base == nil` and this
    /// fails on the second assertion.
    private static func checkStateDirectory() throws {
        let home = "/Users/tester"

        let unset = StateDirectory(environment: [:], homePath: home)
        try expect(
            unset.ravRootPath == "/Users/tester/.local/state/rav",
            "unset XDG_STATE_HOME resolved to \(unset.ravRootPath)"
        )

        let empty = StateDirectory(environment: ["XDG_STATE_HOME": ""], homePath: home)
        try expect(
            empty.ravRootPath == unset.ravRootPath,
            "empty XDG_STATE_HOME resolved to \(empty.ravRootPath), "
                + "expected the same fallback as unset"
        )

        let tilde = StateDirectory(environment: ["XDG_STATE_HOME": "~/custom"], homePath: home)
        try expect(
            tilde.ravRootPath == "/Users/tester/custom/rav",
            "tilde was not expanded: \(tilde.ravRootPath)"
        )

        // The six shared slots must be spelled exactly as the CLI spells them.
        let expected = [
            "scans", "decisions", "folder-scans", "folder-decisions",
            "similar-scans", "similar-decisions", "journal",
        ]
        let actual = StateDirectory.Slot.allCases.map(\.rawValue)
        try expect(actual == expected, "slot names drifted: \(actual)")

        // No slot path may end in a slash. FileManager.fileExists(atPath:) never matches a
        // trailing-slash path against a regular file, so the collision guard below would not fire.
        for slot in StateDirectory.Slot.allCases {
            try expect(
                !unset.path(for: slot).hasSuffix("/"),
                "slot \(slot.rawValue) produced a trailing slash"
            )
        }

        // An identifier read off disk is untrusted input interpolated into a path.
        for bad in ["../../etc/passwd", "", "20260511-112539-97309", "20260511_112539_973098"] {
            var threw = false
            do {
                _ = try unset.filePath(for: .scans, id: bad)
            } catch StateDirectoryError.invalidIdentifier {
                threw = true
            }
            try expect(threw, "identifier \(bad.debugDescription) was accepted")
        }
        let good = try unset.filePath(for: .scans, id: "20260511-112539-973098")
        try expect(
            good.hasSuffix("/scans/20260511-112539-973098.json"),
            "valid identifier produced \(good)"
        )

        // Creation is checked in a temporary directory, never in the user's real state directory:
        // a selftest must not leave anything behind in shared state.
        let scratch = NSTemporaryDirectory() + "/duplicate-selftest-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let scratchState = StateDirectory(
            environment: ["XDG_STATE_HOME": scratch],
            homePath: home
        )
        let created = try scratchState.create(.scans)
        try expect(
            FileManager.default.fileExists(atPath: created),
            "create(.scans) did not create \(created)"
        )
        _ = try scratchState.create(.scans)  // idempotent

        // Something that is not a directory occupying the path must be reported, not swallowed.
        // Foundation reports it as NSCocoaErrorDomain 516, whose text never says a directory was
        // expected.
        let blocked = scratchState.path(for: .decisions)
        try FileManager.default.createDirectory(
            atPath: scratchState.duplicateRootPath,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: blocked, contents: Data(), attributes: nil)
        var reported = false
        do {
            _ = try scratchState.create(.decisions)
        } catch StateDirectoryError.notADirectory {
            reported = true
        }
        try expect(reported, "a regular file at \(blocked) was not reported")

        print("  live state root: \(StateDirectory.current().duplicateRootPath)")
    }

    // MARK: - l10n

    /// Proves both string tables shipped and cover the same keys.
    ///
    /// A missing key renders as the key itself, so this is the difference between a Spanish menu and
    /// a menu that says `menu.app.quit`.
    ///
    /// Proof of teeth: delete one line from es.lproj/Localizable.strings and this fails naming it.
    private static func checkLocalization() throws {
        for table in ["Localizable", "InfoPlist"] {
            guard let base = Strings.table(localization: "en", table: table) else {
                throw SelfTestFailure("en.lproj/\(table).strings is missing from the bundle")
            }
            guard let spanish = Strings.table(localization: "es", table: table) else {
                throw SelfTestFailure("es.lproj/\(table).strings is missing from the bundle")
            }
            let audit = StringTableAudit.audit(base: base, translation: spanish)
            try expect(
                audit.missing.isEmpty,
                "\(table): missing from es.lproj: \(audit.missing.joined(separator: ", "))"
            )
            try expect(
                audit.orphaned.isEmpty,
                "\(table): only in es.lproj: \(audit.orphaned.joined(separator: ", "))"
            )
            print("  \(table): \(base.count) keys, \(audit.identical.count) identical in both")
        }
    }

    // MARK: - json-roundtrip

    /// Proves byte-for-byte JSON compatibility against files the CLI really wrote.
    ///
    /// The unit tests cover this with synthetic fixtures, because the user's real state directory
    /// holds private paths and a committed fixture is a published file. This mode covers the real
    /// corpus instead: it reads every JSON document in the six shared subdirectories, re-encodes it,
    /// and compares the bytes. Read-only -- nothing is written, moved or deleted.
    ///
    /// Pass `--dir <path>` to point it somewhere else. Reports and passes when there is nothing to
    /// read, since a machine that has never run the CLI is not a failing machine -- but it says so
    /// rather than printing a silent OK.
    ///
    /// Proof of teeth: change the indent in JSONWriter from 2 to 4 and every file fails at byte 2.
    private static func checkJSONRoundTrip(arguments: [String]) throws {
        let state = StateDirectory.current()
        let roots: [String] =
            if let override = value(for: "--dir", in: arguments) {
                [override]
            } else {
                StateDirectory.Slot.allCases.filter(\.isSharedWithCLI).map(state.path(for:))
            }

        var checked = 0
        var failures: [String] = []
        var skippedDirectories = 0

        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
                skippedDirectories += 1
                continue
            }
            for name in names.sorted() where name.hasSuffix(".json") {
                let path = root + "/" + name
                let original: Data
                do {
                    original = try Data(contentsOf: URL(filePath: path))
                } catch {
                    failures.append("\(name): unreadable: \(error.localizedDescription)")
                    continue
                }
                do {
                    let reencoded = try JSONWriter.document(JSONReader.parse(original))
                    checked += 1
                    guard reencoded != original else { continue }
                    let offset =
                        zip(original, reencoded).enumerated()
                        .first { $0.element.0 != $0.element.1 }?.offset
                    failures.append(
                        "\(name): differs at byte \(offset.map(String.init) ?? "the end"); "
                            + "\(original.count) bytes in, \(reencoded.count) out"
                    )
                } catch {
                    failures.append("\(name): \(error)")
                }
            }
        }

        guard failures.isEmpty else {
            throw SelfTestFailure(
                "\(failures.count) of \(checked + failures.count) documents did not round-trip:\n    "
                    + failures.prefix(10).joined(separator: "\n    ")
            )
        }
        if checked == 0 {
            print("  SKIPPED: no JSON found (\(skippedDirectories) directories absent)")
        } else {
            print("  \(checked) documents re-encoded byte-identically")
        }
    }

    // MARK: - scans

    /// Proves every real scan decodes into the typed model and re-encodes byte-identically.
    ///
    /// `json-roundtrip` proves the generic tree survives. This proves the path production actually
    /// takes -- `DuplicateScanCodec.decode` into `DuplicateScan` and back -- which is where a wrong
    /// key name, a reordered field, or an over-eager numeric coercion would show up. It also reports
    /// how many scans carry relative paths, because those cannot be acted on and the UI has to ask
    /// the user to resolve them.
    ///
    /// Read-only. Nothing is written, moved or deleted.
    ///
    /// Proof of teeth: rename the `sha256` key in the codec to `digest` and every scan with at least
    /// one group fails.
    private static func checkTypedScanRoundTrip(arguments: [String]) throws {
        let state = StateDirectory.current()
        let root = value(for: "--dir", in: arguments) ?? state.path(for: .scans)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            print("  SKIPPED: \(root) is not readable")
            return
        }

        var decoded = 0
        var groups = 0
        var files = 0
        var relative = 0
        var failures: [String] = []

        for name in names.sorted() where name.hasSuffix(".json") {
            let path = root + "/" + name
            do {
                let original = try Data(contentsOf: URL(filePath: path))
                let scan = try DuplicateScanCodec.decode(JSONReader.parse(original))
                let reencoded = try JSONWriter.document(DuplicateScanCodec.encode(scan))
                guard reencoded == original else {
                    let offset =
                        zip(original, reencoded).enumerated()
                        .first { $0.element.0 != $0.element.1 }?.offset
                    failures.append(
                        "\(name): differs at byte \(offset.map(String.init) ?? "the end")"
                    )
                    continue
                }
                // The filename and the field inside must agree, or re-saving this scan would either
                // overwrite a different one or silently rename this one.
                guard name == scan.scanID + ".json" else {
                    failures.append("\(name): holds scan_id \(scan.scanID)")
                    continue
                }
                decoded += 1
                groups += scan.groups.count
                files += scan.fileCount
                if scan.hasRelativePaths { relative += 1 }
            } catch {
                failures.append("\(name): \(error)")
            }
        }

        guard failures.isEmpty else {
            throw SelfTestFailure(
                "\(failures.count) of \(decoded + failures.count) scans failed:\n    "
                    + failures.prefix(10).joined(separator: "\n    ")
            )
        }
        if decoded == 0 {
            print("  SKIPPED: no scans in \(root)")
        } else {
            print("  \(decoded) scans decoded and re-encoded byte-identically")
            print("  \(groups) groups, \(files) files, \(relative) scans with relative paths")
        }
    }

    // MARK: - digest

    /// Proves the hasher agrees with `shasum -a 256` at the production chunk size.
    ///
    /// The unit tests shrink the chunk to 4 KiB so boundaries are cheap to straddle, and they compare
    /// against a one-shot `CryptoKit` call. Neither of those is what ships: production reads 1 MiB at a
    /// time through a reused page-aligned buffer, and the value that matters is the one `hashlib`
    /// produces, because that is what is already written in the shared scan files.
    ///
    /// `shasum` is the same tool a user would reach for to check the app's arithmetic, which is why it
    /// is the oracle here rather than a second copy of our own code.
    ///
    /// - Note: `--file <path>` hashes that file instead of the synthesized set.
    ///
    /// Proof of teeth: drop the last chunk in `fullDigest`'s read loop (break before the final
    /// `update`) and the 1 MiB + 1 case fails while the small ones still pass.
    private static func checkDigestAgainstShasum(arguments: [String]) throws {
        let hasher = ContentHasher()

        if let path = value(for: "--file", in: arguments) {
            let ours = try hasher.fullDigest(atPath: path)
            let theirs = try shasum(of: path)
            try expect(
                ours.digest.hexString == theirs,
                "\(path): we say \(ours.digest.hexString), shasum says \(theirs)"
            )
            print("  \(ours.digest.hexString)  \(path) (\(ours.byteCount) bytes)")
            return
        }

        let scratch = NSTemporaryDirectory() + "/duplicate-digest-\(getpid())"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }

        // Straddling the real 1 MiB chunk, not a shrunken one. An empty file is included because it is
        // the one case where the read loop exits before hashing anything.
        let chunk = hasher.configuration.chunkBytes
        let sizes = [0, 1, chunk - 1, chunk, chunk + 1, 2 * chunk, 3 * chunk + 7]
        for size in sizes {
            let path = scratch + "/f-\(size)"
            let bytes = (0..<size).map { UInt8($0 % 251) }
            try Data(bytes).write(to: URL(filePath: path))

            let ours = try hasher.fullDigest(atPath: path)
            let theirs = try shasum(of: path)
            try expect(
                ours.digest.hexString == theirs,
                "size \(size): we say \(ours.digest.hexString), shasum says \(theirs)"
            )
            try expect(
                ours.byteCount == Int64(size),
                "size \(size): hashed \(ours.byteCount) bytes"
            )
        }
        print("  \(sizes.count) sizes agree with shasum -a 256 at a \(chunk)-byte chunk")
    }

    /// Runs `shasum -a 256` and returns the hex digest.
    private static func shasum(of path: String) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SelfTestFailure("shasum exited \(process.terminationStatus) for \(path)")
        }
        guard
            let first = String(decoding: data, as: UTF8.self)
                .split(separator: " ", omittingEmptySubsequences: true).first
        else {
            throw SelfTestFailure("shasum produced no digest for \(path)")
        }
        return String(first)
    }

    // MARK: - walk-permissions

    /// Proves the walk keeps going past a directory it cannot read, **and reports that it did**.
    ///
    /// The second half is where the value is, and it took a failed teeth-proof to find that out. The
    /// plan claimed that an error handler returning `false` stops the enumeration, so a naive port would
    /// scan 3% of a home directory and report success. **Measured on this SDK, that is not true:** an
    /// EACCES on a subdirectory yields the same file list whether the handler returns `true`, returns
    /// `false`, or is absent entirely.
    ///
    /// What is true, and what this mode actually guards, is the reporting. With `errorHandler: nil` the
    /// walk returns identical files and the caller learns nothing -- no count, no path, no signal. "No
    /// duplicates found" then means either "there are none" or "I could not look inside 47 protected
    /// directories", with no way for the user to tell which.
    ///
    /// Proof of teeth: pass `errorHandler: nil` and `inaccessiblePaths` comes back empty while every
    /// other assertion still passes.
    private static func checkWalkPermissions() throws {
        guard getuid() != 0 else {
            // An explicit skip, not a silent pass: root reads a 0o000 directory, so the assertion below
            // would hold for the wrong reason.
            print("  SKIPPED: running as root, which can read a 0o000 directory")
            return
        }

        let scratch = NSTemporaryDirectory() + "/duplicate-walkperm-\(getpid())"
        let manager = FileManager.default
        defer {
            try? manager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: scratch + "/m-locked"
            )
            try? manager.removeItem(atPath: scratch)
        }

        for directory in ["a-before", "m-locked", "z-after"] {
            try manager.createDirectory(
                atPath: scratch + "/" + directory,
                withIntermediateDirectories: true
            )
        }
        for path in ["a-before/one.txt", "m-locked/unreachable.txt", "z-after/two.txt"] {
            try Data("x".utf8).write(to: URL(filePath: scratch + "/" + path))
        }
        try manager.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: scratch + "/m-locked"
        )

        let result = try FileManagerWalker().walk(
            root: scratch,
            policy: ScanPolicy(),
            exclusions: ExclusionSet()
        )
        let names = Set(result.entries.map { ($0.path as NSString).lastPathComponent })
        try expect(names.contains("one.txt"), "the file before the locked directory is missing")
        try expect(
            names.contains("two.txt"),
            "enumeration stopped at the locked directory: only \(names.sorted()) came back"
        )
        try expect(
            result.inaccessiblePaths.count == 1,
            "expected exactly one inaccessible directory, got \(result.inaccessiblePaths)"
        )
        // Paths must read under the root the caller gave, not the resolved one. NSTemporaryDirectory
        // lives under /var, a symlink to /private/var, so this is exercised by construction.
        try expect(
            result.entries.allSatisfy { $0.path.hasPrefix(scratch + "/") },
            "a path escaped the requested root prefix"
        )
        print("  walked past 1 unreadable directory; \(result.entries.count) files kept")
    }

    // MARK: - trash-exclusion

    /// Proves the real resolver finds the Trash roots, and that a stand-in one is actually pruned.
    ///
    /// Two halves, because neither alone is enough. The stand-in half proves the pruning works and can
    /// run anywhere; the real half proves the resolver points at the right places on this machine.
    ///
    /// **The real Trash is never listed, never walked and never written to.** Only its identity is read,
    /// and only to assert that it is in the exclusion set.
    ///
    /// Proof of teeth: compare exclusion roots by path string instead of by identity and the symlink
    /// half fails while the plain half still passes -- which is exactly the shape that would ship
    /// unnoticed.
    private static func checkTrashExclusion(arguments: [String]) throws {
        let manager = FileManager.default

        // Half one: a stand-in tree, with a duplicate planted inside the excluded root and a symlink
        // pointing at a second one.
        let scratch = NSTemporaryDirectory() + "/duplicate-trash-\(getpid())"
        defer { try? manager.removeItem(atPath: scratch) }
        for directory in ["real", "faketrash", "elsewhere"] {
            try manager.createDirectory(
                atPath: scratch + "/" + directory,
                withIntermediateDirectories: true
            )
        }
        let payload = Data(repeating: 7, count: 64)
        for path in ["real/dup.txt", "faketrash/dup.txt", "elsewhere/dup.txt"] {
            try payload.write(to: URL(filePath: scratch + "/" + path))
        }
        try manager.createSymbolicLink(
            atPath: scratch + "/link-trash",
            withDestinationPath: scratch + "/elsewhere"
        )

        let exclusions = ExclusionSet.forScan(
            of: scratch,
            resolver: FixedTrashRootResolver([
                scratch + "/faketrash",
                // Named through the symlink on purpose: the walk will meet the target under its own
                // name, which only identity-based pruning recognises.
                scratch + "/link-trash",
            ])
        )
        let result = try FileManagerWalker().walk(
            root: scratch,
            policy: ScanPolicy(),
            exclusions: exclusions
        )
        let kept = result.entries.map { $0.path.dropFirst(scratch.count + 1) }.sorted()
        try expect(
            kept == ["real/dup.txt"],
            "expected only real/dup.txt to survive, got \(kept)"
        )
        // And the planted copies never form a group, which is the whole point: a rescan must not
        // re-discover what a previous run removed.
        try expect(
            SizeBuckets.candidates(in: result.entries).isEmpty,
            "the excluded copies still formed a duplicate group"
        )

        // Half two: the real resolver, on this machine. Read-only.
        let resolver = SystemTrashRootResolver()
        let probeRoot = value(for: "--dir", in: arguments) ?? NSHomeDirectory()
        let roots = resolver.trashRoots(forItemAt: probeRoot)
        try expect(!roots.isEmpty, "the resolver named no Trash roots for \(probeRoot)")
        try expect(
            roots.contains(NSHomeDirectory() + "/.Trash"),
            "the resolver did not name ~/.Trash: \(roots)"
        )

        let live = ExclusionSet.forScan(of: probeRoot, resolver: resolver)
        // ~/.Trash exists on every Mac, so its identity must have resolved.
        try expect(
            !live.identities.isEmpty,
            "no Trash identity resolved from \(roots)"
        )
        // The CLI's three quarantine directories all live under ~/.Trash, so excluding it covers all of
        // them at once. Assert on the resolved set, never by listing the Trash.
        try expect(
            live.resolvedPaths.contains { $0.hasSuffix("/.Trash") },
            "~/.Trash did not resolve into the exclusion set: \(live.resolvedPaths)"
        )
        print(
            "  stand-in trash pruned; live resolver covers \(live.identities.count) "
                + "director\(live.identities.count == 1 ? "y" : "ies")"
        )
    }

    // MARK: - scan

    /// Runs a real end-to-end scan against a synthesized tree with a known answer.
    ///
    /// Everything before this mode tests a stage. This tests the pipeline: walk, bucket, probe, hash,
    /// group, encode. It also asserts the two properties that make a scan trustworthy and that no unit
    /// test can reach as convincingly:
    ///
    /// - **The document is identical at every concurrency width.** If completion order could leak into
    ///   the output, two runs of the same tree would differ and the interop round-trip would start
    ///   failing intermittently -- the worst possible failure mode for a byte-compatibility claim.
    /// - **A saved scan reloads to the same bytes.** Which is what the app will do minutes later when
    ///   the user opens it to review.
    ///
    /// - Note: `--dir <path>` scans a real directory instead, asserting only the invariants that hold
    ///   for any tree. Read-only in both cases: nothing is moved or deleted.
    ///
    /// Proof of teeth: sort the group's files with Swift's `String <` instead of ``PathOrder`` and the
    /// known-answer assertion fails on the Unicode pair.
    private static func checkEndToEndScan(arguments: [String]) async throws {
        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 685054
        )
        let finder = DuplicateFinder()

        if let root = value(for: "--dir", in: arguments) {
            let progress = ProgressCounters()
            let outcome = try await finder.find(root: root, instant: instant, progress: progress)
            let snapshot = progress.snapshot()
            try expect(snapshot.phase == .finished, "phase ended at \(snapshot.phase)")
            for group in outcome.scan.groups {
                try expect(
                    group.files.count > 1,
                    "a group with \(group.files.count) member survived"
                )
                try expect(
                    group.files == PathOrder.sorted(group.files),
                    "a group's files were not in byte order"
                )
            }
            print(
                "  \(root): \(outcome.scan.groups.count) groups, "
                    + "\(outcome.scan.fileCount) files, "
                    + "\(ByteSize.format(outcome.scan.redundantByteCountUpperBound)) redundant "
                    + "(upper bound), \(outcome.walk.inaccessiblePaths.count) unreadable directories"
            )
            return
        }

        let scratch = NSTemporaryDirectory() + "/duplicate-scan-\(getpid())"
        let manager = FileManager.default
        defer { try? manager.removeItem(atPath: scratch) }

        // A known answer: one group of three, one group of two, and several files that must not group.
        let big = Data((0..<400_000).map { UInt8($0 % 251) })
        let small = Data(repeating: 3, count: 900)
        var decoy = big
        decoy[399_999] = decoy[399_999] &+ 1  // same size as `big`, different last byte

        // A pair that the filesystem can hold and whose two orderings disagree, so this fixture has
        // teeth against a PathOrder-to-String regression.
        //
        //   firstByBytes  = "á.bin" written as a, U+0301  ->  61 cc 81 2e ...
        //   secondByBytes = "b.bin"                       ->  62 2e ...
        //
        // By bytes the decomposed name sorts first (0x61 < 0x62), which is what Python's sorted() over
        // Path does. Swift's `<` normalises to U+00E1 = 225 and compares against "b" = 98, putting "b"
        // first. An ASCII-only pair would agree under both and prove nothing -- the first version of this
        // fixture used one, and the teeth-proof caught it.
        //
        // The pair cannot be NFC-versus-NFD: measured on this machine, the case-insensitive boot volume
        // normalises a filename written as NFC into NFD, so /tmp cannot hold an NFC name at all. The
        // external case-sensitive volume does preserve NFC, which is why the real corpus contains both
        // forms -- 38 NFD-only and 10 NFC-only paths out of 71,580.
        let firstByBytes = "a\u{0301}.bin"
        let secondByBytes = "b.bin"

        let layout: [(String, Data)] = [
            ("a/one.bin", big),
            ("b/two.bin", big),
            ("c/deep/three.bin", big),
            ("decoy.bin", decoy),
            ("s/\(secondByBytes)", small),
            ("s/\(firstByBytes)", small),
            ("unique.bin", Data(repeating: 9, count: 77)),
            (".DS_Store", small),  // noise: must never appear, even though it matches `small`
        ]
        for (relative, payload) in layout {
            let path = scratch + "/" + relative
            try manager.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try payload.write(to: URL(filePath: path))
        }

        // Every width must produce the same bytes.
        var documents: Set<Data> = []
        var last: DuplicateFinder.Outcome?
        for width in [1, 2, 4, 8] {
            let outcome = try await finder.find(
                root: scratch,
                instant: instant,
                configuration: .init(concurrency: width)
            )
            documents.insert(try JSONWriter.document(DuplicateScanCodec.encode(outcome.scan)))
            last = outcome
        }
        try expect(
            documents.count == 1,
            "the document changed with the concurrency width (\(documents.count) variants)"
        )
        let outcome = try expectSome(last, "no scan ran")

        try expect(
            outcome.scan.groups.count == 2,
            "expected 2 groups, got \(outcome.scan.groups.count)"
        )
        // Largest first.
        try expect(outcome.scan.groups[0].size == 400_000, "group order or size is wrong")
        try expect(
            outcome.scan.groups[0].files.count == 3,
            "expected 3 members in the large group, got \(outcome.scan.groups[0].files.count)"
        )
        try expect(outcome.scan.groups[1].size == 900, "the small group's size is wrong")
        try expect(
            outcome.scan.groups[1].files.count == 2,
            "expected 2 members in the small group, got \(outcome.scan.groups[1].files.count)"
        )
        // Fails if the sort stops going through PathOrder: Swift's `String <` puts "b.bin" first.
        try expect(
            outcome.scan.groups[1].files[0].hasSuffix(firstByBytes),
            "the small group is not in byte order: "
                + outcome.scan.groups[1].files.map { ($0 as NSString).lastPathComponent }
                .joined(separator: ", ")
        )
        try expect(
            secondByBytes < firstByBytes,
            "the fixture no longer exercises the disagreement between byte and String order"
        )
        try expect(
            !outcome.scan.groups.contains { $0.files.contains { $0.hasSuffix(".DS_Store") } },
            ".DS_Store reached a group"
        )
        try expect(outcome.unreadable.isEmpty, "unreadable: \(outcome.unreadable)")

        // A saved scan must reload to the same bytes: that is what the app does when the user opens it
        // to review, minutes later.
        let encoded = try JSONWriter.document(DuplicateScanCodec.encode(outcome.scan))
        let reloaded = try DuplicateScanCodec.decode(JSONReader.parse(encoded))
        try expect(
            try JSONWriter.document(DuplicateScanCodec.encode(reloaded)) == encoded,
            "the scan did not survive a save and reload"
        )
        try expect(reloaded == outcome.scan, "the reloaded scan is not equal to the original")

        print(
            "  2 groups over 4 concurrency widths, byte-identical; "
                + "\(ByteSize.format(outcome.scan.redundantByteCountUpperBound)) redundant"
        )
    }

    // MARK: - menu

    /// Proves the hand-built menu has no duplicate keyboard shortcuts.
    ///
    /// Hand-assembled menus accumulate collisions silently: two items share a shortcut and only one
    /// ever fires. There is no compiler check and no runtime warning.
    ///
    /// Proof of teeth: give two items the same key equivalent and modifier mask and this fails.
    private static func checkMenu() throws {
        var seen: [String: String] = [:]
        func walk(_ menu: NSMenu, path: String) throws {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    let signature =
                        "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
                    if let owner = seen[signature] {
                        throw SelfTestFailure(
                            "shortcut \(item.keyEquivalent) is on both '\(owner)' and '\(item.title)'"
                        )
                    }
                    seen[signature] = item.title
                }
                if let submenu = item.submenu {
                    try walk(submenu, path: path + "/" + item.title)
                }
            }
        }
        let menu = MainMenuBuilder.build()
        try walk(menu, path: "")
        try expect(!seen.isEmpty, "the main menu has no keyboard shortcuts at all")
        print("  \(seen.count) distinct shortcuts")
    }

    // MARK: - helpers

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw SelfTestFailure(message) }
    }

    /// Unwraps or fails with a message, so a nil never turns into a silent skip.
    private static func expectSome<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw SelfTestFailure(message) }
        return value
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
