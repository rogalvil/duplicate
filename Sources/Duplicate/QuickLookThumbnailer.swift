import AppKit
@preconcurrency import CoreGraphics
import DuplicateCore
@preconcurrency import QuickLookThumbnailing

/// Renders a thumbnail for one file, or gives up quickly.
///
/// **In the executable and not Core, and the reason is not AppKit.** `QLThumbnailGenerator` is XPC to
/// `quicklookd`: it can be slow, it can fail, it can hang, and its output is whatever a third-party
/// thumbnail extension decided to draw. There is nothing deterministic to assert. Core owns the parts that
/// *are* assertable -- what identifies a thumbnail (``ThumbnailKey``), how big to ask for
/// (``ThumbnailPolicy``) and what to keep (``LRUCache``) -- and this owns the call.
///
/// **The timeout is the load-bearing part.** A review window that stops responding because a thumbnail
/// extension for some format is wedged is worse than one that shows a generic icon. So every request races
/// a deadline, and losing the race cancels the request and falls back to the file's icon, which
/// `NSWorkspace` produces from the local database and cannot hang.
@MainActor
final class QuickLookThumbnailer {
    /// How long to wait before giving up on `quicklookd`.
    ///
    /// Two seconds is long enough for a cold RAW file on an external disk and short enough that a wedged
    /// extension reads as "no preview" rather than "the app froze".
    static let deadline: Duration = .seconds(2)

    private let generator = QLThumbnailGenerator.shared
    private var cache: LRUCache<ThumbnailKey, CGImage>
    /// Work already under way, keyed the same as the cache.
    ///
    /// **Necessary because of how the key works.** Every file in a group shares one key, so arrowing down a
    /// group of eight identical photos fires eight requests for the same image before the first one
    /// returns. Without this they all reach `quicklookd`; with it, seven await the first.
    private var inFlight: [ThumbnailKey: Task<CGImage?, Never>] = [:]

    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var timeouts = 0
    private(set) var fallbacks = 0
    /// How many requests were served by a request already under way.
    private(set) var coalesced = 0

    init(capacity: Int = 64) {
        self.cache = LRUCache(capacity: capacity)
    }

    /// A thumbnail already in memory, if there is one. Never blocks, never calls XPC.
    ///
    /// Separate from ``thumbnail(for:digest:pixelSize:)`` so the window can draw the cached image in the
    /// same turn of the run loop as the selection change, and only fall to an async request on a miss.
    /// Without that split, selecting a row the user already visited flickers.
    func cached(path: String, digest: Digest32, pixelSize: Int) -> CGImage? {
        cached(key: ThumbnailKey(digest: digest, path: path, pixelSize: pixelSize))
    }

    /// The same, for a file that is only itself.
    ///
    /// **The perceptual pair viewer must not share a thumbnail between its two files.** They are different
    /// pictures by construction, and drawing one over the other would make every pair look like a perfect
    /// match -- the one bug a side-by-side comparison cannot afford.
    func cached(path: String, pixelSize: Int) -> CGImage? {
        cached(key: ThumbnailKey(path: path, pixelSize: pixelSize))
    }

    private func cached(key: ThumbnailKey) -> CGImage? {
        if let image = cache.value(for: key) {
            hits += 1
            return image
        }
        return nil
    }

    /// Renders, or returns the file's icon when Quick Look cannot or will not.
    ///
    /// - Returns: `nil` only when the file is gone -- there is no icon for a path that does not exist, and
    ///   inventing one would say the file is fine.
    func thumbnail(path: String, digest: Digest32, pixelSize: Int) async -> CGImage? {
        await thumbnail(
            path: path, key: ThumbnailKey(digest: digest, path: path, pixelSize: pixelSize),
            pixelSize: pixelSize)
    }

    /// Renders one particular file, keyed on its path.
    func thumbnail(path: String, pixelSize: Int) async -> CGImage? {
        await thumbnail(
            path: path, key: ThumbnailKey(path: path, pixelSize: pixelSize), pixelSize: pixelSize)
    }

    private func thumbnail(path: String, key: ThumbnailKey, pixelSize: Int) async -> CGImage? {
        if let image = cache.value(for: key) {
            hits += 1
            return image
        }
        if let existing = inFlight[key] {
            coalesced += 1
            return await existing.value
        }
        misses += 1

        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let task = Task { @MainActor [weak self] () -> CGImage? in
            guard let self else { return nil }
            let outcome = await self.generate(path: path, pixelSize: pixelSize)
            if outcome.timedOut { self.timeouts += 1 }
            if let image = outcome.image {
                self.cache.insert(image, for: key)
                return image
            }
            // The icon is cached under the same key: a file whose thumbnail cannot be made will not start
            // working on the next selection, and asking again costs another two seconds of waiting.
            self.fallbacks += 1
            if let icon = self.iconImage(path: path, pixelSize: pixelSize) {
                self.cache.insert(icon, for: key)
                return icon
            }
            return nil
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func clearCache() {
        cache.removeAll()
    }

    var cachedCount: Int { cache.count }

    // MARK: - Private

    /// Races the generator against the deadline.
    ///
    /// Reports *which* outcome happened rather than collapsing both to `nil`: a timeout and a genuine
    /// failure look identical to the caller but mean different things, and a counter that cannot tell them
    /// apart is a counter nobody can act on.
    private func generate(path: String, pixelSize: Int) async -> (image: CGImage?, timedOut: Bool) {
        enum Outcome: Sendable {
            case rendered(CGImage?)
            case expired
        }

        let points = Double(pixelSize)
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(filePath: path),
            // Points and a scale of 1: the pixel size was already resolved by `ThumbnailPolicy`, and
            // handing the same number twice -- once as points, once as scale -- would square it.
            size: CGSize(width: points, height: points),
            scale: 1,
            // `.all` lets Quick Look answer with a cached low-quality thumbnail when it has one, which is
            // most of the time for a photo library the user has browsed in Finder.
            representationTypes: .all
        )

        let generator = self.generator
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    // The completion arrives on an arbitrary queue, and `resume` is reached exactly once
                    // because `generateBestRepresentation` calls back exactly once.
                    generator.generateBestRepresentation(for: request) { representation, _ in
                        continuation.resume(returning: .rendered(representation?.cgImage))
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: QuickLookThumbnailer.deadline)
                return .expired
            }
            // First answer wins.
            let first = await group.next() ?? .expired
            group.cancelAll()
            switch first {
            case .rendered(let image):
                return (image, false)
            case .expired:
                // Cancelling tells `quicklookd` to stop working on something nobody is waiting for.
                generator.cancel(request)
                return (nil, true)
            }
        }
    }

    private func iconImage(path: String, pixelSize: Int) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: path)
        var rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
