import Foundation
import Testing

@testable import DuplicateCore

/// A direct two-dimensional Lanczos, written the obvious way: no intermediate buffer, no flattened ragged
/// weights, weights recomputed inside the pixel loop.
///
/// It is the same mathematics by a different route, which is the point -- the separable implementation's risk
/// is its index arithmetic, and only a second implementation can catch that. Per-axis normalisation and joint
/// normalisation agree exactly, because weights that each sum to one have products that sum to one.
private enum NaiveLanczos {
    static func resize(
        _ pixels: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int
    ) -> [Float] {
        func axis(input: Int, output: Int, at position: Int) -> (first: Int, weights: [Double]) {
            let scale = Double(input) / Double(output)
            let filterScale = max(scale, 1.0)
            let support = Lanczos3.support * filterScale
            let center = (Double(position) + 0.5) * scale
            let start = max(0, Int(center - support + 0.5))
            let end = min(input, Int(center + support + 0.5))
            var weights: [Double] = []
            var total = 0.0
            for index in start..<end {
                let weight = Lanczos3.kernel((Double(index) - center + 0.5) / filterScale)
                weights.append(weight)
                total += weight
            }
            if total != 0 { weights = weights.map { $0 / total } }
            return (start, weights)
        }

        var output = [Float](repeating: 0, count: toWidth * toHeight)
        for row in 0..<toHeight {
            let vertical = axis(input: height, output: toHeight, at: row)
            for column in 0..<toWidth {
                let horizontal = axis(input: width, output: toWidth, at: column)
                var accumulated = 0.0
                for (verticalIndex, verticalWeight) in vertical.weights.enumerated() {
                    for (horizontalIndex, horizontalWeight) in horizontal.weights.enumerated() {
                        let sample = pixels[
                            (vertical.first + verticalIndex) * width + horizontal.first
                                + horizontalIndex]
                        accumulated += Double(sample) * verticalWeight * horizontalWeight
                    }
                }
                output[row * toWidth + column] = Float(accumulated)
            }
        }
        return output
    }
}

private struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed | 1 }
    mutating func next(_ bound: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return bound <= 0 ? 0 : Int(state % UInt64(bound))
    }
}

@Suite("PerceptualHash")
struct PerceptualHashTests {

    /// The layout measured against the installed `imagehash`, one row of that table per case.
    @Test(
        "The bit layout is imagehash's",
        arguments: [
            (0, 0, "8000000000000000"),
            (0, 1, "4000000000000000"),
            (1, 0, "0080000000000000"),
            (7, 7, "0000000000000001"),
        ])
    func matchesImagehashBitOrder(row: Int, column: Int, hex: String) throws {
        let bit = PerceptualHash.bitIndex(row: row, column: column)
        let hash = PerceptualHash(bits: 1 << UInt64(bit))
        #expect(hash.hexString == hex)
        #expect(PerceptualHash(hex: hex) == hash)
    }

    @Test("A hex string of the wrong length is refused")
    func refusesShortHex() {
        // Sixteen characters or nothing: accepting "8" would silently mean a hash with 60 zero high bits.
        #expect(PerceptualHash(hex: "8") == nil)
        #expect(PerceptualHash(hex: "") == nil)
        #expect(PerceptualHash(hex: "zzzzzzzzzzzzzzzz") == nil)
        #expect(PerceptualHash(hex: "00000000000000ff")?.bits == 255)
    }

    @Test("Distance and similarity are the CLI's")
    func matchesTheCLIFormulas() {
        let a = PerceptualHash(bits: 0)
        let b = PerceptualHash(bits: 0b1111)
        #expect(a.distance(to: b) == 4)
        // 1.0 - 4/64
        #expect(abs(a.similarity(to: b) - 0.9375) < 1e-12)
        #expect(a.similarity(to: a) == 1.0)
        #expect(PerceptualHash(bits: .max).similarity(to: a) == 0.0)
    }
}

@Suite("GrayscaleConvert")
struct GrayscaleConvertTests {

