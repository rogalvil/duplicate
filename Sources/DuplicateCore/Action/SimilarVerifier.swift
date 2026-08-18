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
            guard let a = try? await videoHasher.hashes(fileURL: URL(filePath: item.path)),
                !a.hashes.isEmpty
            else { return .unreadable(path: item.path) }
            guard let b = try? await videoHasher.hashes(fileURL: URL(filePath: item.counterpart)),
                !b.hashes.isEmpty
            else { return .unreadable(path: item.counterpart) }
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
