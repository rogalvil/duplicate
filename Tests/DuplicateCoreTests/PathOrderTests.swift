import Foundation
import Testing

@testable import DuplicateCore

@Suite("PathOrder")
struct PathOrderTests {
    // The two forms below were taken from a real scan file in the user's state directory,
    // ~/.local/state/rav/duplicate/scans/, where both appear in the same JSON document. APFS
    // preserves whatever bytes each writer used, so a corpus accumulates both.
    static let decomposed = "Kitzia Sua\u{0301}rez"  // a + combining acute
    static let precomposed = "Kitzia Su\u{00E1}rez"  // precomposed a-acute

    @Test("Swift String equality merges the two Unicode forms the CLI keeps apart")
    func stringEqualityIsWrongForPaths() {
        // Not a test of PathOrder -- a test of the hazard it exists for. Python compares str by
        // code point, so these are two distinct dictionary keys there. Using String as the key type
        // would collapse them into one and lose one of the two review decisions, which is a file
        // moved to the Trash without ever being reviewed.
        #expect(Self.decomposed == Self.precomposed)
        #expect(Self.decomposed.utf8.count != Self.precomposed.utf8.count)
    }

    @Test("Distinguishes the two Unicode forms by raw bytes")
    func bytewiseEqualityKeepsThemApart() {
        #expect(!PathOrder.equal(Self.decomposed, Self.precomposed))
        #expect(PathOrder.equal(Self.decomposed, Self.decomposed))
    }

    @Test("Orders by code point, matching Python's sorted() over Path")
    func ordersByCodePoint() {
        // NFD puts a plain 'a' (U+0061) where NFC puts U+00E1. Python compares 97 < 225 and sorts
        // the decomposed form first. UTF-8 byte order agrees: 0x61 < 0xC3. Swift's String `<`
        // compares under canonical equivalence and does not.
        #expect(PathOrder.lessThan(Self.decomposed, Self.precomposed))
        #expect(!PathOrder.lessThan(Self.precomposed, Self.decomposed))
    }

    @Test("Sorts ASCII paths the way the CLI does")
    func sortsAsciiPaths() {
        let input = ["/x/b.txt", "/x/A.txt", "/x/a.txt", "/x/B.txt", "/x/a/b.txt"]
        // Uppercase sorts before lowercase because 0x41 < 0x61, and "a.txt" sorts before "a/b.txt"
        // because '.' is 0x2E and '/' is 0x2F. Python's sorted() over Path gives the same order,
        // since it compares the path strings by code point.
        let expected = ["/x/A.txt", "/x/B.txt", "/x/a.txt", "/x/a/b.txt", "/x/b.txt"]
        #expect(PathOrder.sorted(input) == expected)
    }

    @Test("A shorter path that is a prefix of a longer one sorts first")
    func prefixSortsFirst() {
        #expect(PathOrder.lessThan("/a/b", "/a/bc"))
        #expect(PathOrder.compare("/a/b", "/a/b") == .orderedSame)
    }

    @Test("Emoji paths order by byte, not by grapheme")
    func emojiOrdersByByte() {
        // Included because a photo library really does contain filenames like this, and because a
        // grapheme-aware comparison would give a different answer than the CLI on exactly them.
        let flag = "/x/\u{1F1F2}\u{1F1FD}.jpg"
        let zebra = "/x/zebra.jpg"
        // 0xF0 (the first byte of a 4-byte UTF-8 sequence) is greater than 'z' (0x7A).
        #expect(PathOrder.lessThan(zebra, flag))
    }

    @Test("Counts components below a root")
    func countsComponents() {
        #expect(PathOrder.componentCount(of: "/root/a.txt", under: "/root") == 1)
        #expect(PathOrder.componentCount(of: "/root/deep/nested/a.txt", under: "/root") == 3)
        #expect(PathOrder.componentCount(of: "/root/a.txt", under: "/root/") == 1)
    }

    @Test("A sibling whose name extends the root is not inside it")
    func siblingIsNotInsideRoot() {
        // /a/bc is not under /a/b. A naive string-prefix check says it is, and the keeper heuristic
        // then scores a file by a depth it does not have -- silently preferring the wrong file.
        #expect(PathOrder.componentCount(of: "/a/bc/x.txt", under: "/a/b") == nil)
        #expect(PathOrder.componentCount(of: "/other/x.txt", under: "/root") == nil)
        #expect(PathOrder.componentCount(of: "/root", under: "/root") == nil)
    }
}