    /// **Measured against Pillow 12.2.0, not derived.** Pillow rounds -- the truncating form the plan named
    /// disagrees on three of these ten, including `(0,255,0)` where it reads 149 against Pillow's 150.
    @Test(
        "The luma is Pillow's, including its rounding",
        arguments: [
            (0, 0, 0, 0), (255, 255, 255, 255), (1, 2, 3, 2), (10, 20, 30, 18),
            (200, 100, 50, 124), (255, 0, 0, 76), (0, 255, 0, 150), (0, 0, 255, 29),
            (7, 7, 7, 7), (123, 231, 45, 178),
        ])
    func matchesPillow(r: Int, g: Int, b: Int, expected: Int) {
        let value = GrayscaleConvert.luma(r: UInt8(r), g: UInt8(g), b: UInt8(b))
        #expect(Int(value) == expected)
    }

    /// The truncating form really is a different function, so the test above is not decoration.
    @Test("The truncating form disagrees, which is why the rounding one is written out")
    func differsFromTruncation() {
        func truncated(_ r: Int, _ g: Int, _ b: Int) -> Int {
            (19595 * r + 38470 * g + 7471 * b) >> 16
        }
        #expect(truncated(0, 255, 0) == 149)
        #expect(GrayscaleConvert.luma(r: 0, g: 255, b: 0) == 150)
    }

    @Test("A white pixel is exactly 255, so the byte never overflows")
    func staysInAByte() {
        // The coefficients sum to 65536 exactly; this is the case that would trap if they did not.
        #expect(GrayscaleConvert.luma(r: 255, g: 255, b: 255) == 255)
    }

    @Test("The fourth byte of an RGBX pixel is ignored")
    func ignoresTheFourthChannel() {
        let buffer: [UInt8] = [10, 20, 30, 0, 10, 20, 30, 255]
        let grey = GrayscaleConvert.convert(
            interleaved: buffer, pixelCount: 2, bytesPerPixel: 4)
        #expect(grey == [18, 18])
    }
}

@Suite("Lanczos3")
struct Lanczos3Tests {

    @Test("The kernel is sinc(x)·sinc(x/3) inside its support")
    func matchesTheDefinition() {
        #expect(Lanczos3.kernel(0) == 1)
        // sinc is zero at every nonzero integer, so the kernel is too.
        #expect(abs(Lanczos3.kernel(1)) < 1e-12)
        #expect(abs(Lanczos3.kernel(2)) < 1e-12)
        // At and past the support it is exactly zero, not merely small.
        #expect(Lanczos3.kernel(3) == 0)
        #expect(Lanczos3.kernel(4) == 0)
        #expect(Lanczos3.kernel(-1.5) == Lanczos3.kernel(1.5))
        // Between the zeros it overshoots negative, which is where the ringing comes from.
        #expect(Lanczos3.kernel(1.5) < 0)
    }

    /// The property the resampler leans on: normalised weights.
    @Test(
        "Every output's weights sum to one",
        arguments: [(1024, 32), (256, 32), (32, 32), (33, 32), (7, 32), (32, 7), (5, 5)])
    func normalisesEveryOutput(input: Int, output: Int) {
        let weights = Lanczos3.weights(inputSize: input, outputSize: output)
        for position in 0..<output {
            // 1e-6 and not 1e-9: normalisation happens in `Double` and the weights are then stored as
            // `Float`, so summing the 192 of them a 1024 -> 32 reduction needs cannot be tighter than
            // accumulated `Float` epsilon -- measured at 5.4e-9. A tighter bound was my mistake about
            // precision, not a defect. They are stored as `Float` because they multiply `Float` pixels.
            #expect(abs(weights.sum(forOutput: position) - 1.0) < 1e-6)
            #expect(weights.count[position] > 0)
        }
    }

    /// Which is what makes a flat image survive, edges included. An unnormalised pass darkens the border.
    @Test("A constant image resamples to the same constant")
    func preservesAConstant() {
        let pixels = [Float](repeating: 77, count: 40 * 40)
        let resized = Lanczos3.resize(pixels, width: 40, height: 40, toWidth: 32, toHeight: 32)
        #expect(resized.count == 32 * 32)
        #expect(resized.allSatisfy { abs($0 - 77) < 1e-3 })
    }

