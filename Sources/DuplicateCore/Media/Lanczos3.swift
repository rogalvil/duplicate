import Foundation

/// A Lanczos-3 resampler, written out rather than called from vImage.
///
/// **Why not `vImageScale_Planar8`.** Its filter is Lanczos3 by default, Lanczos5 under
/// `kvImageHighQualityResampling`, and the header says the choice *"is subject to change"*. A hash whose bits
/// depend on an undocumented, changeable filter changes meaning in an OS update, and every cached hash
/// silently becomes a hash of something else with no version to bump. Sixty lines of arithmetic buys a
/// resampler that answers the same way in ten years. (The counter-intuitive part: the "high quality" flag
/// makes vImage *less* like Pillow, not more.)
///
/// **The weight scheme is Pillow's**, which is the reference this pipeline is measured against: for each
/// output position, centre the kernel at `(out + 0.5) * scale`, stretch its support by the reduction factor,
/// take every input sample inside that support, and normalise so the weights sum to one. Normalising is what
/// makes a constant image resample to the same constant even at the edges, where the support is clipped.
///
/// **One deliberate divergence from Pillow**: this stays in `Float` between the two passes, while Pillow
/// rounds and clamps to `UInt8`. Reproducing that would mean deliberately quantising to 8 bits halfway
/// through -- worse arithmetic adopted only for bit compatibility with a hash that never crosses the
/// interop boundary. `docs/ARCHITECTURE.md` records the trade.
public enum Lanczos3 {

    /// The kernel's radius, in input samples, before the reduction factor stretches it.
    public static let support = 3.0

    /// `sin(πx) / (πx)`, with the removable singularity filled in.
    public static func sinc(_ x: Double) -> Double {
        if x == 0 { return 1 }
        let scaled = Double.pi * x
        return sin(scaled) / scaled
    }

    /// `sinc(x) · sinc(x/3)` inside the support, zero outside.
    public static func kernel(_ x: Double) -> Double {
        let magnitude = abs(x)
        if magnitude == 0 { return 1 }
        guard magnitude < support else { return 0 }
        return sinc(magnitude) * sinc(magnitude / support)
    }

    /// The weights for one axis, flattened: output `o` reads inputs
    /// `firstIndex[o] ..< firstIndex[o] + count[o]` with `values[offset[o] ..< offset[o] + count[o]]`.
    ///
    /// Ragged rather than a fixed stride because the two ends of the axis touch fewer input samples, and a
    /// padded rectangle would either waste the work or need a mask.
    public struct AxisWeights: Sendable {
        public let firstIndex: [Int]
        public let count: [Int]
        public let offset: [Int]
        public let values: [Float]

        /// Every output's weights sum to one, which is the property the resampler depends on.
        public func sum(forOutput output: Int) -> Double {
            var total = 0.0
            for index in 0..<count[output] { total += Double(values[offset[output] + index]) }
            return total
        }
    }

    public static func weights(inputSize: Int, outputSize: Int) -> AxisWeights {
        precondition(inputSize > 0 && outputSize > 0, "an axis needs at least one sample")
        let scale = Double(inputSize) / Double(outputSize)
        // Only a reduction stretches the kernel. Enlarging keeps the unit support, or the result would be
        // blurred by the ratio rather than interpolated.
        let filterScale = max(scale, 1.0)
        let stretchedSupport = support * filterScale

        var firstIndex: [Int] = []
        var count: [Int] = []
        var offset: [Int] = []
        var values: [Float] = []
        firstIndex.reserveCapacity(outputSize)
        count.reserveCapacity(outputSize)
        offset.reserveCapacity(outputSize)

        for output in 0..<outputSize {
            let center = (Double(output) + 0.5) * scale
            let start = max(0, Int(center - stretchedSupport + 0.5))
            let end = min(inputSize, Int(center + stretchedSupport + 0.5))

            var row: [Double] = []
            row.reserveCapacity(end - start)
            var total = 0.0
            for input in start..<end {
                let weight = kernel((Double(input) - center + 0.5) / filterScale)
                row.append(weight)
                total += weight
            }
            // Renormalise. At the edges the support is clipped, so the raw weights sum to less than one and
            // an unnormalised pass would darken the border -- which a constant-image test catches.
            if total != 0 {
                for index in row.indices { row[index] /= total }
            }

            firstIndex.append(start)
            count.append(row.count)
            offset.append(values.count)
            values.append(contentsOf: row.map(Float.init))
        }

        return AxisWeights(
            firstIndex: firstIndex, count: count, offset: offset, values: values)
    }

    /// Resamples a planar float image, separably: horizontal first, then vertical.
    ///
    /// Separable because a 2D Lanczos kernel is the product of two 1D kernels, so `w·h·(kx + ky)` multiplies
    /// replace `w·h·kx·ky`. A differential test compares this against a direct two-dimensional reference that
    /// computes its weights inline, which is the only way to trust the index arithmetic.
    public static func resize(
        _ pixels: [Float],
        width: Int,
        height: Int,
        toWidth: Int,
        toHeight: Int
    ) -> [Float] {
        precondition(pixels.count == width * height, "pixel count does not match the dimensions")
        let horizontal = weights(inputSize: width, outputSize: toWidth)
        let vertical = weights(inputSize: height, outputSize: toHeight)

        // Pass one: every row of the input, narrowed to the output width.
        var intermediate = [Float](repeating: 0, count: toWidth * height)
        for row in 0..<height {
            let rowBase = row * width
            for column in 0..<toWidth {
                var accumulated: Float = 0
                let start = horizontal.firstIndex[column]
                let base = horizontal.offset[column]
                for index in 0..<horizontal.count[column] {
                    accumulated += pixels[rowBase + start + index] * horizontal.values[base + index]
                }
                intermediate[row * toWidth + column] = accumulated
            }
        }

        // Pass two: every column of the intermediate, shortened to the output height.
        var output = [Float](repeating: 0, count: toWidth * toHeight)
        for row in 0..<toHeight {
            let start = vertical.firstIndex[row]
            let base = vertical.offset[row]
            for column in 0..<toWidth {
                var accumulated: Float = 0
                for index in 0..<vertical.count[row] {
                    accumulated +=
                        intermediate[(start + index) * toWidth + column]
                        * vertical.values[base + index]
                }
                output[row * toWidth + column] = accumulated
            }
        }
        return output
    }
}
