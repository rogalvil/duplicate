import AppKit

/// Shows a path in Finder.
///
/// `NSWorkspace` and not Apple events. Telling Finder what to do through an Apple event would need
/// `NSAppleEventsUsageDescription` in the Info.plist and would put a second TCC prompt in front of a user
/// who only asked to see a folder. `NSWorkspace` needs neither.
///
/// In the executable rather than Core because there is nothing to assert: the result is a window in another
/// app. Core owns the *policy* -- whether a scan's paths can be acted on at all -- and this owns the call.
@MainActor
enum Reveal {
    /// Selects an item in its containing folder.
    static func item(at path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    /// Opens a folder, selecting it in its parent when it cannot be opened.
    ///
    /// A scan root that has since been deleted or unmounted -- the common case for an external drive, and
    /// 473 of 501 paths in this user's oldest scans -- makes `open` fail. Falling back to selecting it says
    /// "this is where it was" instead of doing nothing at all.
    static func folder(at path: String) {
        let url = URL(filePath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