    @Test("Mirroring the input mirrors the output")
    func isSymmetric() {
        let width = 24
        let height = 8
        var pixels = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                pixels[row * width + column] = Float(column * 7 % 251)
            }
        }
        var mirrored = pixels
        for row in 0..<height {
            for column in 0..<width {
                mirrored[row * width + column] = pixels[row * width + (width - 1 - column)]
            }
        }
        let a = Lanczos3.resize(pixels, width: width, height: height, toWidth: 12, toHeight: 8)
        let b = Lanczos3.resize(mirrored, width: width, height: height, toWidth: 12, toHeight: 8)
        for row in 0..<8 {
            for column in 0..<12 {
                #expect(abs(a[row * 12 + column] - b[row * 12 + (11 - column)]) < 1e-3)
            }
        }
    }

    /// The differential test: the separable implementation against the direct one, over random shapes.
    @Test("The separable pass agrees with a direct 2D reference", arguments: 1...40)
    func agreesWithTheNaiveReference(seed: Int) {
        var rng = Rng(seed: UInt64(seed))
        let width = 4 + rng.next(60)
        let height = 4 + rng.next(60)
        let toWidth = 1 + rng.next(40)
        let toHeight = 1 + rng.next(40)
        var pixels = [Float](repeating: 0, count: width * height)
        for index in pixels.indices { pixels[index] = Float(rng.next(256)) }

        let fast = Lanczos3.resize(
            pixels, width: width, height: height, toWidth: toWidth, toHeight: toHeight)
        let slow = NaiveLanczos.resize(
            pixels, width: width, height: height, toWidth: toWidth, toHeight: toHeight)
        #expect(fast.count == slow.count)
        var worst: Float = 0
        for index in fast.indices { worst = max(worst, abs(fast[index] - slow[index])) }
        // Float accumulation in a different order, over samples up to 255.
        #expect(worst < 0.01, "\(width)x\(height) -> \(toWidth)x\(toHeight) worst \(worst)")
    }
}

@Suite("CosineTransform")
struct CosineTransformTests {

    @Test("The basis is cos(π·k·(j+½)/N)")
    func matchesTheDefinition() {
        let size = 8
        let basis = CosineTransform.basis(size: size)
        for k in 0..<size {
            for j in 0..<size {
                let expected = cos(Double.pi * Double(k) * (Double(j) + 0.5) / Double(size))
                #expect(abs(Double(basis[k * size + j]) - expected) < 1e-6)
            }
        }
        // Row zero is all ones, which is what makes coefficient zero a plain sum.
        #expect((0..<size).allSatisfy { abs(basis[$0] - 1) < 1e-6 })
    }

    /// **Derived, not captured.** A constant image has one nonzero coefficient and its value follows from the
    /// orthogonality of the basis: `Σ_j cos(π·k·(j+½)/N) = 0` for every `k > 0`, so only `(0,0)` survives, at
    /// `value · N²`.
    @Test("A constant matrix transforms to a single coefficient of value·N²")
    func transformsAConstant() {
        let size = 32
        let value: Float = 3
        let transformed = CosineTransform.forward2D(
            [Float](repeating: value, count: size * size), size: size)
        #expect(abs(transformed[0] - value * Float(size * size)) < 0.01)
        for index in 1..<(size * size) {
            #expect(abs(transformed[index]) < 0.01, "coefficient \(index) is \(transformed[index])")
        }
    }

