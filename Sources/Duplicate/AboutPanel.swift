import AppKit
import DuplicateCore

/// Shows the standard About panel, filled from the build identity the Makefile stamped in.
///
/// The system panel rather than a custom window: it already handles the app icon, the copyright line,
/// centring, and the Escape key. What it does not know is the build date and the commit, which go in
/// the credits area.
///
/// All the wording lives here, and all the truth lives in ``AboutInfo``. That split is the project's
/// localisation rule: `DuplicateCore` returns values, the executable turns them into a sentence in the
/// user's language.
@MainActor
enum AboutPanel {
    /// The lines the last `credits(for:)` produced.
    ///
    /// Exists so the selftest can assert the wording chain -- Info.plist to AboutInfo to a localised
    /// sentence -- without a screenshot. The panel itself is an AppKit window and cannot be inspected
    /// headlessly; its text can.
    private(set) static var creditsLines: [String] = []

    static func show() {
        let info = AboutInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]

        // The panel shows `applicationVersion` as the version line and `version` in parentheses after
        // it, which is exactly the marketing-version-plus-build-number convention.
        if let version = info.resolvedVersion {
            options[.applicationVersion] = version
        }
        if let build = info.resolvedBuildNumber {
            options[.version] = build
        }
        options[.credits] = credits(for: info)

        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The build date, the commit, and a warning when the build came from a dirty tree.
    static func credits(for info: AboutInfo) -> NSAttributedString {
        let unknown = Strings.string("about.unknown")
        var lines: [String] = [
            String(format: Strings.string("about.builtOn"), info.displayBuildDate ?? unknown),
            String(format: Strings.string("about.commit"), info.resolvedCommit ?? unknown),
        ]
        if info.isDirtyBuild {
            // A dirty build corresponds to no commit at all, so a bug reported against it cannot be
            // reproduced from the repository alone -- and the person reporting it has no way to know
            // that unless the app says so.
            lines.append(Strings.string("about.dirtyBuild"))
        }
        if info.hasUnsubstitutedPlaceholder {
            // Should be impossible in a bundle assembled by the Makefile, and worth shouting about if it
            // ever happens: an unsubstituted bundle identifier orphans every TCC grant.
            lines.append(Strings.string("about.placeholderWarning"))
        }

        creditsLines = lines

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(
            string: lines.joined(separator: "\n"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
