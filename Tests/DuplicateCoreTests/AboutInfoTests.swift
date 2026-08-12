import Testing

@testable import DuplicateCore

@Suite("AboutInfo")
struct AboutInfoTests {
    private func info(
        version: String? = "0.1.0",
        buildNumber: String? = "14",
        buildDate: String? = "2026-08-12T08:31:29-0600",
        commit: String? = "d976dad"
    ) -> AboutInfo {
        AboutInfo(
            version: version,
            buildNumber: buildNumber,
            buildDate: buildDate,
            commit: commit
        )
    }

    @Test("Reads the four keys the Makefile stamps")
    func readsInfoDictionary() {
        let resolved = AboutInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "14",
            "DUPBuildDate": "2026-08-12T08:31:29-0600",
            "DUPGitCommit": "d976dad",
            "CFBundleName": "Duplicate",
        ])
        #expect(resolved.resolvedVersion == "0.1.0")
        #expect(resolved.resolvedBuildNumber == "14")
        #expect(resolved.resolvedCommit == "d976dad")
        #expect(resolved.displayBuildDate == "2026-08-12 08:31")
        #expect(resolved.isComplete)
    }

    @Test("Treats an unsubstituted placeholder as absent, and says so")
    func detectsPlaceholders() {
        // The whole reason placeholders use the __NAME__ shape. An unsubstituted CFBundleIdentifier would
        // orphan every TCC grant the app had been given, and the symptom -- "macOS keeps asking for
        // permission" -- points nowhere near the build.
        let broken = info(version: "__VERSION__", buildNumber: "__BUILD_NUMBER__")
        #expect(broken.resolvedVersion == nil)
        #expect(broken.resolvedBuildNumber == nil)
        #expect(broken.hasUnsubstitutedPlaceholder)
        #expect(!broken.isComplete)

        #expect(!info().hasUnsubstitutedPlaceholder)
    }

    @Test("Treats empty and whitespace-only values as absent")
    func treatsBlankAsAbsent() {
        // What a blank plist entry and a build from a tarball both look like.
        #expect(info(version: "").resolvedVersion == nil)
        #expect(info(version: "   ").resolvedVersion == nil)
        #expect(info(commit: nil).resolvedCommit == nil)
        #expect(info(buildDate: "").displayBuildDate == nil)
    }

    @Test("Trims surrounding whitespace from a value it keeps")
    func trimsWhitespace() {
        #expect(info(version: "  0.1.0 ").resolvedVersion == "0.1.0")
    }

    @Test("Renders the build date without a formatter, and without a locale")
    func rendersBuildDate() {
        // Parsed by hand on purpose: a DateFormatter is locale-sensitive, and ISO8601DateFormatter will
        // not accept the -0600 offset without a colon that `date +%z` does not emit. Rendering in the
        // offset the build recorded, rather than the reader's zone, keeps the string identical to what
        // the build machine saw.
        #expect(AboutInfo.formatted("2026-08-12T08:31:29-0600") == "2026-08-12 08:31")
        #expect(AboutInfo.formatted("2026-01-01T00:00:00+0000") == "2026-01-01 00:00")
        #expect(AboutInfo.formatted("2026-12-31T23:59:59Z") == "2026-12-31 23:59")
    }

    @Test("Shows an unparseable build date raw rather than hiding it")
    func showsUnparseableDateRaw() {
        // An unexpected format is still more informative than "unknown", and it makes a stamping bug
        // visible instead of invisible.
        #expect(info(buildDate: "sometime tuesday").displayBuildDate == "sometime tuesday")
        #expect(AboutInfo.formatted("sometime tuesday") == nil)
        #expect(AboutInfo.formatted("2026-08-12") == nil)
        #expect(AboutInfo.formatted("2026-08-12X08:31:29-0600") == nil)
        #expect(AboutInfo.formatted("20x6-08-12T08:31:29-0600") == nil)
    }

    @Test("Flags a build made from a modified working tree")
    func flagsDirtyBuild() {
        // A dirty build corresponds to no commit at all, so a bug reported against it cannot be
        // reproduced from the repository alone -- and whoever reports it cannot know that unless the app
        // says so.
        #expect(info(commit: "d976dad+").isDirtyBuild)
        #expect(!info(commit: "d976dad").isDirtyBuild)
        #expect(!info(commit: nil).isDirtyBuild)
        #expect(info(commit: "d976dad+").resolvedCommit == "d976dad+")
    }

    @Test("A build with no git metadata is incomplete but not broken")
    func toleratesMissingGitMetadata() {
        // A build from a tarball has no commit. The panel says "unknown" and everything else still works.
        let tarball = info(commit: nil)
        #expect(!tarball.isComplete)
        #expect(!tarball.hasUnsubstitutedPlaceholder)
        #expect(tarball.resolvedVersion == "0.1.0")
    }

    @Test("Version and build number are separate values")
    func versionAndBuildAreSeparate() {
        // Using the marketing version for both -- which the sibling project does -- makes two different
        // builds of 0.1.0 indistinguishable to Launch Services, in crash reports, and in a bug report.
        let resolved = info(version: "0.1.0", buildNumber: "14")
        #expect(resolved.resolvedVersion != resolved.resolvedBuildNumber)
        #expect(resolved.resolvedBuildNumber == "14")
    }

    @Test("An empty dictionary yields nothing, without trapping")
    func handlesEmptyDictionary() {
        let empty = AboutInfo(infoDictionary: [:])
        #expect(empty.resolvedVersion == nil)
        #expect(empty.resolvedBuildNumber == nil)
        #expect(empty.displayBuildDate == nil)
        #expect(empty.resolvedCommit == nil)
        #expect(!empty.isComplete)
        #expect(!empty.hasUnsubstitutedPlaceholder)
    }
}
