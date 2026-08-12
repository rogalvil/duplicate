import AppKit
// `@preconcurrency` on both, per the project rule: the macOS 15 SDK that CI compiles against lacks
// `Sendable` annotations the local SDK has, and the failure only appears there.
@preconcurrency import CoreGraphics
import DuplicateCore
import Foundation
@preconcurrency import ImageIO
import Synchronization

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

        // The catalogue, in the order `--mode all` runs them: cheap and structural first, so a broken
        // bundle fails in a second instead of after a Trash round-trip.
        let allModes = [
            "bundle", "state-dir", "l10n", "menu", "json-roundtrip", "scans", "digest",
            "walk-permissions", "trash-exclusion", "scan", "about", "icon", "cache", "storage",
            "trash", "undo", "review", "decisions", "gate", "library", "review-window", "preview",
            "fdlimit", "scan-window", "apply-window",
        ]

        let modes: [String]
        switch mode {
        case "all":
            modes = allModes
        case let name where !allModes.contains(name):
            // Naming the alternatives, because the usual way to get here is a typo and an error that
            // only says "unknown" makes the reader go read the source.
            print("FAILED: unknown selftest mode '\(name)'")
            print("  available: \(allModes.joined(separator: ", "))")
            return 1
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
                case "cache": try await checkHashCache(arguments: arguments)
                case "storage": try await checkStorageClasses(arguments: arguments)
                case "trash": try checkTrashRoundTrip()
                case "undo": try checkUndoCycle()
                case "review": try await checkReviewTriState()
                case "decisions": try checkRealDecisions(arguments: arguments)
                case "gate": try checkApplyGate()
                case "library": try await checkLibraryWindow()
                case "review-window": try await checkReviewWindow()
                case "preview": try await checkPreview()
                case "fdlimit": try checkDescriptorLimit()
                case "scan-window": try await checkScanWindow()
                case "apply-window": try await checkApplyWindow()
                case "about": try checkAbout()
                case "icon": try checkIcon()
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
        try checkKeysUsedInCode()
    }

    /// Proves the tables and the code agree, in both directions.
    ///
    /// The audit above compares the two tables against each other, which cannot catch either failure that
    /// actually ships:
    ///
    /// - **A typo in a `Strings.string("...")` call.** Both tables agree, the key is in neither, and the UI
    ///   displays `library.column.roo`. Nothing crashes and nothing looks wrong from inside the code.
    /// - **A key nobody asks for.** Dead weight, and usually a rename left half-done -- which means the
    ///   *other* half is a live call site pointing at a key that no longer exists.
    ///
    /// Two passes, because keys reach `Strings.string` two ways. Literal call sites are read directly. Keys
    /// passed through a variable -- the column titles are, they live in a table of `Column` values -- are
    /// covered by searching the sources for the key text instead, which does not care how it is passed.
    ///
    /// Scans the sources rather than the binary, so it needs the repository. Skips out loud when run from
    /// somewhere else: a check that quietly passes when it did nothing is worse than no check.
    ///
    /// Proof of teeth: misspell a key in any `Strings.string` call and the first assertion names it; add a
    /// key to both tables and use it nowhere and the second one does.
    private static func checkKeysUsedInCode() throws {
        let sources = "Sources/Duplicate"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sources) else {
            print("  SKIPPED: the key scan needs the repository as the working directory")
            return
        }
        guard let base = Strings.table(localization: "en") else {
            throw SelfTestFailure("en.lproj/Localizable.strings is missing from the bundle")
        }

        var text = ""
        for name in names.sorted() where name.hasSuffix(".swift") && name != "SelfTest.swift" {
            text += (try? String(contentsOfFile: sources + "/" + name, encoding: .utf8)) ?? ""
        }

        // Pass one: every literal call site names a key that exists.
        var literals: Set<String> = []
        var rest = Substring(text)
        while let call = rest.range(of: "Strings.string(\"") {
            rest = rest[call.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let literal = String(rest[..<end])
            // An interpolated key comes out of a literal scan as its source text. Skipped here and
            // enumerated below, because no literal scan can resolve it.
            if !literal.contains("\\(") { literals.insert(literal) }
            rest = rest[end...]
        }
        let unknown = literals.subtracting(base.keys).sorted()
        try expect(
            unknown.isEmpty,
            "used in code, absent from the tables: \(unknown.joined(separator: ", "))"
        )

        // Pass two: every declared key is referenced somewhere, however it is passed.
        var interpolated = Set(LibrarySort.allCases.map { "library.sort.\($0.rawValue)" })
        interpolated.formUnion(ScanPhase.allCases.map { "scan.phase.\($0)" })
        let unreferenced = base.keys
            .filter { !interpolated.contains($0) && !text.contains("\"\($0)\"") }
            .sorted()
        try expect(
            unreferenced.isEmpty,
            "declared and never referenced: \(unreferenced.joined(separator: ", "))"
        )

        // And every key really resolves, rather than falling back to its own name.
        for key in base.keys.sorted() {
            try expect(Strings.string(key) != key, "\(key) resolved to its own key")
        }
        print(
            "  \(literals.count) literal call sites and \(base.count) declared keys agree, "
                + "\(interpolated.count) built by interpolation"
        )
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

    // MARK: - cache

    /// Proves a warm scan reads nothing and answers identically.
    ///
    /// The cache is the largest performance decision in the app, and the one that matters most for the
    /// corpus it was built for: that corpus lives on an external volume, where the read is the expensive
    /// part by a wide margin. So the assertion is not "it is faster" -- it is **zero reads and the same
    /// bytes**, which is stronger and does not depend on how busy the machine is.
    ///
    /// - Note: `--dir <path>` runs the same two passes against a real tree, and reports the wall time of
    ///   each. Read-only apart from the cache file, which lives in `~/Library/Caches`.
    ///
    /// Proof of teeth: drop `withSize` back to rebuilding the entry from scratch -- the bug this mode
    /// found -- and the warm pass reads every file again.
    private static func checkHashCache(arguments: [String]) async throws {
        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 685054
        )
        let manager = FileManager.default

        // A cache file of its own, so a selftest never disturbs the one a real scan built.
        let cacheDirectory = NSTemporaryDirectory() + "/duplicate-cachetest-\(getpid())"
        defer { try? manager.removeItem(atPath: cacheDirectory) }
        try manager.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
        let cacheURL = URL(filePath: cacheDirectory).appending(
            path: "hashes.v1", directoryHint: .notDirectory
        )

        // The tree: a real directory when asked, otherwise a synthesized one with a known answer.
        var scratch: String?
        let root: String
        if let given = value(for: "--dir", in: arguments) {
            root = given
        } else {
            let path = NSTemporaryDirectory() + "/duplicate-cachetree-\(getpid())"
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
            scratch = path
            let payload = Data((0..<200_000).map { UInt8($0 % 251) })
            for index in 0..<8 {
                try payload.write(to: URL(filePath: path + "/g\(index).bin"))
            }
            try Data(repeating: 4, count: 5000).write(to: URL(filePath: path + "/unique.bin"))
            root = path
        }
        defer { if let scratch { try? manager.removeItem(atPath: scratch) } }

        let clock = ContinuousClock()

        let cold = HashCache(url: cacheURL)
        await cold.load()
        let coldStart = clock.now
        let first = try await DuplicateFinder().find(
            root: root,
            instant: instant,
            configuration: .init(cache: cold)
        )
        let coldElapsed = clock.now - coldStart
        let written = try await cold.persist()
        try expect(first.cacheHits == 0, "the cold pass had \(first.cacheHits) cache hits")

        // A tree whose files all have distinct sizes has no candidates, so there is nothing to hash and
        // nothing to cache. That is a legitimate answer, not a failure -- and asserting `written > 0`
        // here was wrong: it failed on a real 696-file directory that simply has no duplicates.
        let coldStats = await cold.statistics
        if written == 0 {
            try expect(
                coldStats.hits + coldStats.misses == 0,
                "nothing was cached even though \(coldStats.misses) candidates were hashed"
            )
            print("  \(root): no hash candidates, so nothing to cache")
            return
        }

        // A fresh instance, which is what another process would see.
        let warm = HashCache(url: cacheURL)
        await warm.load()
        try expect(
            await warm.report.isClean, "the cache did not reload cleanly: \(await warm.report)")
        let warmStart = clock.now
        let second = try await DuplicateFinder().find(
            root: root,
            instant: instant,
            configuration: .init(cache: warm)
        )
        let warmElapsed = clock.now - warmStart

        let coldDocument = try JSONWriter.document(DuplicateScanCodec.encode(first.scan))
        let warmDocument = try JSONWriter.document(DuplicateScanCodec.encode(second.scan))
        try expect(
            coldDocument == warmDocument,
            "the warm pass produced a different document (\(coldDocument.count) vs "
                + "\(warmDocument.count) bytes)"
        )

        let stats = await warm.statistics
        try expect(
            stats.misses == 0,
            "the warm pass missed \(stats.misses) of \(stats.hits + stats.misses) candidates"
        )
        if !first.scan.groups.isEmpty || first.cacheHits > 0 {
            try expect(second.cacheHits > 0, "the warm pass had no cache hits at all")
        }

        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
        }
        print(
            "  \(root == scratch ? "synthesized tree" : root): "
                + "\(second.cacheHits) hits, \(stats.misses) misses, "
                + "\(written) records written"
        )
        print(
            "  cold \(String(format: "%.3f", seconds(coldElapsed)))s  "
                + "warm \(String(format: "%.3f", seconds(warmElapsed)))s  "
                + "(\(String(format: "%.1f", seconds(coldElapsed) / max(seconds(warmElapsed), 1e-9)))x)"
        )
    }

    // MARK: - storage

    /// Proves the reclaimable figure counts storage, not files.
    ///
    /// Built against the real syscalls, because the whole thing rests on a fact that is easy to state and
    /// easy to get backwards: **copying a file on APFS produces a clone.** `FileManager.copyItem` and `cp`
    /// both go through `clonefile`, so a file duplicated in Finder shares storage with its original and
    /// removing it frees nothing. An app that counted files would claim bytes that `df` can prove it never
    /// returned.
    ///
    /// The tree here holds all four cases at once: a source, a `clonefile` clone, a `copyItem` copy, a
    /// `link(2)` hardlink, and one file whose bytes were written afresh. Only the last one is a second copy
    /// of the content.
    ///
    /// - Note: `--dir <path>` reports the same two figures for a real tree, and how far apart they are.
    ///
    /// Proof of teeth: make `StoragePartition.of` key on the path instead of the content identifier and
    /// the reclaimable figure jumps from one copy to four.
    private static func checkStorageClasses(arguments: [String]) async throws {
        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 6, minute: 47, second: 16, microsecond: 3
        )

        if let root = value(for: "--dir", in: arguments) {
            let outcome = try await DuplicateFinder().find(root: root, instant: instant)
            let scan = outcome.scan
            let shared = scan.groupsWithSharedStorage.count
            try expect(
                scan.reclaimableBytes <= scan.redundantByteCountUpperBound,
                "the honest figure exceeds its own upper bound"
            )
            print(
                "  \(root): \(scan.groups.count) groups, "
                    + "apparent \(ByteSize.format(scan.redundantByteCountUpperBound)), "
                    + "reclaimable \(ByteSize.format(scan.reclaimableBytes))"
                    + (scan.isReclaimExact ? " (exact)" : " (upper bound)")
            )
            print("  \(shared) group\(shared == 1 ? "" : "s") contain files that share storage")
            return
        }

        let manager = FileManager.default
        let scratch = NSTemporaryDirectory() + "/duplicate-storage-\(getpid())"
        defer { try? manager.removeItem(atPath: scratch) }
        try manager.createDirectory(atPath: scratch, withIntermediateDirectories: true)

        let supportsCloning =
            (try? URL(filePath: scratch).resourceValues(
                forKeys: [.volumeSupportsFileCloningKey]
            ).volumeSupportsFileCloning) ?? false
        guard supportsCloning else {
            // An explicit skip, not a silent pass: without cloning the distinction cannot be observed, so
            // every assertion below would hold for the wrong reason.
            print("  SKIPPED: \(scratch) is on a volume that cannot clone")
            return
        }

        let payload = Data((0..<8192).map { UInt8($0 % 251) })
        let source = scratch + "/source.bin"
        try payload.write(to: URL(filePath: source))
        // Written afresh, which is the only way to get a genuinely second copy on APFS.
        try payload.write(to: URL(filePath: scratch + "/independent.bin"))
        let clone = scratch + "/clone.bin"
        let rc = source.withCString { s in clone.withCString { c in clonefile(s, c, 0) } }
        try expect(rc == 0, "clonefile failed with errno \(errno)")
        try manager.copyItem(atPath: source, toPath: scratch + "/copied.bin")
        try manager.linkItem(atPath: source, toPath: scratch + "/hardlink.bin")

        let outcome = try await DuplicateFinder().find(
            root: scratch,
            instant: instant,
            configuration: .init(concurrency: 2)
        )
        let group = try expectSome(outcome.scan.groups.first, "no group was found")
        try expect(group.files.count == 5, "expected 5 members, got \(group.files.count)")
        try expect(group.isReclaimExact, "the volume reported no content identifiers")

        // Five files, two distinct copies of the content: source+clone+copied+hardlink share one, and
        // independent.bin is the other. So exactly one copy is reclaimable.
        let partition = try expectSome(group.storage, "the group carries no partition")
        try expect(
            partition.distinctCopies == 2,
            "expected 2 distinct copies, got \(partition.distinctCopies): \(partition.clusters)"
        )
        try expect(
            group.reclaimableBytes == 8192,
            "reclaimable is \(group.reclaimableBytes), expected 8192"
        )
        try expect(
            group.redundantByteCountUpperBound == 8192 * 4,
            "the file-counting figure changed: \(group.redundantByteCountUpperBound)"
        )

        // And the removal set never contains a second name for the storage being kept.
        let removals = group.removalCandidates(keeping: source)
        try expect(removals.count == 1, "removal set is \(removals)")
        try expect(
            removals[0].hasSuffix("/independent.bin"),
            "the removal set names \(removals[0]), which shares storage with the keeper"
        )
        try expect(
            group.storageSiblings(of: source).count == 3,
            "expected 3 storage siblings, got \(group.storageSiblings(of: source))"
        )

        print(
            "  5 files, 2 distinct copies: apparent "
                + "\(ByteSize.format(group.redundantByteCountUpperBound)), reclaimable "
                + "\(ByteSize.format(group.reclaimableBytes))"
        )
        print(
            "  copyItem and cp both clone on APFS, so only the freshly written file is a second copy"
        )
    }

    // MARK: - trash

    /// Proves a file can be sent to the real Trash, found again, and read back byte-identical.
    ///
    /// The destructive path is the riskiest thing in the app and the only part with no second chance, so it
    /// is exercised against the real `FileManager.trashItem` rather than a stub. Measured on this machine,
    /// every mounted volume accepts it: the boot volume and `$HOME` land in `~/.Trash`, and both external
    /// APFS volumes land in `<volume>/.Trashes/<uid>`. The plan's largest open risk was that the external
    /// volume holding the real corpus would be exFAT, where `trashItem` fails outright -- it is not.
    ///
    /// Everything this mode creates, it removes, including the trashed copy. A selftest must not leave
    /// debris in the user's Trash.
    ///
    /// Proof of teeth: make `TrashDisposer` ignore the `resultingItemURL` and return the original path, and
    /// the read-back assertion fails -- which is the difference between "the file moved" and "the file can
    /// be put back".
    private static func checkTrashRoundTrip() throws {
        let manager = FileManager.default
        let scratch = NSTemporaryDirectory() + "/duplicate-trash-\(getpid())"
        defer { try? manager.removeItem(atPath: scratch) }
        try manager.createDirectory(atPath: scratch, withIntermediateDirectories: true)

        let hasher = ContentHasher()
        let payload = Data((0..<3000).map { UInt8($0 % 251) })
        let path = scratch + "/doomed.bin"
        try payload.write(to: URL(filePath: path))
        let before = try hasher.fullDigest(atPath: path)

        // Verification first, which is the order production uses: nothing is moved until its content still
        // matches what the scan recorded.
        let verifying = VerifyingDisposer(
            wrapping: TrashDisposer(),
            hasher: hasher,
            expected: [path: before.digest]
        )
        let outcome = try verifying.dispose(path: path)
        defer { try? manager.removeItem(atPath: outcome.resultingPath) }

        try expect(outcome.mechanism == .trash, "mechanism was \(outcome.mechanism)")
        try expect(!manager.fileExists(atPath: path), "the original is still at \(path)")
        try expect(
            manager.fileExists(atPath: outcome.resultingPath),
            "nothing at the reported destination \(outcome.resultingPath)"
        )
        let after = try hasher.fullDigest(atPath: outcome.resultingPath)
        try expect(
            after.digest == before.digest,
            "the trashed file is not byte-identical: \(after.digest.hexString) vs "
                + "\(before.digest.hexString)"
        )
        try expect(after.byteCount == before.byteCount, "the size changed")

        // And a file whose content no longer matches is refused, not moved.
        let changed = scratch + "/changed.bin"
        try payload.write(to: URL(filePath: changed))
        let stale = VerifyingDisposer(
            wrapping: TrashDisposer(),
            hasher: hasher,
            expected: [changed: Digest32(hexString: String(repeating: "0", count: 64))!]
        )
        var refused = false
        do {
            _ = try stale.dispose(path: changed)
        } catch DisposalError.contentChanged {
            refused = true
        }
        try expect(refused, "a file whose digest did not match was still moved")
        try expect(
            manager.fileExists(atPath: changed),
            "the refused file was moved anyway"
        )

        // The quarantine fallback, forced, with a collision already in place.
        let quarantine = scratch + "/quarantine"
        let session = quarantine + "/20260511-064716-000001"
        try manager.createDirectory(atPath: session, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: URL(filePath: session + "/fallback.bin"))
        let occupiedDigest = try hasher.fullDigest(atPath: session + "/fallback.bin")

        let fallbackSource = scratch + "/fallback.bin"
        try payload.write(to: URL(filePath: fallbackSource))
        let fallback = FallbackDisposer(
            primary: RefusingDisposer(),
            secondary: QuarantineDisposer(root: quarantine, sessionID: "20260511-064716-000001")
        )
        let quarantined = try fallback.dispose(path: fallbackSource)
        try expect(quarantined.mechanism == .quarantine, "the fallback did not engage")
        try expect(
            quarantined.resultingPath == session + "/fallback-2.bin",
            "collision resolved as \(quarantined.resultingPath)"
        )
        // The file that was already there must be untouched: overwriting on the recovery path is the worst
        // place for it.
        try expect(
            try hasher.fullDigest(atPath: session + "/fallback.bin").digest
                == occupiedDigest.digest,
            "the pre-existing quarantined file was overwritten"
        )

        print("  trashed to \((outcome.resultingPath as NSString).deletingLastPathComponent)")
        print(
            "  read back byte-identical; verification refused a changed file; fallback renamed on collision"
        )
    }

    // MARK: - undo

    /// Creates files, trashes them, journals it, undoes it, and asserts every file came back identical.
    ///
    /// The whole promise of the destructive path in one pass, against the real Trash and a real journal on
    /// disk. Two assertions carry it:
    ///
    /// - **Every file is back at its original path with its original bytes.** Without this, "you can undo
    ///   this" is a claim nobody checked.
    /// - **An occupied original path is never overwritten.** A user who saved new work at one of those
    ///   paths and then undid the session must not lose it. This is the worst bug the design permits, so it
    ///   is asserted here rather than only in a unit test.
    ///
    /// Everything created is removed, including anything left in the Trash.
    ///
    /// Proof of teeth: remove the `fileExists` guard from `UndoRunner.run` and the second half fails with
    /// the user's new file gone.
    private static func checkUndoCycle() throws {
        let manager = FileManager.default
        let hasher = ContentHasher()
        let sessionID = "20260511-070000-000001"

        let scratch = NSTemporaryDirectory() + "/duplicate-undo-\(getpid())"
        defer { try? manager.removeItem(atPath: scratch) }
        try manager.createDirectory(atPath: scratch + "/tree", withIntermediateDirectories: true)

        // A state directory of its own, so the real journal directory is never written to.
        let state = StateDirectory(
            environment: ["XDG_STATE_HOME": scratch + "/state"],
            homePath: NSHomeDirectory()
        )

        // Four files, and a manifest of what they must look like afterwards.
        var expected: [String: Digest32] = [:]
        var entries: [JournalEntry] = []
        var trashed: [String] = []
        for index in 0..<4 {
            let path = scratch + "/tree/file-\(index).bin"
            let payload = Data((0..<(600 + index * 100)).map { UInt8(($0 + index) % 251) })
            try payload.write(to: URL(filePath: path))
            let digest = try hasher.fullDigest(atPath: path)
            expected[path] = digest.digest

            let outcome = try VerifyingDisposer(
                wrapping: TrashDisposer(),
                hasher: hasher,
                expected: [path: digest.digest]
            ).dispose(path: path)
            trashed.append(outcome.resultingPath)
            entries.append(
                JournalEntry(
                    originalPath: outcome.originalPath,
                    resultingPath: outcome.resultingPath,
                    mechanism: outcome.mechanism,
                    byteCount: outcome.byteCount,
                    digest: digest.digest,
                    groupKey: "\(digest.byteCount):\(digest.digest.hexString)",
                    scanID: "20260511-064716-685054",
                    timestamp: "2026-05-11T06:47:16.685054Z"
                )
            )
        }
        defer { for path in trashed { try? manager.removeItem(atPath: path) } }

        try expect(
            try MoveJournal.append(entries, sessionID: sessionID, in: state) == 4,
            "the journal did not record four entries"
        )
        for path in expected.keys {
            try expect(!manager.fileExists(atPath: path), "\(path) was not removed")
        }

        // Reload from disk, which is what the app does when the user opens the history later.
        let loaded = try MoveJournal.load(sessionID: sessionID, in: state)
        try expect(loaded.isClean, "the journal did not reload cleanly: \(loaded.malformedLines)")
        try expect(loaded.entries.count == 4, "reloaded \(loaded.entries.count) entries")

        let plan = UndoPlanner.plan(
            sessionID: sessionID,
            entries: loaded.entries,
            restoredPaths: loaded.restoredPaths,
            environment: .live(hasher: hasher)
        )
        try expect(!plan.isNoOp, "the plan would restore nothing")
        try expect(
            plan.restorable.count == 4,
            "\(plan.restorable.count) restorable, blocked: \(plan.obstacleCounts)"
        )

        let report = UndoRunner().run(plan)
        try expect(report.failed.isEmpty, "failures: \(report.failed.map(\.reason))")
        try expect(report.restored.count == 4, "restored \(report.restored.count)")

        for (path, digest) in expected {
            try expect(manager.fileExists(atPath: path), "\(path) did not come back")
            let fresh = try hasher.fullDigest(atPath: path)
            try expect(
                fresh.digest == digest,
                "\((path as NSString).lastPathComponent) came back with different bytes"
            )
        }

        // Now the case that must never go wrong: undo again, with new work saved where a file used to be.
        let occupied = scratch + "/tree/file-0.bin"
        let newWork = Data("something the user wrote after the apply".utf8)
        let second = try VerifyingDisposer(
            wrapping: TrashDisposer(),
            hasher: hasher,
            expected: [occupied: expected[occupied]!]
        ).dispose(path: occupied)
        defer { try? manager.removeItem(atPath: second.resultingPath) }
        try newWork.write(to: URL(filePath: occupied))

        let conflictEntry = JournalEntry(
            originalPath: second.originalPath,
            resultingPath: second.resultingPath,
            mechanism: second.mechanism,
            byteCount: second.byteCount,
            digest: expected[occupied]!,
            groupKey: "x",
            scanID: "20260511-064716-685054",
            timestamp: "2026-05-11T06:47:16.685054Z"
        )
        let conflictPlan = UndoPlanner.plan(
            sessionID: sessionID,
            entries: [conflictEntry],
            environment: .live(hasher: hasher)
        )
        try expect(
            conflictPlan.obstacleCounts[.originalPathOccupied] == 1,
            "expected an occupied-path obstacle, got \(conflictPlan.obstacleCounts)"
        )
        try expect(conflictPlan.isNoOp, "the planner offered to overwrite the user's file")
        // And running it anyway changes nothing.
        let refused = UndoRunner().run(conflictPlan)
        try expect(refused.restored.isEmpty, "the runner restored over an occupied path")
        try expect(
            try Data(contentsOf: URL(filePath: occupied)) == newWork,
            "the user's new file was overwritten"
        )

        print("  4 files trashed, journalled, restored byte-identical")
        print("  a second undo over occupied work was refused, and the work survived")
    }

    // MARK: - review

    /// Proves a partly reviewed scan saves only what was reviewed.
    ///
    /// This is the fix for the most dangerous defect the port inherited. The CLI's `decisions()` writes an
    /// entry for **every** group, including ones the user never opened, filled in with the heuristic's guess
    /// (`src/rav/core/duplicate_review.py:152-157`). Quit after group 1 of 50 and the file records decisions
    /// for 49 groups; apply then acts on all of them. In a terminal that needs a deliberate `q`. In a window,
    /// quitting is closing a window.
    ///
    /// The assertion is a count: review one group of fifty, and the saved document has exactly one key. It
    /// also checks the other direction -- that a document written this way is still readable by the CLI's
    /// rules, because absence is the contract both tools rely on.
    ///
    /// Proof of teeth: make `decisionsForSaving` fall back to `effectiveKeep` for undecided groups -- the
    /// CLI's behaviour -- and the count jumps to fifty.
    private static func checkReviewTriState() async throws {
        let manager = FileManager.default
        let scratch = NSTemporaryDirectory() + "/duplicate-review-\(getpid())"
        defer { try? manager.removeItem(atPath: scratch) }
        try manager.createDirectory(atPath: scratch + "/tree", withIntermediateDirectories: true)

        // Fifty groups of two, from a real scan so the group keys are real content identities.
        for index in 0..<50 {
            let payload = Data(repeating: UInt8(index % 251), count: 400 + index)
            try manager.createDirectory(
                atPath: scratch + "/tree/g\(index)",
                withIntermediateDirectories: true
            )
            for name in ["a.bin", "b.bin"] {
                try payload.write(to: URL(filePath: scratch + "/tree/g\(index)/" + name))
            }
        }

        let instant = ScanIdentifier.Instant(
            year: 2026, month: 5, day: 11, hour: 7, minute: 0, second: 0, microsecond: 1
        )
        let outcome = try await DuplicateFinder().find(
            root: scratch + "/tree",
            instant: instant,
            configuration: .init(concurrency: 4)
        )
        try expect(
            outcome.scan.groups.count == 50,
            "expected 50 groups, got \(outcome.scan.groups.count)"
        )

        var state = ExactReviewState(scan: outcome.scan, root: scratch + "/tree")
        try expect(
            state.decisionsForSaving.isEmpty,
            "an untouched review already had \(state.decisionsForSaving.count) decisions"
        )
        try expect(state.removalPlan.isEmpty, "an untouched review already had a removal plan")

        // Review exactly one group, then stop -- the shape of closing a window.
        let confirmed = state.confirm()
        try expect(confirmed == .advanced, "confirming the first group returned \(confirmed)")

        let saved = state.decisionsForSaving
        try expect(
            saved.count == 1,
            "reviewed 1 of 50 groups but saved \(saved.count) decisions"
        )
        let tally = state.tally
        try expect(
            tally == (decided: 1, skipped: 0, undecided: 49),
            "tally is \(tally)"
        )
        try expect(
            state.removalPlan.count == 1,
            "the removal plan covers \(state.removalPlan.count) groups"
        )

        // And the document that gets written holds one key, in the shape the CLI reads.
        let document = DecisionsCodec.document(from: state, instant: instant)
        let data = try JSONWriter.document(DecisionsCodec.encode(document))
        let reloaded = try DecisionsCodec.decode(JSONReader.parse(data))
        try expect(
            reloaded.decisions.count == 1,
            "the saved document holds \(reloaded.decisions.count) keys")
        try expect(
            try JSONWriter.document(DecisionsCodec.encode(reloaded)) == data,
            "the decisions document did not survive a round trip"
        )

        // Reopening it restores the one decision and leaves the other 49 undecided.
        let reopened = ExactReviewState(
            scan: outcome.scan,
            root: scratch + "/tree",
            priorDecisions: reloaded.byKey
        )
        try expect(
            reopened.tally == (decided: 1, skipped: 0, undecided: 49),
            "after reopening, the tally is \(reopened.tally)"
        )

        // Skipping is recorded as neither, so the UI can tell "you skipped these" from "you never looked".
        var skipping = state
        let skipped = skipping.skip()
        try expect(skipped == .advanced, "skip returned \(skipped)")
        try expect(
            skipping.decisionsForSaving.count == 1,
            "a skip added a decision: \(skipping.decisionsForSaving.count)"
        )
        try expect(skipping.tally == (decided: 1, skipped: 1, undecided: 48), "\(skipping.tally)")

        print("  reviewed 1 of 50 groups; saved exactly 1 decision, 49 left undecided")
        print("  a skip is recorded as neither decided nor unseen")
    }

    // MARK: - decisions

    /// Reads every decisions document the CLI wrote, through the app's codec, and re-encodes it.
    ///
    /// A gap I named in a previous change and left open: the decisions round-trip was proven only against a
    /// synthesized fixture, while this machine holds 55 files the CLI really wrote. Cheap to check, so there
    /// was no reason not to.
    ///
    /// Read-only.
    ///
    /// Proof of teeth: drop `created_at` from the encoder and every document differs.
    private static func checkRealDecisions(arguments: [String]) throws {
        let state = StateDirectory.current()
        let root = value(for: "--dir", in: arguments) ?? state.path(for: .decisions)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else {
            print("  SKIPPED: \(root) is not readable")
            return
        }

        var decoded = 0
        var keys = 0
        var emptyKeepLists = 0
        var failures: [String] = []

        for name in names.sorted() where name.hasSuffix(".json") {
            let path = root + "/" + name
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            do {
                let document = try DecisionsCodec.decode(JSONReader.parse(data))
                let reencoded = try JSONWriter.document(DecisionsCodec.encode(document))
                guard reencoded == data else {
                    let offset = zip(data, reencoded).enumerated()
                        .first { $0.element.0 != $0.element.1 }?.offset
                    failures.append(
                        "\(name): differs at byte \(offset.map(String.init) ?? "the end")"
                    )
                    continue
                }
                guard name == document.scanID + ".json" else {
                    failures.append("\(name): holds scan_id \(document.scanID)")
                    continue
                }
                decoded += 1
                keys += document.decisions.count
                emptyKeepLists += document.decisions.filter { $0.keptPaths.isEmpty }.count
            } catch {
                failures.append("\(name): \(error)")
            }
        }

        guard failures.isEmpty else {
            throw SelfTestFailure(
                "\(failures.count) of \(decoded + failures.count) documents failed:\n    "
                    + failures.prefix(10).joined(separator: "\n    ")
            )
        }
        if decoded == 0 {
            print("  SKIPPED: no decisions documents in \(root)")
        } else {
            print("  \(decoded) decisions documents re-encoded byte-identically")
            print(
                "  \(keys) decision keys, \(emptyKeepLists) with an empty keep list "
                    + "(the CLI's keep-none, which it then ignores)"
            )
        }
    }

    // MARK: - gate

    /// Proves nothing can be applied without a current dry run.
    ///
    /// The invariant the CLI enforces implicitly, in the branches of its command loop. Here Core owns it, and
    /// this mode checks the three ways around it that a UI could otherwise take: applying with no dry run at
    /// all, applying after editing a decision, and applying a plan that differs from the one shown.
    ///
    /// Proof of teeth: make `ApplyGate.authorize` ignore its fingerprint argument and the second assertion
    /// fails.
    private static func checkApplyGate() throws {
        let digest = Digest32(hexString: String(repeating: "a", count: 64))!
        let groups = (0..<3).map { index in
            DuplicateGroup(
                size: 1000,
                digest: Digest32(hexString: String(repeating: "\(index)", count: 64))!,
                files: ["/root/\(index)/a", "/root/\(index)/b"]
            )
        }
        _ = digest
        let scan = DuplicateScan(
            scanID: "20260511-064716-685054",
            root: "/root",
            createdAt: "2026-05-11T06:47:16.685054Z",
            groups: groups
        )
        var state = ExactReviewState(scan: scan, root: "/root")
        var flow = ReviewFlow()

        // No dry run: refused.
        let firstPlan = ApplyGate.fingerprint(of: state.removalPlan)
        try expectThrows("applying with no dry run") {
            try ApplyGate.authorize(flow: flow, fingerprint: firstPlan)
        }
        try expect(!flow.isAvailable(.apply), "apply was offered before any dry run")
        try expect(!flow.isAvailable(.dryRun), "a dry run was offered with nothing decided")

        // Decide something, then simulate.
        _ = state.confirm()
        flow.decisionsChanged(hasAny: !state.decisionsForSaving.isEmpty)
        try expect(flow.isAvailable(.dryRun), "a dry run was not offered after deciding")
        let planned = ApplyGate.fingerprint(of: state.removalPlan)
        _ = flow.advance(.dryRun, fingerprint: planned)
        try expect(flow.step == .dryRunDone, "the flow is at \(flow.step)")
        try expect(flow.isAvailable(.apply), "apply was not offered after a dry run")
        try ApplyGate.authorize(flow: flow, fingerprint: planned)

        // Edit a decision afterwards: the approved plan is stale, so apply is refused again.
        _ = state.confirm()
        flow.decisionsChanged(hasAny: true)
        let changed = ApplyGate.fingerprint(of: state.removalPlan)
        try expect(changed != planned, "the fingerprint did not change with the plan")
        try expectThrows("applying after editing a decision") {
            try ApplyGate.authorize(flow: flow, fingerprint: changed)
        }
        try expect(!flow.isAvailable(.apply), "apply survived an edit")

        // And a plan that differs from the one shown is refused even at the right step.
        _ = flow.advance(.dryRun, fingerprint: changed)
        try expectThrows("applying a plan other than the one shown") {
            try ApplyGate.authorize(flow: flow, fingerprint: planned)
        }
        try ApplyGate.authorize(flow: flow, fingerprint: changed)

        print(
            "  apply refused with no dry run, after an edit, and for a plan that was not the one shown"
        )
    }

    /// Runs `body` and fails unless it throws.
    private static func expectThrows(_ what: String, _ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            return
        }
        throw SelfTestFailure("\(what) was allowed")
    }

    // MARK: - library

    /// Drives the real library window against a synthesized state directory.
    ///
    /// A unit test cannot reach this: `Duplicate` is an executable target and SwiftPM will not let the test
    /// target import it. So the window controller is built here, for real, and read back through the same
    /// `tableView(_:viewFor:row:)` that draws it -- not through a second copy of the formatting rules,
    /// which would pass while the window showed something else.
    ///
    /// What it asserts, in order: the rows come back newest first; a scan whose reclaimable figure is an
    /// upper bound is labelled as one; a scan with a decisions file shows it; a scan with relative paths is
    /// flagged rather than silently offered; sorting and filtering reach the table; the footer and the empty
    /// state render sentences rather than key literals; and **a scan appearing on disk lands in the table
    /// without anyone asking**, which is the whole point of the window.
    ///
    /// Writes only to a temp directory. The user's real state directory is never opened.
    ///
    /// Proof of teeth: in `reloadRows`, drop the `rows =` assignment and the row count fails; make
    /// `startWatching` watch only `.scans` and the decisions half of the live-update assertion fails.
    @MainActor
    private static func checkLibraryWindow() async throws {
        let root = NSTemporaryDirectory() + "duplicate-selftest-library-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)

        func group(_ seed: String, size: Int64, files: [String]) -> DuplicateGroup {
            DuplicateGroup(
                size: size,
                digest: Digest32(hexString: String(repeating: seed, count: 64))!,
                files: files
            )
        }

        // Newest, with two groups and an inexact figure.
        try store.save(
            DuplicateScan(
                scanID: "20260511-064716-685054",
                root: "/Volumes/WD12TB/Fotos",
                createdAt: "2026-05-11T06:47:16.685054Z",
                groups: [
                    group(
                        "a", size: 2048,
                        files: ["/Volumes/WD12TB/Fotos/a", "/Volumes/WD12TB/Fotos/b"]),
                    group(
                        "b", size: 1024,
                        files: ["/Volumes/WD12TB/Fotos/c", "/Volumes/WD12TB/Fotos/d"]),
                ]
            )
        )
        // Older, already reviewed.
        let reviewed = DuplicateScan(
            scanID: "20260101-000000-000000",
            root: "/Users/tester/Descargas",
            createdAt: "2026-01-01T00:00:00.000000Z",
            groups: [
                group(
                    "c", size: 512,
                    files: ["/Users/tester/Descargas/x", "/Users/tester/Descargas/y"])
            ]
        )
        try store.save(reviewed)
        try store.save(
            DecisionsDocument(
                scanID: reviewed.scanID,
                createdAt: "2026-01-01T00:10:00.000000Z",
                decisions: [(reviewed.groups[0].key, ["/Users/tester/Descargas/x"])]
            )
        )
        // Oldest, with relative paths, which cannot be acted on.
        try store.save(
            DuplicateScan(
                scanID: "20250101-235959-999999",
                root: "sub",
                createdAt: "2025-01-01T23:59:59.999999Z",
                groups: [group("d", size: 64, files: ["sub/a", "sub/b"])]
            )
        )

        let controller = LibraryWindowController(stateDirectory: state)
        defer { controller.close() }

        // The read is off the main thread, so the table starts empty. That is the point -- a window that
        // stalls for a third of a second before it draws feels broken -- and it is asserted rather than
        // assumed, because a synchronous load would still pass every check below.
        try expect(
            controller.displayedRowCount == 0, "the window read the directory before drawing")
        try expect(
            controller.emptyStateText == nil, "the empty state flashed before the first read")
        try await waitOnMainActor(
            until: { controller.hasFinishedFirstLoad },
            what: "the first read to finish"
        )

        try expect(
            controller.displayedRowCount == 3, "\(controller.displayedRowCount) rows, wanted 3")
        try expect(controller.watcherCount == 2, "\(controller.watcherCount) watchers, wanted 2")

        // Newest first, and the root column shows the root.
        try expect(
            controller.displayedValue(row: 0, column: "root") == "/Volumes/WD12TB/Fotos",
            "row 0 root was \(controller.displayedValue(row: 0, column: "root") ?? "nil")"
        )
        try expect(
            controller.displayedValue(row: 2, column: "root") == "sub",
            "row 2 root was \(controller.displayedValue(row: 2, column: "root") ?? "nil")"
        )
        try expect(controller.displayedValue(row: 0, column: "groups") == "2", "group count")
        try expect(controller.displayedValue(row: 0, column: "files") == "4", "file count")

        // 3072 bytes over two groups with no storage partition: an upper bound, and labelled as one.
        let reclaim = controller.displayedValue(row: 0, column: "reclaim") ?? ""
        try expect(
            reclaim == "\u{2264} " + ByteSize.format(3072),
            "reclaimable read \(reclaim), wanted a labelled upper bound"
        )

        // The date column is locale-aware, so the exact text is not asserted -- only that it parsed the
        // identifier rather than falling back to the raw timestamp.
        let created = controller.displayedValue(row: 0, column: "created") ?? ""
        try expect(!created.isEmpty, "the created column is empty")
        try expect(
            created != "2026-05-11T06:47:16.685054Z",
            "the created column fell back to the raw timestamp"
        )

        let reviewedState = controller.displayedValue(row: 1, column: "state") ?? ""
        try expect(
            reviewedState == Strings.string("library.state.reviewed"),
            "the reviewed scan shows \(reviewedState)"
        )
        try expect(
            controller.displayedValue(row: 2, column: "state")
                == Strings.string("library.state.relativePaths"),
            "the relative-path scan is not flagged"
        )
        try expect(
            controller.displayedValue(row: 0, column: "state") == "", "an unreviewed scan is marked"
        )

        // The footer is a sentence, not a key.
        try expect(
            !controller.footerText.contains("library.footer"), "the footer shows a key literal")
        try expect(controller.footerText.contains("3"), "the footer omits the scan count")

        // Sorting and filtering reach the table.
        controller.applyForSelftest(sort: .mostGroups, filter: "")
        try expect(
            controller.displayedValue(row: 0, column: "root") == "/Volumes/WD12TB/Fotos",
            "sorting by group count did not reach the table"
        )
        controller.applyForSelftest(sort: .newest, filter: "descargas")
        try expect(
            controller.displayedRowCount == 1, "the filter matched \(controller.displayedRowCount)")
        try expect(
            controller.displayedValue(row: 0, column: "root") == "/Users/tester/Descargas",
            "the filter kept the wrong row"
        )
        controller.applyForSelftest(sort: .newest, filter: "no such folder")
        try expect(controller.displayedRowCount == 0, "an impossible filter matched something")
        try expect(
            controller.emptyStateText == Strings.string("library.empty.filtered"),
            "the filtered empty state reads \(controller.emptyStateText ?? "nil")"
        )
        controller.applyForSelftest(sort: .newest, filter: "")

        // **The point of the window**: a scan written by another process appears without being asked.
        try store.save(
            DuplicateScan(
                scanID: "20260812-120000-000000",
                root: "/Users/tester/Nuevo",
                createdAt: "2026-08-12T12:00:00.000000Z",
                groups: [
                    group("e", size: 16, files: ["/Users/tester/Nuevo/a", "/Users/tester/Nuevo/b"])
                ]
            )
        )
        try await waitOnMainActor(
            until: { controller.displayedRowCount == 4 },
            what: "a new scan to reach the table"
        )
        try expect(controller.emptyStateText == nil, "the empty state is showing with 4 rows")
        try expect(
            controller.displayedValue(row: 0, column: "root") == "/Users/tester/Nuevo",
            "the new scan is not at the top"
        )

        // And a decisions file appearing beside a scan updates its state, which is the second watcher.
        try store.save(
            DecisionsDocument(
                scanID: "20260812-120000-000000",
                createdAt: "2026-08-12T12:01:00.000000Z",
                decisions: [("16:" + String(repeating: "e", count: 64), ["/Users/tester/Nuevo/a"])]
            )
        )
        try await waitOnMainActor(
            until: {
                controller.displayedValue(row: 0, column: "state")
                    == Strings.string("library.state.reviewed")
            },
            what: "a decisions file to change the state column"
        )

        print("  4 scans listed, sorted, filtered; upper bound and review state labelled")
        print("  a scan and a decisions file written by another writer both reached the table")

        try measureRealCorpusLoad()
    }

    /// Times the read the window pays on open, against the real corpus.
    ///
    /// Read-only, and skipped out loud when there is no corpus. The assertion is on completeness, not on
    /// the clock: a wall-time bound would be flaky on a loaded machine and on CI. The number is printed so
    /// a regression is visible in a PR body.
    private static func measureRealCorpusLoad() throws {
        let store = ScanStore(state: .current())
        let identifiers = store.identifiers(in: .scans)
        guard !identifiers.isEmpty else {
            print("  SKIPPED: no real corpus to time")
            return
        }
        let start = ContinuousClock.now
        let library = ScanLibrary(store: store)
        let elapsed = ContinuousClock.now - start
        try expect(
            library.summaries.count == identifiers.count,
            "\(identifiers.count) scans on disk but \(library.summaries.count) decoded"
        )
        let totals = library.totals
        print(
            "  real corpus: \(identifiers.count) scans, \(totals.groupCount) groups read in "
                + "\(elapsed)"
        )
    }

    /// Spins the run loop until `condition` holds, or fails naming what it waited for.
    ///
    /// The watcher reports on its own queue and hops to the main actor, so the update cannot arrive while
    /// this function blocks the main thread -- `Task.sleep` yields, which is what lets the hop land.
    @MainActor
    private static func waitOnMainActor(
        until condition: @MainActor () -> Bool,
        what: String,
        deadline: Duration = .seconds(5)
    ) async throws {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        throw SelfTestFailure("timed out after \(deadline) waiting for \(what)")
    }

    // MARK: - review-window

    /// Drives the real review window, and checks what it has to be honest about.
    ///
    /// Built for real against a state directory in `/tmp`, over a **real tree of real files**, and read back
    /// through the same cell-building code the window draws with. A unit test cannot reach any of this:
    /// `Duplicate` is an executable target and the test target cannot import it.
    ///
    /// Real files rather than invented paths, and that is not incidental: the window now checks the
    /// filesystem, so a fixture of paths that do not exist would make it report a stale group -- correctly
    /// -- and every assertion about the ordinary path would be racing that answer.
    ///
    /// The assertions, in order of how much they matter:
    ///
    /// 1. **An unvisited group is not a decision.** The heuristic's mark is a preview, the warning says so,
    ///    and saving writes nothing for it. This is the CLI's most dangerous defect, and in a window it is
    ///    worse: quitting is closing a window.
    /// 2. **A file sharing the keeper's storage is not offered.** Its checkbox is disabled and its note
    ///    says why -- trashing it would free nothing, and a tool caught claiming otherwise is not believed
    ///    about anything else.
    /// 3. **Keeping nothing is refused, not treated as an exit.** The CLI's TUI reads that condition as
    ///    "we are done" and quits the review.
    ///
    /// Plus: undo restores a decision, skip is neither decided nor unseen, the saved file holds exactly the
    /// decided groups, and the preview pane names the file under the cursor.
    ///
    /// Writes only under `/tmp`. The user's own decisions are never opened.
    ///
    /// Proof of teeth: five separate breaks, each listed beside its assertion.
    @MainActor
    private static func checkReviewWindow() async throws {
        let root = NSTemporaryDirectory() + "duplicate-selftest-review-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)

        let tree = root + "/tree"
        func make(_ relative: String, bytes: Int) throws -> String {
            let path = tree + "/" + relative
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: URL(filePath: path))
            return path
        }
        func digest(_ seed: String) -> Digest32 {
            Digest32(hexString: String(repeating: seed, count: 64))!
        }

        let fotoA = try make("fotos/a.jpg", bytes: 4096)
        let fotoB = try make("fotos/sub/a.jpg", bytes: 4096)
        let docA = try make("docs/b.pdf", bytes: 2048)
        let docLink = try make("docs/b-link.pdf", bytes: 2048)
        let docOther = try make("docs/otro/b.pdf", bytes: 2048)
        let copyA = try make("x/copia de c.txt", bytes: 512)
        let copyB = try make("x/deep/c.txt", bytes: 512)

        // Group 0: two independent copies under one folder.
        // Group 1: three files where the second is the keeper's own storage under another name.
        // Group 2: two copies, one with a copy-looking name.
        let scan = DuplicateScan(
            scanID: "20260812-120000-000000",
            root: tree,
            createdAt: "2026-08-12T12:00:00.000000Z",
            groups: [
                DuplicateGroup(size: 4096, digest: digest("a"), files: [fotoA, fotoB]),
                DuplicateGroup(
                    size: 2048,
                    digest: digest("b"),
                    files: [docA, docLink, docOther],
                    storage: StoragePartition(
                        clusters: [[docA, docLink], [docOther]], isExact: true)
                ),
                DuplicateGroup(size: 512, digest: digest("c"), files: [copyA, copyB]),
            ]
        )
        try store.save(scan)

        let controller = ReviewWindowController(scan: scan, stateDirectory: state)
        defer { controller.window?.close() }

        // The window checks the filesystem off the main thread, so the assertions below wait for that
        // answer rather than racing it: without this, the warning under test can be overwritten mid-run.
        await controller.awaitPresenceForSelftest()
        let onDisk = try expectSome(controller.groupPresence, "the presence check never landed")
        try expect(onDisk.presentCount == 2, "\(onDisk.presentCount) of 2 files found on disk")
        try expect(onDisk.isStale == false, "a freshly written tree reports as stale")

        try expect(controller.groupRowCount == 3, "\(controller.groupRowCount) groups listed")
        try expect(controller.fileRowCount == 2, "\(controller.fileRowCount) files in group 1")

        // 1. The common parent is hoisted, so the rows show only what differs.
        // Teeth: return nil from PathElision.commonParent and the header shows the fallback sentence.
        try expect(
            controller.headerText == tree + "/fotos", "header reads \(controller.headerText)")
        try expect(
            controller.fileCellText(row: 1, column: "file") == "sub/a.jpg",
            "row 1 reads \(controller.fileCellText(row: 1, column: "file") ?? "nil")"
        )

        // 2. **An unvisited group is a preview, not a decision.**
        // Teeth: make `decisionsForSaving` emit every group and the saved key count below fails.
        try expect(
            controller.reviewState.decision(at: 0) == .undecided,
            "opening the window decided group 1"
        )
        try expect(
            controller.warningText == Strings.string("review.warning.preview"),
            "the preview warning is missing: \(controller.warningText)"
        )
        try expect(
            controller.currentPresentation?.reclaimableBytes == 0,
            "an undecided group already claims to free bytes"
        )
        // The mark is shown all the same, or the user has nothing to react to. **Deeper wins**: the
        // heuristic prefers `sub/a.jpg` over the one sitting loose in the folder above. That is the CLI's
        // guess and surprising enough to be worth pinning here.
        try expect(
            controller.fileCellText(row: 1, column: "keep") == "on",
            "the heuristic's preview is not on the deeper file"
        )
        try expect(
            controller.fileCellText(row: 0, column: "keep") == "off",
            "the shallower file is previewed as kept"
        )

        // The preview pane names the file under the cursor and reports nothing wrong with it.
        // Teeth: drop the `refreshPreview()` call from `selectGroup` and the name comes back empty.
        controller.selectFileForSelftest(0)
        try expect(
            controller.preview.nameText == "a.jpg",
            "the preview names \(controller.preview.nameText)"
        )
        try expect(
            controller.preview.stateText.isEmpty,
            "a file that is right there reports \(controller.preview.stateText)"
        )
        try expect(
            controller.preview.detailText.contains("4.0 KB"),
            "the preview detail reads \(controller.preview.detailText)"
        )
        try expect(controller.preview.isShowingPlaceholder == false, "the placeholder is still up")

        // 3. Toggling makes it a real decision.
        controller.toggleForSelftest()
        try expect(
            controller.reviewState.decision(at: 0).isActionable, "toggling did not decide the group"
        )
        try expect(
            controller.fileCellText(row: 0, column: "keep") == "on", "the toggle did not stick")
        try expect(controller.hasUnsavedReviewChanges, "a decision left nothing to save")

        // 4. Undo puts it back. `NSUndoManager` records nothing useful without the snapshot registration.
        // Teeth: drop `undo.registerUndo` from `mutate` and this fails.
        try expect(controller.canUndoReview, "nothing to undo after a decision")
        controller.undoForSelftest()
        try expect(
            controller.reviewState.decision(at: 0) == .undecided,
            "undo left the group decided"
        )

        // 5. **Keeping nothing is refused.** The preview keeps exactly one file; toggling that one off has
        // to be refused rather than accepted as "remove everything".
        // Teeth: let `toggleCursor` remove the last keeper and the group ends up with zero kept files.
        try expect(
            controller.currentPresentation?.keptCount == 1,
            "the preview keeps \(controller.currentPresentation?.keptCount ?? -1) files"
        )
        controller.selectFileForSelftest(1)
        controller.toggleForSelftest()
        try expect(
            controller.currentPresentation?.keptCount == 1,
            "the review let the group end up keeping nothing"
        )
        try expect(
            controller.reviewState.decision(at: 0) == .undecided,
            "a refused toggle still recorded a decision"
        )
        // Keeping both, then dropping one, is allowed -- the refusal is about the last one, not any one.
        controller.selectFileForSelftest(0)
        controller.toggleForSelftest()
        try expect(controller.currentPresentation?.keptCount == 2, "keeping both was refused")
        controller.selectFileForSelftest(1)
        controller.toggleForSelftest()
        try expect(
            controller.currentPresentation?.keptCount == 1, "dropping one of two was refused")

        // 6. **A file sharing the keeper's storage is never offered.**
        //
        // The keeper is chosen explicitly here rather than left to the heuristic, because the point is the
        // rule and not the guess: whichever file the user keeps, a second name for that same storage must
        // not be offered. (The heuristic would pick the deepest file, which happens to be alone in its
        // cluster and would prove nothing.)
        //
        // Teeth: build the Row with `sharesStorageWithKeeper: false` and the first assertions fail; return
        // `files[1...]` from `removalCandidates` and the removable ones do.
        controller.selectGroupForSelftest(1)
        await controller.awaitPresenceForSelftest()
        try expect(controller.fileRowCount == 3, "group 2 shows \(controller.fileRowCount) files")
        controller.selectFileForSelftest(0)
        controller.toggleForSelftest()
        controller.selectFileForSelftest(2)
        controller.toggleForSelftest()

        let shared = try expectSome(controller.currentPresentation, "group 2 has no presentation")
        try expect(shared.rows[0].isKept, "the chosen keeper is not kept")
        try expect(shared.keptCount == 1, "\(shared.keptCount) files kept, wanted 1")
        try expect(shared.rows[1].sharesStorageWithKeeper, "the hardlink is not recognised")
        try expect(
            shared.rows[1].isRemovable == false, "the keeper's own storage is offered for removal")
        try expect(shared.rows[2].isRemovable, "the independent copy is not offered")
        try expect(
            controller.fileCellText(row: 1, column: "note")
                == Strings.string("review.note.sameStorage"),
            "the note reads \(controller.fileCellText(row: 1, column: "note") ?? "nil")"
        )
        // The checkbox is not a choice for a file that cannot be removed.
        try expect(
            controller.fileCellText(row: 1, column: "keep") == "off",
            "the keeper's own storage is shown as kept"
        )
        // **Three files, two storage classes: keeping one frees one class, not two files.** Counting files
        // would claim 4 KB here and `df` would disagree.
        try expect(shared.distinctCopies == 2, "\(shared.distinctCopies) distinct copies, wanted 2")
        try expect(
            shared.reclaimableBytes == 2048,
            "\(shared.reclaimableBytes) bytes claimed, wanted 2048"
        )
        try expect(shared.isReclaimExact, "a recorded partition is reported as inexact")

        // 7. A copy-looking name is flagged, and the heuristic prefers the other one.
        controller.selectGroupForSelftest(2)
        await controller.awaitPresenceForSelftest()
        let copyGroup = try expectSome(
            controller.currentPresentation, "group 3 has no presentation")
        try expect(copyGroup.rows[0].looksLikeCopy, "\"copia de c.txt\" is not flagged as a copy")
        try expect(copyGroup.rows[1].isKept, "the heuristic kept the copy")

        // 8. Skip is neither decided nor unseen.
        controller.skipGroup(nil)
        try expect(controller.reviewState.decision(at: 2) == .skipped, "skip did not record a skip")
        let tally = controller.reviewState.tally
        try expect(tally.skipped == 1, "\(tally.skipped) skipped, wanted 1")

        // 9. **Saving writes only the decided groups.**
        //
        // Two of the three were decided; the third was skipped. A skip is not a decision, so it must be
        // absent -- and so must a group nobody opened.
        //
        // Teeth: port the CLI's `decisions()` literally and this reads 3 instead of 2.
        controller.saveDecisions(nil)
        let document = try store.loadDecisions(scanID: scan.scanID)
        try expect(
            document.decisions.count == 2,
            "\(document.decisions.count) decision keys saved, wanted 2"
        )
        let savedKeys = Set(document.decisions.map(\.key))
        try expect(
            savedKeys == Set([scan.groups[0].key, scan.groups[1].key]),
            "the saved keys are not the two groups that were decided"
        )
        try expect(
            !savedKeys.contains(scan.groups[2].key),
            "the skipped group was written, which the CLI would then act on"
        )
        try expect(
            document.decisions.allSatisfy { !$0.keptPaths.isEmpty },
            "a saved decision keeps nothing, which the CLI would then ignore"
        )
        try expect(controller.hasUnsavedReviewChanges == false, "saving left the review dirty")

        // 10. Reopening rehydrates from disk: the decisions come back, the skip does not.
        //
        // A persisted skip would be indistinguishable from a decision on the next visit, which is exactly
        // the confusion the tri-state exists to remove.
        let reopened = ReviewWindowController(scan: scan, stateDirectory: state)
        defer { reopened.window?.close() }
        try expect(
            reopened.reviewState.decision(at: 0).isActionable, "a saved decision did not come back")
        try expect(
            reopened.reviewState.decision(at: 1).isActionable,
            "the second saved decision did not come back"
        )
        try expect(
            reopened.reviewState.decision(at: 2) == .undecided,
            "a skip was persisted, which would make it look like a decision"
        )
        try expect(reopened.reviewState.tally.decided == 2, "the rehydrated tally is wrong")
        try expect(reopened.reviewFlow.isAvailable(.dryRun), "a saved review cannot be simulated")
        try expect(
            reopened.reviewFlow.isAvailable(.apply) == false, "apply is offered with no dry run")

        print("  3 groups over a real tree: preview is not a decision, keep-nothing refused")
        print("  the keeper's own storage is not offered; 2 of 3 saved, the skip is not")
    }

    // MARK: - preview

    /// Renders a real preview, and checks what the window says about a file that is no longer there.
    ///
    /// Two halves, both of which need a real filesystem and a real `quicklookd`:
    ///
    /// 1. **A PNG written here comes back as an image**, through `QLThumbnailGenerator` over XPC. That is
    ///    not assertable in a unit test -- the output is whatever a thumbnail extension drew -- so what is
    ///    asserted is that an image of a plausible size arrived, not what it looks like.
    /// 2. **A file the scan listed and that no longer exists says so.** This is the case the real corpus is
    ///    full of: the oldest scans here are from May and 473 of one scan's 501 paths are gone. A pane that
    ///    drew a blank for those would be asking the user to decide about files that are already deleted.
    ///
    /// Plus the caching that makes a group of identical files cheap: eight files sharing one digest share
    /// one thumbnail, so the second request is a hit and no second XPC call happens.
    ///
    /// Writes only under `/tmp`.
    ///
    /// Proof of teeth: four breaks, each named beside its assertion.
    @MainActor
    private static func checkPreview() async throws {
        let root = NSTemporaryDirectory() + "duplicate-selftest-preview-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)

        // A real PNG, drawn here rather than committed: a fixture image is a binary in the repository, and
        // this also documents how to make one.
        let width = 64
        let height = 64
        let context = try expectSome(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            "could not make a bitmap context"
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let drawn = try expectSome(context.makeImage(), "the context produced no image")
        let pngPath = tree + "/blue.png"
        let destination = try expectSome(
            CGImageDestinationCreateWithURL(
                URL(filePath: pngPath) as CFURL, "public.png" as CFString, 1, nil),
            "could not make a PNG destination"
        )
        CGImageDestinationAddImage(destination, drawn, nil)
        try expect(CGImageDestinationFinalize(destination), "the PNG was not written")

        // A second file with the same bytes, so the group is a real duplicate group and the cache key is
        // exercised the way it is in production.
        let pngBytes = try Data(contentsOf: URL(filePath: pngPath))
        let copyPath = tree + "/blue-copy.png"
        try pngBytes.write(to: URL(filePath: copyPath))
        let size = Int64(pngBytes.count)
        // The real digest, because the thumbnail cache key is built from it: a made-up digest would still
        // pass every assertion here while being wrong in production.
        let realDigest = try ContentHasher().fullDigest(atPath: pngPath).digest

        let scan = DuplicateScan(
            scanID: "20260812-130000-000000",
            root: tree,
            createdAt: "2026-08-12T13:00:00.000000Z",
            groups: [
                DuplicateGroup(size: size, digest: realDigest, files: [copyPath, pngPath]),
                // A group whose files are gone: the shape the real corpus is full of.
                DuplicateGroup(
                    size: 1234,
                    digest: Digest32(hexString: String(repeating: "d", count: 64))!,
                    files: [tree + "/gone-a.bin", tree + "/gone-b.bin"]
                ),
            ]
        )
        try store.save(scan)

        let controller = ReviewWindowController(scan: scan, stateDirectory: state)
        defer { controller.window?.close() }
        await controller.awaitPresenceForSelftest()

        // The pane's width decides the pixel size, and the width settles at layout. Settling first makes
        // the cache count below exact rather than "one entry per size the pane happened to have".
        controller.settleLayoutForSelftest()
        try expect(
            controller.currentThumbnailPixels >= ThumbnailPolicy.minimumPixels,
            "the pane asks for \(controller.currentThumbnailPixels) pixels"
        )

        // 1. **A real preview arrives.**
        // Teeth: return nil from `QuickLookThumbnailer.thumbnail` and this fails.
        controller.selectFileForSelftest(0)
        await controller.loadPreviewForSelftest()
        try expect(controller.preview.hasImage, "no image was rendered for a real PNG")
        try expect(
            controller.preview.nameText == "blue-copy.png",
            "the pane names \(controller.preview.nameText)"
        )
        try expect(
            controller.preview.stateText.isEmpty,
            "a file that is right there reports \(controller.preview.stateText)"
        )

        // 2. **The cache collapses a group to one thumbnail.**
        //
        // Asserted on the miss count, not on how many entries the cache holds. **The entry count is not
        // stable and it took a flaky run to find out**: the pixel size comes from the pane's width, the
        // width settles during layout, and a window that is never shown lays out at a time nobody controls.
        // Three runs in six held two entries -- one per size the pane happened to have -- with correct code.
        // The miss count is the property the digest key actually exists for, and it does not move.
        //
        // Teeth: key `ThumbnailKey` on the path instead of the digest and the miss count goes to 3.
        let missesAfterFirst = controller.thumbnailMisses
        controller.selectFileForSelftest(1)
        await controller.loadPreviewForSelftest()
        try expect(
            controller.thumbnailMisses == missesAfterFirst,
            "the second file of the group missed the cache: \(controller.thumbnailMisses) misses"
        )
        try expect(controller.thumbnailHits >= 1, "the cache never reported a hit")

        // 3. **A group whose files are gone says so, and is not offered as a duplicate.**
        // Teeth: make `FilePresence.check` always return `.present` and both assertions fail.
        controller.selectGroupForSelftest(1)
        await controller.awaitPresenceForSelftest()
        let gone = try expectSome(controller.groupPresence, "the presence check never landed")
        try expect(gone.missingCount == 2, "\(gone.missingCount) files reported missing, wanted 2")
        try expect(
            gone.isStillADuplicate == false, "a group with no surviving files is still offered")
        try expect(
            controller.warningText
                == String(
                    format: Strings.string("review.warning.notADuplicate"), 0, 2),
            "the warning reads \(controller.warningText)"
        )
        controller.selectFileForSelftest(0)
        try expect(
            controller.preview.stateText == Strings.string("preview.state.missing"),
            "the pane says \(controller.preview.stateText) about a file that is gone"
        )
        try expect(
            controller.fileCellText(row: 0, column: "note")
                == Strings.string("review.note.missing"),
            "the note reads \(controller.fileCellText(row: 0, column: "note") ?? "nil")"
        )

        // 4. **A file whose length changed is reported as changed, not as fine.**
        // Teeth: drop the size comparison from `FilePresence.check` and this reads as present.
        try Data(repeating: 0x42, count: Int(size) + 7).write(to: URL(filePath: copyPath))
        controller.selectGroupForSelftest(0)
        await controller.awaitPresenceForSelftest()
        let changed = try expectSome(controller.groupPresence, "the presence check never landed")
        try expect(changed.changedCount == 1, "\(changed.changedCount) files changed, wanted 1")
        try expect(
            changed.isStillADuplicate == false,
            "a group with one surviving file is still offered as a duplicate"
        )

        print(
            "  a real PNG rendered through quicklookd; one thumbnail served both files of the group"
        )
        print(
            "  a group whose files are gone is reported, and a changed length is not reported as fine"
        )
    }

    // MARK: - fdlimit

    /// Proves the descriptor limit really gets raised, and that a real scan stays well inside it.
    ///
    /// **Launch Services starts an app with a soft `RLIMIT_NOFILE` of 256.** Running out does not crash: it
    /// surfaces as an unreadable file, gets counted as a skipped candidate, and the scan quietly finds less
    /// than it should -- a failure that looks like a smaller answer rather than an error.
    ///
    /// **The raise is exercised, not observed.** From a terminal the soft limit is often already in the
    /// millions, so asserting on the current value would pass whether or not `main.swift` does anything --
    /// measured: 1048576 on this machine. So the mode lowers the limit to 256 itself, calls the same
    /// function launch does, and checks it came back up. Lowering always succeeds; raising back is bounded
    /// by the hard limit, which is left alone.
    ///
    /// Also counts descriptors across a real scan, because the leak this would catch is a missing
    /// `defer { close(fd) }` on the cancellation path, which no unit test notices.
    ///
    /// Proof of teeth: make `DescriptorLimit.raiseIfNeeded` return without calling `setrlimit` and the
    /// first assertion fails with 256; leak a descriptor per file in `ChunkedReader` and the second fails.
    private static func checkDescriptorLimit() throws {
        let entryLimit = DescriptorLimit.current
        try expect(entryLimit > 0, "the descriptor limit could not be read")
        defer { _ = DescriptorLimit.lowerForTesting(to: entryLimit) }

        try expect(
            DescriptorLimit.lowerForTesting(to: 256),
            "the soft limit could not be lowered for the test")
        try expect(DescriptorLimit.current == 256, "lowering did not take effect")
        let raised = DescriptorLimit.raiseIfNeeded()
        try expect(
            raised >= DescriptorLimit.target,
            "the limit came back as \(raised), wanted at least \(DescriptorLimit.target)"
        )
        try expect(DescriptorLimit.current == raised, "getrlimit disagrees with the raise")

        let before = openDescriptorCount()

        // A scan over a tree big enough to exercise the concurrency window.
        let root = NSTemporaryDirectory() + "duplicate-selftest-fd-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        for index in 0..<300 {
            try Data(repeating: UInt8(index % 251), count: 4096)
                .write(to: URL(filePath: tree + "/f\(index).bin"))
        }
        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let session = ScanSession(
            store: ScanStore(state: state),
            trashResolver: FixedTrashRootResolver([root + "/faketrash"]),
            cacheURL: URL(filePath: root + "/hashes.v1")
        )
        let result = try runBlocking {
            try await session.run(
                ScanSession.Request(root: tree),
                instant: ScanIdentifier.Instant(
                    year: 2026, month: 8, day: 12, hour: 12, minute: 0, second: 0, microsecond: 0)
            )
        }
        try expect(result.scan.groups.count > 0, "the fixture produced no groups")

        let after = openDescriptorCount()
        // A handful of descriptors legitimately survive a scan: the hash cache's own, and whatever the
        // state directory writer left in a cache. A per-file leak over 300 files would be unmistakable.
        try expect(
            after - before <= 16,
            "the scan leaked descriptors: \(before) open before, \(after) after"
        )
        print("  lowered to 256, raised back to \(raised); the launch limit here was \(entryLimit)")
        print("  300 files scanned with \(after - before) descriptors still open afterwards")
    }

    /// How many descriptors this process has open, by probing the table.
    ///
    /// `fcntl(F_GETFD)` rather than listing `/dev/fd`: listing it opens a descriptor of its own and changes
    /// the number being measured.
    private static func openDescriptorCount() -> Int {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return 0 }
        let ceiling = Int(min(limits.rlim_cur, 8192))
        var count = 0
        for descriptor in 0..<ceiling where fcntl(Int32(descriptor), F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    /// Runs an async body from a synchronous selftest mode.
    private static func runBlocking<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Mutex<Result<T, any Error>?>(nil)
        Task.detached {
            do {
                let value = try await body()
                box.withLock { $0 = .success(value) }
            } catch {
                box.withLock { $0 = .failure(error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.withLock({ $0 }) else {
            throw SelfTestFailure("the async body produced nothing")
        }
        return try result.get()
    }

    // MARK: - scan-window

    /// Drives the real scan window over a real tree, and then cancels a second one.
    ///
    /// **This is the mode that says the app no longer needs the CLI.** Everything before it produced or read
    /// documents somebody else made; this one has the window make one.
    ///
    /// What it asserts: the options refuse a root that cannot be scanned; a real scan runs to completion and
    /// **the saved document is the one the store reads back**; the progress labels show sentences and real
    /// counts rather than key literals; and a cancelled scan **writes nothing at all**.
    ///
    /// Writes only under `/tmp`, including the hash cache -- pointing at the real one would make the next
    /// real scan look warm because a selftest hashed a fixture.
    ///
    /// Proof of teeth: four breaks, each named beside its assertion.
    @MainActor
    private static func checkScanWindow() async throws {
        let root = NSTemporaryDirectory() + "duplicate-selftest-scanwin-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)

        // Three groups' worth of duplicates and some unique files, big enough that the hashing phase is
        // real work rather than a single batch.
        for index in 0..<60 {
            let contents = "payload \(index % 20) " + String(repeating: "x", count: 2048)
            try Data(contents.utf8).write(to: URL(filePath: tree + "/f\(index).bin"))
        }
        try Data("unique".utf8).write(to: URL(filePath: tree + "/only.bin"))

        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)
        let controller = ScanPanelController(stateDirectory: state)
        defer { controller.window?.close() }

        // 1. A root that cannot be scanned is refused before any work.
        // Teeth: make `ScanSession.check` always return `.ok` and this fails.
        controller.setRootForSelftest(root + "/does-not-exist")
        try expect(controller.canStart == false, "a missing folder was accepted")
        controller.setRootForSelftest(tree + "/only.bin")
        try expect(controller.canStart == false, "a file was accepted as a folder")

        controller.setRootForSelftest(tree)
        try expect(controller.canStart, "a readable folder was refused")

        // The request the options produce reaches the session with the defaults the window shows.
        let request = try expectSome(
            controller.requestForSelftest(), "the options produced no request")
        try expect(request.root == tree, "the request names \(request.root)")
        try expect(
            request.policy.includesHiddenFiles == false,
            "hidden files are on by default, which buries real findings under .DS_Store groups"
        )
        try expect(
            request.policy.packageHandling == .skipEntirely,
            "packages are descended into by default, which is how a bundle gets corrupted"
        )

        // 2. A real scan runs and lands on disk.
        // Teeth: drop the `store.save` from `ScanSession.run` and the reload below fails.
        controller.startForSelftest()
        try expect(controller.isShowingProgress, "the window stayed on the options page")
        await controller.awaitCompletionForSelftest()
        try expect(controller.isRunning == false, "the scan is still running after completion")

        let identifiers = store.identifiers(in: .scans)
        try expect(identifiers.count == 1, "\(identifiers.count) scans saved, wanted 1")
        let saved = try store.loadScan(id: identifiers[0])
        try expect(saved.root == tree, "the saved scan names \(saved.root)")
        try expect(saved.groups.count == 20, "\(saved.groups.count) groups found, wanted 20")
        try expect(saved.fileCount == 60, "\(saved.fileCount) files grouped, wanted 60")

        // 3. The progress labels are sentences with real numbers, not key literals.
        // Teeth: misspell a `scan.phase.*` key and the phase text comes back as the key.
        controller.refreshProgressForSelftest()
        try expect(
            controller.phaseText == Strings.string("scan.phase.finished"),
            "the phase reads \(controller.phaseText)"
        )
        try expect(
            !controller.phaseText.contains("scan.phase"), "the phase label shows a key literal")
        try expect(
            controller.countsText.contains("61"),
            "the counts read \(controller.countsText), which does not mention the 61 files seen"
        )

        // 4. **A cancelled scan writes nothing.**
        // Teeth: move the `store.save` before the finder's last cancellation check and a second document
        // appears.
        let second = ScanPanelController(stateDirectory: state)
        defer { second.window?.close() }
        second.setRootForSelftest(tree)
        second.startForSelftest()
        second.cancelForSelftest()
        await second.awaitCompletionForSelftest()
        try expect(
            store.identifiers(in: .scans).count == 1,
            "a cancelled scan left \(store.identifiers(in: .scans).count) documents behind"
        )

        print("  60 files scanned by the window into 20 groups, saved and read back")
        print("  a bad root refused before any work; a cancelled scan wrote nothing")
    }

    // MARK: - apply-window

    /// The whole destructive loop through the real windows: review, simulate, apply, undo.
    ///
    /// **This is the mode that says the app is finished for exact duplicates.** Everything before it either
    /// found files or described what it would do to them.
    ///
    /// What it asserts, in order of how much it matters:
    ///
    /// 1. **Nothing moves without a current dry run.** Applying is refused before simulating, and refused
    ///    again after a decision changes -- checked through `ApplyGate`, on the real sheet.
    /// 2. **What the sheet lists is exactly what moves.** Every path, not a sample.
    /// 3. **A file that changed since the scan is left alone**, and the rest still move.
    /// 4. **Undo puts everything back byte-identically.**
    ///
    /// Uses a quarantine root under `/tmp`, not the Trash: the Trash path is covered by `--mode trash`, and
    /// a mode that filled the user's Trash on every run is a mode nobody wants in `selftest-all`.
    ///
    /// Proof of teeth: four breaks, each named beside its assertion.
    @MainActor
    private static func checkApplyWindow() async throws {
        let root = NSTemporaryDirectory() + "duplicate-selftest-apply-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let tree = root + "/tree"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        let state = StateDirectory(environment: ["XDG_STATE_HOME": root], homePath: root)
        let store = ScanStore(state: state)

        func make(_ name: String, _ contents: String) throws -> String {
            let path = tree + "/" + name
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: URL(filePath: path))
            return path
        }

        let keepA = try make("a/keep.txt", "group one contents")
        let dupA = try make("a/copy.txt", "group one contents")
        let keepB = try make("b/keep.txt", "group two contents")
        let dupB = try make("b/copy.txt", "group two contents")
        let hasher = ContentHasher()
        let digestA = try hasher.fullDigest(atPath: keepA).digest
        let digestB = try hasher.fullDigest(atPath: keepB).digest
        let sizeA = Int64("group one contents".utf8.count)
        let sizeB = Int64("group two contents".utf8.count)

        let scan = DuplicateScan(
            scanID: "20260812-140000-000000",
            root: tree,
            createdAt: "2026-08-12T14:00:00.000000Z",
            groups: [
                DuplicateGroup(
                    size: sizeA, digest: digestA, files: PathOrder.sorted([keepA, dupA])),
                DuplicateGroup(
                    size: sizeB, digest: digestB, files: PathOrder.sorted([keepB, dupB])),
            ]
        )
        try store.save(scan)

        let review = ReviewWindowController(scan: scan, stateDirectory: state)
        defer { review.window?.close() }
        await review.awaitPresenceForSelftest()

        // 1. **Nothing to simulate before anything is decided**, and nothing to apply either.
        //
        // Teeth: make `removalPlan` fall back to `effectiveKeep` for undecided groups -- **that** is the
        // function the plan comes from, not `decisionsForSaving`. Measured: breaking `decisionsForSaving`
        // leaves this assertion passing, which is why the note names the right one.
        try expect(
            ApplyPlan.from(review.reviewState).isEmpty,
            "an untouched review already plans to move files"
        )
        try expect(
            review.reviewFlow.isAvailable(.apply) == false, "apply is offered before any dry run")

        // Decide both groups, keeping the file named `keep.txt` in each.
        //
        // **Confirming is what makes it a decision.** Getting the keep set right is not enough: if the
        // heuristic already picked the right file there is nothing to toggle, and the group stays
        // `.undecided` -- which is the tri-state working, not a bug. That is exactly what happened the first
        // time this was written, and the plan came back empty.
        for index in 0..<2 {
            review.selectGroupForSelftest(index)
            await review.awaitPresenceForSelftest()
            let presentation = try expectSome(
                review.currentPresentation, "group \(index + 1) has no presentation")
            let keepRow = try expectSome(
                presentation.rows.firstIndex { $0.path.hasSuffix("keep.txt") },
                "no keep.txt in group \(index + 1)"
            )
            if presentation.rows[keepRow].isKept == false {
                // Keep the right one, then drop the other: a group must never be left keeping nothing, so
                // the order matters.
                review.selectFileForSelftest(keepRow)
                review.toggleForSelftest()
                for row in presentation.rows.indices where row != keepRow {
                    review.selectFileForSelftest(row)
                    review.toggleForSelftest()
                }
            }
            review.selectGroupForSelftest(index)
            review.confirmGroup(nil)
            try expect(
                review.reviewState.decision(at: index).isActionable,
                "group \(index + 1) is still undecided after confirming"
            )
        }

        let plan = ApplyPlan.from(review.reviewState)
        try expect(plan.fileCount == 2, "\(plan.fileCount) files planned, wanted 2")
        try expect(
            Set(plan.items.map(\.path)) == Set([dupA, dupB]),
            "the plan names \(plan.items.map(\.path))"
        )

        // 2. The sheet lists exactly the plan, and the gate refuses until it is shown.
        // Teeth: have `simulateApply` skip `flow.advance(.dryRun,...)` and the apply below is refused.
        review.simulateForSelftest()
        let sheet = try expectSome(review.openApplySheet, "simulating opened no sheet")
        defer { sheet.window?.close() }
        try expect(sheet.canApply, "the sheet will not let a real plan be applied")
        for path in [dupA, dupB] {
            try expect(sheet.listText.contains(path), "the sheet does not list \(path)")
        }
        try expect(
            sheet.listText.contains(keepA) == false, "the sheet lists a file it would keep")

        // 3. **A file that changed since the scan is left alone**, and the other still moves.
        // Teeth: drop the digest check from `VerifyingDisposer` and the changed file moves too.
        try Data("changed after the scan".utf8).write(to: URL(filePath: dupB))

        sheet.applyForSelftest()
        await sheet.awaitApplyForSelftest()
        let report = try expectSome(sheet.lastReport, "the apply produced no report")

        try expect(report.movedCount == 1, "\(report.movedCount) files moved, wanted 1")
        try expect(report.failures.count == 1, "\(report.failures.count) failures, wanted 1")
        try expect(
            report.failures[0].reason == .contentChanged(path: dupB),
            "the failure reads \(report.failures[0].reason)"
        )
        try expect(
            FileManager.default.fileExists(atPath: dupA) == false, "the duplicate did not move")
        try expect(
            FileManager.default.fileExists(atPath: dupB), "the changed file was moved anyway")
        try expect(FileManager.default.fileExists(atPath: keepA), "the keeper was moved")

        // The journal describes what happened, which is what makes an undo possible at all.
        let journalled = try MoveJournal.load(sessionID: report.sessionID, in: state)
        try expect(journalled.entries.count == 1, "\(journalled.entries.count) journal entries")
        try expect(journalled.entries[0].originalPath == dupA, "the journal names the wrong file")

        // 4. **Applying consumes the authorisation.** A second apply needs a second dry run.
        // Teeth: remove the `flow.advance(.apply)` from the completion and this fails.
        try expect(
            review.reviewFlow.isAvailable(.apply) == false,
            "apply is still offered after it already ran"
        )

        // 5. **Undo puts it back byte-identically.**
        // Teeth: make `UndoRunner` copy instead of move, or restore to a suffixed name, and the digest
        // comparison fails.
        let outcome = UndoCoordinator.undo(sessionID: report.sessionID, in: state)
        try expect(outcome.restoredCount == 1, "\(outcome.restoredCount) files restored, wanted 1")
        try expect(FileManager.default.fileExists(atPath: dupA), "the file was not put back")
        try expect(
            try hasher.fullDigest(atPath: dupA).digest == digestA,
            "the restored file does not match what was moved"
        )

        // And a second undo of the same session is a no-op rather than an error, because the `undone_at`
        // records say the work is done.
        let again = UndoCoordinator.undo(sessionID: report.sessionID, in: state)
        try expect(again.restoredCount == 0, "a second undo moved \(again.restoredCount) files")

        print("  simulated, applied 1 of 2, refused the file that changed since the scan")
        print("  undo restored it byte-identically; a second undo did nothing")
    }

    // MARK: - about

    /// Proves the About panel has a real build identity to show.
    ///
    /// This is the one chain that only an assembled bundle can exercise: Makefile variable ->
    /// `sed` substitution -> `Info.plist` key -> `Bundle.main` read -> `AboutInfo` parse. `swift test`
    /// has no bundle, so a broken link in it would ship.
    ///
    /// Proof of teeth: drop the `__BUILD_NUMBER__` substitution from the Makefile and this fails naming
    /// the placeholder.
    private static func checkAbout() throws {
        let info = AboutInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

        try expect(
            !info.hasUnsubstitutedPlaceholder,
            "the Info.plist still holds a __PLACEHOLDER__: version=\(info.version ?? "nil") "
                + "build=\(info.buildNumber ?? "nil") date=\(info.buildDate ?? "nil") "
                + "commit=\(info.commit ?? "nil")"
        )
        let version = try expectSome(info.resolvedVersion, "no version in the bundle")
        let build = try expectSome(info.resolvedBuildNumber, "no build number in the bundle")
        let date = try expectSome(info.displayBuildDate, "no build date in the bundle")
        _ = try expectSome(info.resolvedCommit, "no commit in the bundle")

        // The build number has to be a number, and it has to be the commit count. A marketing version
        // leaking into CFBundleVersion is the failure this catches: it would make two builds of the same
        // version indistinguishable to Launch Services and in crash reports.
        try expect(
            build.allSatisfy(\.isNumber),
            "the build number is not numeric: \(build)"
        )
        try expect(version != build, "version and build number are the same value")
        // The rendered date must have been parsed, not passed through raw.
        try expect(
            date.count == 16 && date.contains("-") && date.contains(":"),
            "the build date was not parsed: \(date)"
        )
        try expect(info.isComplete, "the build identity is incomplete")

        // The wording chain, without a screenshot: the panel is an AppKit window and cannot be inspected
        // headlessly, but the text it would show can. This is what catches a format string whose %@ was
        // lost in translation -- the line would render without the date and look fine.
        _ = AboutPanel.credits(for: info)
        let lines = AboutPanel.creditsLines
        try expect(lines.count >= 2, "the About panel would show \(lines.count) credit lines")
        try expect(
            lines[0].contains(date),
            "the build-date line does not contain the date: \(lines[0].debugDescription)"
        )
        try expect(
            lines[0] != date,
            "the build-date line is the bare value, so its localised label was lost"
        )
        try expect(
            lines[1].contains(info.resolvedCommit ?? "?"),
            "the commit line does not contain the commit: \(lines[1].debugDescription)"
        )
        for line in lines {
            try expect(
                !line.contains("%@") && !line.hasPrefix("about."),
                "an About line is unsubstituted or untranslated: \(line.debugDescription)"
            )
        }

        print("  version \(version) (build \(build)), built \(date)")
        for line in lines { print("    \(line)") }
        if info.isDirtyBuild {
            print("  note: built from a modified working tree")
        }
    }

    // MARK: - icon

    /// Proves the icon shipped, and that it carries the small sizes that actually get used.
    ///
    /// The icon is where this app appears in the System Settings privacy lists, because reading folders
    /// is what it does. An `.icns` missing its 16 pt representation falls back to a generic document
    /// glyph there, and nothing in the build would complain.
    ///
    /// What this cannot check is whether the icon is *legible*: two overlapping squares that merge into
    /// one blob at 16 pt would pass every assertion here. That is verified by looking at it --
    /// `iconutil -c iconset Resources/AppIcon.icns` -- and the PR body says so.
    ///
    /// Proof of teeth: remove the `cp Resources/AppIcon.icns` line from the Makefile and this fails.
    private static func checkIcon() throws {
        let name = Bundle.main.infoDictionary?["CFBundleIconFile"] as? String
        let declared = try expectSome(name, "Info.plist declares no CFBundleIconFile")
        let url = try expectSome(
            Bundle.main.url(forResource: declared, withExtension: "icns"),
            "\(declared).icns is missing from the bundle's Resources"
        )
        let image = try expectSome(
            NSImage(contentsOf: url),
            "\(declared).icns did not decode as an image"
        )
        // Every size the icon was generated at should be present. 16 is the one that matters most and the
        // one a hand-assembled iconset most often lacks.
        let wanted: [CGFloat] = [16, 32, 128, 512]
        let available = Set(image.representations.map(\.pixelsWide))
        for size in wanted {
            try expect(
                available.contains(Int(size)) || available.contains(Int(size) * 2),
                "no representation at \(Int(size))px; have \(available.sorted())"
            )
        }
        try expect(
            image.representations.count >= wanted.count,
            "only \(image.representations.count) representations in the icon"
        )
        print(
            "  \(declared).icns: \(available.sorted().map(String.init).joined(separator: ", "))px")
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

        // A submenu with nothing in it is a title in the menu bar that opens onto nothing.
        for item in menu.items {
            let submenu = try expectSome(item.submenu, "a top-level item has no submenu")
            try expect(
                !submenu.items.isEmpty,
                "the \(submenu.title.isEmpty ? "app" : submenu.title) menu is empty"
            )
        }

        // Undo has to be reachable. `NSUndoManager` records perfectly and is invisible without a menu item
        // carrying its selector, so a review with no working undo would look like a design choice.
        let undoTitles = ["undo:", "redo:"]
        var foundSelectors: Set<String> = []
        for item in menu.items {
            for child in item.submenu?.items ?? [] {
                if let action = child.action { foundSelectors.insert(NSStringFromSelector(action)) }
            }
        }
        for selector in undoTitles {
            try expect(foundSelectors.contains(selector), "no menu item sends \(selector)")
        }

        // The review actions have to be on a menu, or they exist only in code.
        for selector in [
            "confirmGroup:", "skipGroup:", "discardEntireGroup:", "saveDecisions:",
        ] {
            try expect(foundSelectors.contains(selector), "no menu item sends \(selector)")
        }

        print("  \(seen.count) distinct shortcuts across \(menu.items.count) menus")
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

/// Always refuses, to force the quarantine fallback in the trash selftest.
private struct RefusingDisposer: ItemDisposing {
    func dispose(path: String) throws -> DisposalOutcome {
        throw DisposalError.trashUnavailable(path: path, reason: "forced by the selftest")
    }
}

private struct SelfTestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
