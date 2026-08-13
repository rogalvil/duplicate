import Foundation

/// Turns colour pixels into the grey values Pillow's `convert("L")` produces.
///
/// **Pillow rounds. The plan said it truncated, and the plan was wrong.** Measured against Pillow 12.2.0
/// over ten triples, comparing three candidate formulas:
///
/// ```
/// rgb              PIL  trunc round div1000
/// (1, 2, 3)           2     1     2       1
/// (0, 255, 0)       150   149   150     149
/// (123, 231, 45)    178   177   178     177
/// ```
///
/// Three of ten differ, so the choice is not academic: the truncating form shifts a third of the pixels of a
/// real photograph by one, which moves DCT coefficients and can flip a hash bit. The rounded form matched
/// every value.
///
/// The `+ 0x8000` is a half added before the shift, which is what makes it round instead of floor.
///
/// **Not `CGColorSpaceCreateDeviceGray`**, which applies a colorimetric conversion with gamma and produces
/// visibly different numbers, and **not `vImageMatrixMultiply`**, whose rounding is its own. This is nine
/// integer operations and it is exactly the reference.
public enum GrayscaleConvert {

    /// The ITU-R 601-2 luma Pillow uses, in integers.
    ///
    /// The three coefficients sum to exactly 65536, so a white pixel is exactly 255 and the result can never
    /// exceed a byte: `255 * 65536 + 0x8000 >> 16 == 255`.
    public static func luma(r: UInt8, g: UInt8, b: UInt8) -> UInt8 {
        let weighted = 19595 * Int(r) + 38470 * Int(g) + 7471 * Int(b) + 0x8000
        return UInt8(weighted >> 16)
    }

    /// Converts an interleaved 8-bit buffer to floats in `0...255`, ready to resample.
    ///
    /// Floats rather than bytes because the resampler that follows works in floats and a byte intermediate
    /// would quantise twice. `bytesPerPixel` covers RGBX (4) as well as tight RGB (3); the fourth byte is
    /// ignored, which is what Pillow does with an alpha channel too -- it converts the colour channels and
    /// never composites.
    public static func convert(
        interleaved buffer: [UInt8], pixelCount: Int, bytesPerPixel: Int
    ) -> [Float] {
        precondition(bytesPerPixel >= 3, "need at least three channels to read a luma from")
        precondition(
            buffer.count >= pixelCount * bytesPerPixel, "buffer is short of the pixels claimed")
        var grey = [Float](repeating: 0, count: pixelCount)
        for index in 0..<pixelCount {
            let base = index * bytesPerPixel
            grey[index] = Float(
                luma(r: buffer[base], g: buffer[base + 1], b: buffer[base + 2]))
        }
        return grey
    }
}
