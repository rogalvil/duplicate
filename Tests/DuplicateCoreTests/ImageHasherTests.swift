import Foundation
import Testing

@testable import DuplicateCore

private struct ImageScratch {
    let root: String

    init() throws {
        root = NSTemporaryDirectory() + "/duplicate-phash-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    func path(_ name: String) -> String { root + "/" + name }
    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

/// Grey samples for a pattern, as the floats the hasher takes.
private func grey(_ pattern: SyntheticImage.Pattern, width: Int, height: Int) -> [Float] {
    SyntheticImage.samples(pattern, width: width, height: height).map(Float.init)
}

@Suite("ImageHasher")
struct ImageHasherTests {

    /// **Derived from the definition, and confirmed against the installed `imagehash`.**
    ///
    /// A flat image resamples to a flat 32x32, whose transform is one DC coefficient and 63 zeros. The median
    /// of 63 zeros and one large value is zero, and `> 0` is true only for the DC, so the hash is bit 63
    /// alone. Python agrees: `imagehash.phash(Image.new("L",(64,64),128))` prints `8000000000000000`.
    @Test("A uniform image hashes to the DC bit alone", arguments: [7, 128, 200, 255])
    func hashesAFlatImage(level: Int) {
        let hasher = ImageHasher()
        let hash = hasher.hash(
            grey: grey(.uniform(UInt8(level)), width: 64, height: 64), width: 64, height: 64)
        #expect(hash.hexString == "8000000000000000")
    }

    /// The one case where the DC is not above the median, because it is zero too. Python prints
    /// `0000000000000000` for a black image, and so does this.
    @Test("A black image hashes to zero")
    func hashesBlack() {
        let hasher = ImageHasher()
        let hash = hasher.hash(
            grey: grey(.uniform(0), width: 64, height: 64), width: 64, height: 64)
        #expect(hash.hexString == "0000000000000000")
    }

    @Test("A PNG on disk hashes the same as its samples in memory")
    func matchesThroughAFile() throws {
        let scratch = try ImageScratch()
        defer { scratch.remove() }
        let path = try SyntheticImage.write(
            .rampWithCorner, width: 96, height: 96, format: .png, to: scratch.path("a.png"))

        let hasher = ImageHasher()
        let fromFile = try hasher.hash(fileURL: URL(filePath: path))
        let fromMemory = hasher.hash(
            grey: grey(.rampWithCorner, width: 96, height: 96), width: 96, height: 96)
        // The file goes through ImageIO's thumbnail and a CoreGraphics draw; PNG is lossless and 96 is under
        // the 256 decode cap, so the samples have to survive.
        #expect(fromFile == fromMemory)
    }

    /// **The invariance the hash exists for**: a lossy re-encode must not move it much.
    @Test("A JPEG re-encode stays close")
    func survivesJPEG() throws {
        let scratch = try ImageScratch()
        defer { scratch.remove() }
        let hasher = ImageHasher()
        let png = try SyntheticImage.write(
            .rampWithCorner, width: 160, height: 160, format: .png, to: scratch.path("a.png"))
        let jpeg = try SyntheticImage.write(
            .rampWithCorner, width: 160, height: 160, format: .jpeg(quality: 0.9),
            to: scratch.path("a.jpg"))

        let distance = try hasher.hash(fileURL: URL(filePath: png))
            .distance(to: try hasher.hash(fileURL: URL(filePath: jpeg)))
        print("  JPEG q=0.9 re-encode distance: \(distance)")
        #expect(distance <= 2)
    }

    @Test("The same picture at half the size stays close")
    func survivesScaling() {
        let hasher = ImageHasher()
        let full = hasher.hash(
            grey: grey(.rampWithCorner, width: 200, height: 200), width: 200, height: 200)
        let half = hasher.hash(
            grey: grey(.rampWithCorner, width: 100, height: 100), width: 100, height: 100)
        let distance = full.distance(to: half)
        print("  50% scale distance: \(distance)")
        #expect(distance <= 2)
    }

    /// And the other direction: a hash that never moves would be useless.
    @Test("An inverted image is far away")
    func distinguishesInversion() {
        let hasher = ImageHasher()
        let samples = grey(.rampWithCorner, width: 128, height: 128)
        let inverted = samples.map { 255 - $0 }
        let distance = hasher.hash(grey: samples, width: 128, height: 128)
            .distance(to: hasher.hash(grey: inverted, width: 128, height: 128))
        print("  inversion distance: \(distance)")
        #expect(distance >= 20)
    }

    @Test("A fine checkerboard and a ramp are far apart")
    func distinguishesPatterns() {
        let hasher = ImageHasher()
        let ramp = hasher.hash(
            grey: grey(.horizontalRamp, width: 128, height: 128), width: 128, height: 128)
        let board = hasher.hash(
            grey: grey(.checkerboard(square: 3), width: 128, height: 128), width: 128, height: 128)
        #expect(ramp.distance(to: board) >= 10)
    }

    /// **A perceptual hash cannot tell some pictures apart, and this pins which.** The hash reads the eight
    /// lowest spatial frequencies; a checkerboard of 8-pixel squares in a 128-pixel image has all its energy
    /// at a frequency *outside* that block, so what the hash sees is a flat grey -- and it answers the same
    /// thing it answers for a flat grey.
    ///
    /// `imagehash` answers `8000000000000000` for every one of these too, measured. So this is a property of
    /// the algorithm, not a defect in this implementation, and a test that expected these to differ would be
    /// asserting something false. It stays here because the alternative is rediscovering it as a bug report.
    @Test(
        "Patterns whose detail is above the eighth frequency all read as flat",
        arguments: [
            SyntheticImage.Pattern.uniform(128),
            .horizontalRamp,
            .checkerboard(square: 8),
            .checkerboard(square: 16),
        ])
    func collapsesHighFrequencyPatterns(pattern: SyntheticImage.Pattern) {
        let hash = ImageHasher().hash(
            grey: grey(pattern, width: 128, height: 128), width: 128, height: 128)
        #expect(hash.hexString == "8000000000000000")
    }

    /// **Bit-identical to `imagehash`, on the fixtures where it is.**
    ///
    /// Measured against `imagehash` on Pillow 12.2.0: seven of eight synthetic fixtures agree bit for bit,
    /// including a ramp, two checkerboards and an asymmetric corner pattern. The eighth,
    /// `checkerboard(square: 3)`, is **4 bits apart** -- the finest pattern, where the one deliberate
    /// difference shows: Pillow rounds to `UInt8` *between* its two resampling passes and this rounds only
    /// after both.
    ///
    /// These are captured from the reference rather than derived, which is the right way round: the point is
    /// that the reference and this agree, and only the reference can say what it produces. CI has no Pillow,
    /// so the comparison has to arrive as constants or not at all.
    @Test(
        "The hash matches imagehash on the fixtures where the resamplers agree",
        arguments: [
            (SyntheticImage.Pattern.uniform(128), 128, "8000000000000000"),
            (.horizontalRamp, 128, "8000000000000000"),
            (.horizontalRamp, 200, "8000000000000000"),
            (.checkerboard(square: 8), 128, "8000000000000000"),
            (.checkerboard(square: 16), 128, "8000000000000000"),
            (.rampWithCorner, 128, "a8f8f8f8f8070707"),
            (.rampWithCorner, 160, "a8f8f8f8f8070707"),
        ])
    func matchesImagehash(pattern: SyntheticImage.Pattern, size: Int, hex: String) {
        let hash = ImageHasher().hash(
            grey: grey(pattern, width: size, height: size), width: size, height: size)
        #expect(hash.hexString == hex)
    }

    /// The one that differs, pinned with the measurement so a change in either direction is visible.
    @Test("The finest checkerboard is four bits from imagehash, and that is known")
    func differsWhereTheResamplersDo() throws {
        let ours = ImageHasher().hash(
            grey: grey(.checkerboard(square: 3), width: 128, height: 128), width: 128, height: 128)
        let theirs = try #require(PerceptualHash(hex: "81027f0a7f2a3faa"))
        #expect(ours.hexString == "81022f0a7f2affaa")
        #expect(ours.distance(to: theirs) == 4)
        // Which is inside the CLI's own threshold of 5, so both tools would still call these the same image.
        #expect(ours.distance(to: theirs) <= 5)
    }

    @Test("A file that is not an image is refused by name")
    func refusesNonImages() throws {
        let scratch = try ImageScratch()
        defer { scratch.remove() }
        let path = scratch.path("notes.txt")
        try Data("not an image".utf8).write(to: URL(filePath: path))
        #expect(throws: MediaHashingError.notAnImage(path: path)) {
            try ImageHasher().hash(fileURL: URL(filePath: path))
        }
    }

    @Test("A JPEG round-trips through the writer at a size over the decode cap")
    func decodesLargerThanTheCap() throws {
        let scratch = try ImageScratch()
        defer { scratch.remove() }
        let path = try SyntheticImage.write(
            .checkerboard(square: 40), width: 640, height: 480, format: .png,
            to: scratch.path("big.png"))
        // 640 is past the 256 cap, so ImageIO reduces it and the hasher resamples from the thumbnail.
        let hash = try ImageHasher().hash(fileURL: URL(filePath: path))
        #expect(hash.bits != 0)
        // The DC of a half-black checkerboard is well above the median, so bit 63 is set.
        #expect(hash.bits & (1 << 63) != 0)
    }
}
