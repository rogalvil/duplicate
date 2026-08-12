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
        case "all": modes = ["bundle", "state-dir", "l10n", "menu", "json-roundtrip", "scans"]
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
