import AppKit

/// Whether the panes show the file's size, date and media facts.
///
/// **A preference and not a fixed layout, because the pane it lives in is the narrow half of a split view.**
/// A perceptual pair puts two panes side by side, and on a laptop each is a few hundred points wide -- wide
/// enough for a thumbnail and a path, and two more lines of text is a real cost for someone comparing pictures
/// rather than metadata. So it is on by default and one keystroke away from gone.
///
/// Persisted in `UserDefaults` rather than per window: it is a statement about how the user wants to read this
/// app, not about one scan. Windows already open follow along through the notification, because a preference
/// that only applies to windows opened later reads as a bug.
@MainActor
enum MetadataPreference {
    private static let key = "ShowFileMetadata"

    /// Where the setting is stored. Injectable, and that is not ceremony.
    ///
    /// **A selftest that writes the real preference domain contaminates the next run.** It happened: a mode
    /// asserting the toggle left `ShowFileMetadata` false after a deliberate failure, and from then on every run
    /// started with the line off and a different mode failed with "hidden by default" -- a failure pointing at
    /// innocent code. The same trap the presence cache hit with `~/Library/Caches`, in a different domain.
    static var defaults: UserDefaults = .standard

    /// Broadcast when the setting changes, so open panes can redraw without being tracked.
    static let didChange = Notification.Name("com.rogalvil.duplicate.metadataPreferenceDidChange")

    /// Defaults to on: the metadata is why someone opens the pane a second time.
    static var isEnabled: Bool {
        get {
            guard defaults.object(forKey: key) != nil else { return true }
            return defaults.bool(forKey: key)
        }
        set {
            defaults.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func toggle() {
        isEnabled = !isEnabled
    }
}
