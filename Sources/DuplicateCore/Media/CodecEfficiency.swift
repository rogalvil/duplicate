import Foundation

/// How much picture a codec delivers per bit, relative to H.264.
///
/// **The table is the CLI's, values included** (`similar_review.py:15-21`), because the quality score it feeds
/// decides which file a review proposes to delete. Changing a number here changes which file gets thrown away,
/// so it is copied rather than improved.
///
/// The numbers are rules of thumb, not measurements -- AV1 is not exactly three times H.264 at every bitrate --
/// and that is fine for the job: the score only has to order two encodings of the same picture.
public enum CodecEfficiency {
    public static let table: [String: Double] = [
        "av1": 3.0,
        "hevc": 2.0,
        "vp9": 1.8,
        "h264": 1.0,
        "mpeg4": 0.7,
        "mpeg2video": 0.5,
    ]

    /// The multiplier for a codec name, and whether the table had it.
    ///
    /// **Unknown returns 1.0 *and says so*.** The CLI's `.get(codec, 1.0)` silently treats an unrecognised codec
    /// as H.264, which is a guess that can hand the decision to the wrong file. The number is kept for parity;
    /// the flag exists so a caller can say "I do not know this codec" instead of implying it measured it.
    public static func multiplier(for codec: String) -> (value: Double, isKnown: Bool) {
        let name = codec.lowercased()
        if let known = table[name] { return (known, true) }
        return (1.0, false)
    }

    /// FourCC media subtypes mapped to the names the table uses.
    ///
    /// AVFoundation reports a codec as a four-character code and `ffprobe` reports a name; the table is keyed by
    /// the `ffprobe` name because that is what the CLI wrote. `hvc1` and `hev1` are both HEVC -- one carries its
    /// parameter sets in the sample entry and the other in the stream -- and they are the same codec here.
    public static func name(forFourCharacterCode code: String) -> String {
        switch code.lowercased() {
        case "avc1", "avc3": return "h264"
        case "hvc1", "hev1", "dvh1", "dvhe": return "hevc"
        case "av01": return "av1"
        case "vp09": return "vp9"
        case "mp4v": return "mpeg4"
        case "m2v1", "mpg2": return "mpeg2video"
        case "jpeg": return "mjpeg"
        default: return code.lowercased()
        }
    }
}
