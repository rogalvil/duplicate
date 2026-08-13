@preconcurrency import Accelerate
import Foundation

/// The two-dimensional DCT-II the perceptual hash thresholds.
///
/// **Accelerate's FFT-based DCT, and the reason is exact cancellation rather than speed.** A flat image is the
/// case that decides this. Its transform is mathematically one DC coefficient and 63 zeros, so the median is
/// zero and only the DC bit sets -- the answer `imagehash` gives and the answer this must give. But those 63
/// zeros are only zero if the arithmetic *cancels exactly*:
///
/// | transform of a constant | max&#124;AC&#124; in the 8x8 block |
/// |---|---|
/// | `vDSP.DCT`, `Float` | **0.0, exactly** |
/// | basis matrix via `vDSP_mmul`, `Float` | ~1e-3 of mixed sign |
/// | `scipy.fftpack.dct`, `Float64` | **0.0, exactly** |
///
/// Measured, all three. And a median taken over 63 tiny values of mixed sign is itself one of them, so about
/// half land above it: a perturbation of 1e-3 sets **32 bits instead of 1** -- verified in Python by adding
/// that much noise to a constant. Precision is not what fixes it. An FFT's butterflies subtract equal values
/// and get exact zeros; a sum of 32 cosines that mathematically cancels does not, at any precision. So the
/// matrix form is the clearer definition and the wrong implementation, and it lives on in the tests as the
/// oracle it is good at being.
///
/// This also matters well past flat test fixtures: **a letterboxed bar, a solid background, a black video
/// frame.** The video path leans on identical frames producing identical hashes, and with the matrix form two
/// unrelated black frames would hash to two different piles of noise.
///
/// **Setup is not expensive, which was the other thing worth checking.** The plan said to build one per worker
/// and reuse it. Measured: **1,000 setups at count 32 take 1.0 ms**, one microsecond each, against a decode
/// that costs milliseconds. So one is built per transform, and the type stays a value that needs no
/// `Sendable` argument at all.
///
/// **The scale differs from SciPy by a constant, and that provably cannot move a bit.** `scipy.fftpack.dct`
/// with `norm=None` computes `2·Σ x[n]·cos(π·k·(2n+1)/(2N))`, twice this, applied on two axes -- a uniform
/// factor of 4, confirmed by measurement (`DC = 1.04448e6` there against `261120` here for the same input).
/// The hash compares each coefficient against the **median of those same coefficients**, and scaling a set by
/// one positive number scales its median by the same number, so every comparison lands where it did. This
/// holds only for the unnormalised transform: the orthonormal variant scales `k = 0` by an extra `1/√2`,
/// which is not uniform and can flip bits.
public enum CosineTransform {

    /// Lengths Accelerate's DCT accepts: `f · 2ⁿ` for `f` in `{1, 3, 5, 15}` and `n >= 4`.
    ///
    /// **This is why the pipeline transforms 32 and crops 8 rather than transforming 8.** The minimum is 16.
    public static func supportsLength(_ length: Int) -> Bool {
        guard length >= 16 else { return false }
        for factor in [1, 3, 5, 15] {
            guard length % factor == 0 else { continue }
            let remainder = length / factor
            // A power of two of at least 16.
            if remainder >= 16, remainder & (remainder - 1) == 0 { return true }
        }
        return false
    }

    /// `B · X · Bᵀ`: the DCT along the columns, then along the rows.
    ///
    /// That is the order `imagehash` uses (`dct(dct(pixels, axis=0), axis=1)`). The transform is separable and
    /// linear so the order cannot change the result, but matching it keeps a side-by-side comparison against
    /// Python honest.
    public static func forward2D(_ values: [Float], size: Int) -> [Float] {
        precondition(values.count == size * size, "expected a square matrix of \(size)")
        // A trap rather than a silent fallback to the matrix form: the two agree to within a rounding error on
        // ordinary input and disagree completely on a flat one, so quietly swapping them would change what a
        // hash means without changing a version.
        precondition(
            supportsLength(size),
            "Accelerate's DCT does not accept length \(size); it takes f·2ⁿ for f in {1,3,5,15}, n >= 4"
        )
        guard let transform = vDSP.DCT(count: size, transformType: .II) else {
            preconditionFailure("Accelerate refused a DCT setup of length \(size)")
        }

        let alongColumns = transposed(
            rowTransforms(of: values, size: size, using: transform), size: size)
        let alongRows = rowTransforms(of: alongColumns, size: size, using: transform)
        return transposed(alongRows, size: size)
    }

    /// The definition, as a matrix: `basis[k · size + j] = cos(π·k·(j + ½) / size)`.
    ///
    /// Kept because it is the clearest statement of what the transform is, and used by the differential test
    /// that checks Accelerate against it. Not used to hash -- see the note above.
    public static func basis(size: Int) -> [Float] {
        precondition(size > 0, "a transform needs at least one sample")
        var matrix = [Float](repeating: 0, count: size * size)
        for k in 0..<size {
            for j in 0..<size {
                let angle = Double.pi * Double(k) * (Double(j) + 0.5) / Double(size)
                matrix[k * size + j] = Float(cos(angle))
            }
        }
        return matrix
    }

    /// The median of a set, matching `numpy.median`: for an even count it **averages the two middle values**
    /// rather than picking one.
    ///
    /// It matters here. The 64 coefficients of a flat image are one large DC and 63 zeros, and both middle
    /// values are zero, so the median is zero and the strict `>` leaves only the DC bit set. Picking the upper
    /// middle instead would agree on that fixture and differ on a real photograph, which is the kind of
    /// difference a synthetic test never shows.
    public static func median(_ values: [Float]) -> Float {
        precondition(!values.isEmpty, "no median of nothing")
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - Private

    private static func rowTransforms(
        of values: [Float], size: Int, using transform: vDSP.DCT
    ) -> [Float] {
        var result = [Float](repeating: 0, count: size * size)
        var row = [Float](repeating: 0, count: size)
        var output = [Float](repeating: 0, count: size)
        for index in 0..<size {
            for column in 0..<size { row[column] = values[index * size + column] }
            transform.transform(row, result: &output)
            for column in 0..<size { result[index * size + column] = output[column] }
        }
        return result
    }

    static func transposed(_ matrix: [Float], size: Int) -> [Float] {
        var result = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                result[column * size + row] = matrix[row * size + column]
            }
        }
        return result
    }
}