    /// **The property that decided the implementation.** A flat image's transform must be *exactly* one
    /// coefficient, because a median taken over 63 near-zero values of mixed sign falls among them and about
    /// half the bits flip. Measured: the matrix form leaves ~1e-3 of noise here and Accelerate leaves nothing.
    @Test("A constant transforms to exactly one nonzero coefficient", arguments: [7, 128, 255])
    func cancelsExactly(level: Int) {
        let size = 32
        let transformed = CosineTransform.forward2D(
            [Float](repeating: Float(level), count: size * size), size: size)
        #expect(transformed[0] == Float(level) * Float(size * size))
        for row in 0..<8 {
            for column in 0..<8 where !(row == 0 && column == 0) {
                #expect(
                    transformed[row * size + column] == 0,
                    "coefficient (\(row),\(column)) is \(transformed[row * size + column])")
            }
        }
    }

    /// And the matrix form does not, which is why it is the oracle and not the implementation.
    @Test("The matrix form leaves noise where Accelerate leaves zero")
    func showsWhyTheMatrixFormWasRejected() {
        let size = 32
        let basis = CosineTransform.basis(size: size)
        let constant = [Float](repeating: 255, count: size * size)
        // One axis by hand is enough to show it: coefficient k of a constant row is 255 · Σ_j basis[k][j].
        var worst: Float = 0
        for k in 1..<8 {
            var sum: Float = 0
            for j in 0..<size { sum += constant[j] * basis[k * size + j] }
            worst = max(worst, abs(sum))
        }
        #expect(worst > 0, "the matrix form would have to cancel exactly for this to be a wash")
    }

    /// Accelerate against the definition, on ordinary input where both are fine.
    @Test("Accelerate's DCT agrees with the basis matrix", arguments: 1...20)
    func agreesWithTheDefinition(seed: Int) {
        var rng = Rng(seed: UInt64(seed))
        let size = 32
        var values = [Float](repeating: 0, count: size * size)
        for index in values.indices { values[index] = Float(rng.next(256)) }

        let fast = CosineTransform.forward2D(values, size: size)

        // B · X · Bᵀ, spelled out.
        let basis = CosineTransform.basis(size: size)
        var intermediate = [Float](repeating: 0, count: size * size)
        for k in 0..<size {
            for column in 0..<size {
                var sum: Float = 0
                for j in 0..<size { sum += basis[k * size + j] * values[j * size + column] }
                intermediate[k * size + column] = sum
            }
        }
        var slow = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            for m in 0..<size {
                var sum: Float = 0
                for j in 0..<size { sum += intermediate[row * size + j] * basis[m * size + j] }
                slow[row * size + m] = sum
            }
        }
        // Coefficients run to about 255·1024; a relative tolerance is the honest bound.
        var worst: Float = 0
        for index in fast.indices { worst = max(worst, abs(fast[index] - slow[index])) }
        #expect(worst < 1.0, "worst coefficient difference \(worst)")
    }

    @Test("The supported lengths are Accelerate's f·2ⁿ")
    func knowsItsLengths() {
        // The pipeline's size, and the reason it is not 8.
        #expect(CosineTransform.supportsLength(32))
        #expect(CosineTransform.supportsLength(8) == false)
        #expect(CosineTransform.supportsLength(16))
        #expect(CosineTransform.supportsLength(48))  // 3 · 16
        #expect(CosineTransform.supportsLength(80))  // 5 · 16
        #expect(CosineTransform.supportsLength(240))  // 15 · 16
        #expect(CosineTransform.supportsLength(24) == false)  // 3 · 8, and 8 is below the floor
        #expect(CosineTransform.supportsLength(33) == false)
    }

    @Test("The median averages the two middle values, like numpy")
    func averagesTheMiddle() {
        #expect(CosineTransform.median([1, 2, 3, 4]) == 2.5)
        #expect(CosineTransform.median([3, 1, 2]) == 2)
        // The case the hash actually meets: one large value and 63 zeros.
        var values = [Float](repeating: 0, count: 64)
        values[0] = 1000
        #expect(CosineTransform.median(values) == 0)
    }

    /// The scale argument in the doc comment, checked rather than asserted: multiplying every coefficient by
    /// the same positive number cannot move a comparison against their median.
    @Test("A uniform positive scale moves no bit")
    func isScaleInvariant() {
        var values = [Float](repeating: 0, count: 64)
        for index in values.indices { values[index] = Float((index * 37) % 91) - 45 }
        let median = CosineTransform.median(values)
        let scaled = values.map { $0 * 4 }
        let scaledMedian = CosineTransform.median(scaled)
        for index in values.indices {
            #expect((values[index] > median) == (scaled[index] > scaledMedian))
        }
    }
}
