import Foundation

/// Re-checks that a pair still looks alike, immediately before one of its files is moved.
///
/// **The exact detector's check does not exist here, so this is the honest replacement.** There, the scan
/// recorded a SHA-256 and the runner re-hashes the file and refuses if it differs -- which turns a stale scan or
/// a corrupt cache from data loss into an error message. A perceptual scan records **no digest at all**: only two
/// paths, a similarity and a media type. There is nothing to compare bytes against.
///
/// What *can* be re-checked is the claim the decision was made on: **these two files look alike**. So both files
/// are hashed again and the pair is scored again, and the move happens only if it still passes the threshold the
/// scan was run at. A photograph edited since the scan, or a file replaced wholesale at the same path, fails and
/// is refused.
///
/// It costs a decode of two files -- measured at about 7 ms for a pair of images and 300 ms for a pair of videos
/// -- which is nothing beside a scan that took 177 seconds, and it is paid only for files being deleted.
public struct SimilarVerifier: Sendable {

    public enum Verdict: Sendable, Equatable {
        /// The pair still scores at or above the threshold.
        case stillAlike(similarity: Double)
        /// One or both files could not be read.
        case unreadable(path: String)
        /// The pair no longer passes: something changed since the scan.
        case noLongerAlike(similarity: Double, threshold: Double)
        /// The file to move is not there any more, so there is nothing to do.
        case missing(path: String)
        /// The verification was cancelled part-way.
        ///
        /// **A separate case because the alternative accuses the user's data of something.** A cancelled video
        /// decode used to come back as `unreadable`, so stopping an apply reported "could not read this file"
        /// about a file that is perfectly fine -- and `unreadable` is the one refusal that suggests the user go
        /// look for damage. `Task.checkCancellation` inside ``VideoHasher`` is what makes a 300 ms decode
        /// abortable at all, so the error it throws has to travel as itself.
        case cancelled

        public var allowsMove: Bool {
            if case .stillAlike = self { return true }
            return false
        }
    }

    private let imageHasher: ImageHasher
    private let videoHasher: VideoHasher

    public init(
        imageHasher: ImageHasher = ImageHasher(), videoHasher: VideoHasher = VideoHasher()
    ) {
        self.imageHasher = imageHasher
        self.videoHasher = videoHasher
    }

    public func verify(
        _ item: SimilarApplyItem, imageThreshold: Int, videoThreshold: Double
    ) async -> Verdict {
        guard FileManager.default.fileExists(atPath: item.path) else {
            return .missing(path: item.path)
        }
        // **The counterpart's absence is not this file's problem, but it is a reason to stop.** If the other half
        // of the pair is gone, the claim "these two look alike" cannot be re-checked, and moving on an unverifiable
        // claim is what this type exists to prevent.
        guard FileManager.default.fileExists(atPath: item.counterpart) else {
            return .unreadable(path: item.counterpart)
        }

        switch item.mediaKind {
        case .image:
            // Checked before the two decodes rather than relying on them to notice: `ImageHasher` is
            // synchronous and has no cancellation point, so this is the only place an image pair can stop.
            if Task.isCancelled { return .cancelled }
            guard let a = try? imageHasher.hash(fileURL: URL(filePath: item.path)) else {
                return .unreadable(path: item.path)
            }
            guard let b = try? imageHasher.hash(fileURL: URL(filePath: item.counterpart)) else {
                return .unreadable(path: item.counterpart)
            }
            let distance = a.distance(to: b)
            let similarity = a.similarity(to: b)
            return distance <= imageThreshold
                ? .stillAlike(similarity: similarity)
                : .noLongerAlike(
                    similarity: similarity,
                    threshold: 1.0 - Double(imageThreshold) / Double(PerceptualHash.bitCount))
        case .video:
            let a: VideoHasher.Result
            let b: VideoHasher.Result
            do {
                a = try await videoHasher.hashes(fileURL: URL(filePath: item.path))
                b = try await videoHasher.hashes(fileURL: URL(filePath: item.counterpart))
            } catch is CancellationError {
                return .cancelled
            } catch {
                // Which of the two failed is not knowable from here, and naming the wrong one would send the
                // reader to the wrong file. The one being moved is the one they can act on.
                return .unreadable(path: item.path)
            }
            guard !a.hashes.isEmpty else { return .unreadable(path: item.path) }
            guard !b.hashes.isEmpty else { return .unreadable(path: item.counterpart) }
            // Oriented by bytes, the same way the scan computed it -- the comparison is asymmetric, so asking it
            // in the other direction could answer differently and refuse a move the scan's own number allows.
            let similarity = VideoSimilarity.orientedSimilarity(
                pathA: item.path, hashesA: a.hashes,
                pathB: item.counterpart, hashesB: b.hashes,
                threshold: imageThreshold
            )
            return similarity >= videoThreshold
                ? .stillAlike(similarity: similarity)
                : .noLongerAlike(similarity: similarity, threshold: videoThreshold)
        }
    }
}
