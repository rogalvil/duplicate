import Foundation
import Testing

@testable import DuplicateCore

@Suite("StateDirectory")
struct StateDirectoryTests {
    static let home = "/Users/tester"

    private func state(_ xdg: String? = nil) -> StateDirectory {
        StateDirectory(
            environment: xdg.map { ["XDG_STATE_HOME": $0] } ?? [:],
            homePath: Self.home
        )
    }

    @Test("Falls back to ~/.local/state/duplicate when XDG_STATE_HOME is unset")
    func fallsBackWhenUnset() {
        #expect(state().stateRootPath == "/Users/tester/.local/state")
        #expect(state().duplicateRootPath == "/Users/tester/.local/state/duplicate")
    }

    @Test("Falls back when XDG_STATE_HOME is set but empty")
    func fallsBackWhenEmpty() {
        // An empty base must use the default state directory. Appending the app name to it
        // would resolve to /duplicate and silently hide existing scans.
        #expect(state("").stateRootPath == state().stateRootPath)
    }

    @Test("Honours an absolute XDG_STATE_HOME")
    func honoursAbsoluteOverride() {
        #expect(state("/var/state").stateRootPath == "/var/state")
    }

    @Test("Never produces a trailing slash, whatever the input")
    func neverTrailingSlash() {
        // A trailing slash is not cosmetic: FileManager.fileExists(atPath:) never matches a
        // trailing-slash path against a regular file, so a file sitting where a directory belongs
        // would read as "nothing here" and the real error would surface later, somewhere else,
        // without mentioning the collision. This suite found that exact bug.
        for input in ["/var/state/", "/var/state//", "~/custom/"] {
            #expect(
                !state(input).stateRootPath.hasSuffix("/"), "\(input) produced a trailing slash")
        }
        #expect(state("/var/state/").stateRootPath == "/var/state")
        #expect(state("~/custom/").stateRootPath == "/Users/tester/custom")
        for slot in StateDirectory.Slot.allCases {
            #expect(!state().path(for: slot).hasSuffix("/"))
        }
    }

    @Test("Expands a leading tilde against the injected home")
    func expandsTilde() {
        // Expand against the injected home, independently of the process environment.
        #expect(state("~/custom").stateRootPath == "/Users/tester/custom")
        #expect(state("~").stateRootPath == "/Users/tester")
    }

    @Test("Treats ~otheruser as a literal component")
    func doesNotExpandOtherUser() {
        // Looking up ~name through the password database would ignore the injected home.
        // The result is visibly not absolute, so a caller can refuse it.
        let resolved = state("~other/s")
        #expect(resolved.stateRootPath == "~other/s")
        #expect(!resolved.isAbsolute)
    }

    @Test("Keeps a relative root relative instead of resolving it against the working directory")
    func keepsRelativeRootRelative() {
        // Holding the path as a String rather than a URL is what makes a relative base
        // detectable: URL(filePath:) would silently prepend the process's working directory, and
        // Launch Services starts the app with / as its working directory.
        let relative = state("relative/dir")
        #expect(relative.stateRootPath == "relative/dir")
        #expect(!relative.isAbsolute)
        #expect(state().isAbsolute)
    }

    @Test("Keeps the persisted subdirectory names stable")
    func slotNamesAreStable() {
        // Renaming a slot would hide documents saved by previous builds.
        #expect(
            StateDirectory.Slot.allCases.map(\.rawValue) == [
                "scans", "decisions", "folder-scans", "folder-decisions",
                "similar-scans", "similar-decisions", "similar-renames", "journal",
            ]
        )
        #expect(
            StateDirectory.Slot.allCases.filter { !$0.isSharedWithCLI } == [
                .similarRenames, .journal,
            ])
    }

    @Test("Maps every detector to its scan and decision slots")
    func mapsDetectorsToSlots() {
        #expect(ScanKind.files.scanSlot == .scans)
        #expect(ScanKind.files.decisionSlot == .decisions)
        #expect(ScanKind.folders.scanSlot == .folderScans)
        #expect(ScanKind.folders.decisionSlot == .folderDecisions)
        #expect(ScanKind.media.scanSlot == .similarScans)
        #expect(ScanKind.media.decisionSlot == .similarDecisions)
    }

    @Test("Builds a scan file path under the right slot")
    func buildsFilePath() throws {
        let path = try state().filePath(for: .scans, id: "20260511-112539-973098")
        #expect(
            path == "/Users/tester/.local/state/duplicate/scans/20260511-112539-973098.json")
    }

    @Test("URL accessors carry no trailing slash either")
    func urlAccessorsHaveNoTrailingSlash() throws {
        // The URL form is a convenience, but it has to agree with the string form byte for byte:
        // a URL built with directoryHint .isDirectory would append a slash and reintroduce the
        // fileExists blind spot through the back door.
        let resolved = state()
        #expect(resolved.stateRoot.path(percentEncoded: false) == resolved.stateRootPath)
        #expect(resolved.duplicateRoot.path(percentEncoded: false) == resolved.duplicateRootPath)
        for slot in StateDirectory.Slot.allCases {
            #expect(
                resolved.directory(for: slot).path(percentEncoded: false)
                    == resolved.path(for: slot)
            )
        }
        let id = "20260511-112539-973098"
        #expect(
            try resolved.file(for: .scans, id: id).path(percentEncoded: false)
                == (try resolved.filePath(for: .scans, id: id))
        )
        #expect(resolved.allPaths.count == StateDirectory.Slot.allCases.count)
        #expect(resolved.allPaths.first == resolved.path(for: .scans))
    }

    @Test("Refuses an identifier that would escape its directory")
    func refusesTraversal() {
        #expect(throws: StateDirectoryError.invalidIdentifier("../../etc/passwd")) {
            try state().filePath(for: .scans, id: "../../etc/passwd")
        }
    }

    @Test("Creating a slot directory is idempotent")
    func createIsIdempotent() throws {
        let scratch = TemporaryDirectory()
        try scratch.make()
        defer { scratch.remove() }
        let scoped = StateDirectory(
            environment: ["XDG_STATE_HOME": scratch.path],
            homePath: Self.home
        )
        let first = try scoped.create(.scans)
        let second = try scoped.create(.scans)
        #expect(first == second)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: first, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("Reports something that is not a directory occupying a slot's path")
    func reportsFileWhereDirectoryBelongs() throws {
        // FileManager.createDirectory reports this as NSCocoaErrorDomain 516, whose message says
        // "a file with the same name already exists" without saying that a directory was expected.
        // Naming the case here is the difference between a diagnosis and a shrug -- and the guard
        // only works because the path carries no trailing slash.
        let scratch = TemporaryDirectory()
        try scratch.make()
        defer { scratch.remove() }
        let scoped = StateDirectory(
            environment: ["XDG_STATE_HOME": scratch.path],
            homePath: Self.home
        )
        let blocked = scoped.path(for: .decisions)
        try FileManager.default.createDirectory(
            atPath: scoped.duplicateRootPath,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: blocked, contents: Data(), attributes: nil)
        #expect(throws: StateDirectoryError.notADirectory(blocked)) {
            try scoped.create(.decisions)
        }
    }
}

/// A scratch directory for tests. Created and removed explicitly so failures leave no debris.
struct TemporaryDirectory {
    let path: String

    init() {
        path =
            NSTemporaryDirectory().hasSuffix("/")
            ? NSTemporaryDirectory() + "duplicate-tests-\(UUID().uuidString)"
            : NSTemporaryDirectory() + "/duplicate-tests-\(UUID().uuidString)"
    }

    func make() throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
