import XCTest
@testable import VitCore

/// Optimized paths must produce exactly the same state as the straightforward ones.
final class DifferentialTests: XCTestCase {
    override func tearDown() { Terminal.batchedPrintEnabled = true }

    static let pieces: [String] = [
        "abc", "hello world ", "x", " ", "中", "文字列", "😀", "🚀✨", "é", "e\u{301}", "a\u{300}\u{301}",
        "👩\u{200D}💻", "\u{200D}", "❤\u{FE0F}", "\u{FE0F}", "\u{1F1EF}\u{1F1F5}", "\u{1F1EF}", "👍🏽", "\u{1F3FD}",
        "─│┼╔═╗", "Ελληνικά", "русский", "한국어", "ｱｲｳ", "\u{0301}", "\u{E0B0}",
        "\r", "\n", "\r\n", "\u{08}", "\t",
        "\u{1B}[1;1H", "\u{1B}[1;999H", "\u{1B}[2;3H", "\u{1B}[999;1H", "\u{1B}[3D", "\u{1B}[2C",
        "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}[4h", "\u{1B}[4l", "\u{1B}[?2027h", "\u{1B}[?2027l",
        "\u{1B}(0", "\u{1B}(B", "\u{1B}N", "\u{1B}[K", "\u{1B}[1K", "\u{1B}[2P", "\u{1B}[3@", "\u{1B}[31;44m", "\u{1B}[0m",
    ]

    func assertSameState(_ a: Terminal, _ b: Terminal, _ context: @autoclosure () -> String) -> Bool {
        func fail(_ what: String) -> Bool { XCTFail("\(what) — \(context())"); return false }
        if a.cursorX != b.cursorX || a.cursorY != b.cursorY { return fail("cursor \(a.cursorX),\(a.cursorY) vs \(b.cursorX),\(b.cursorY)") }
        if a.pendingWrap != b.pendingWrap { return fail("pendingWrap \(a.pendingWrap) vs \(b.pendingWrap)") }
        if a.lastPrintValid != b.lastPrintValid || (a.lastPrintValid && (a.lastPrintX != b.lastPrintX || a.lastPrintY != b.lastPrintY)) {
            return fail("last print position differs")
        }
        for (ga, gb) in [(a.primary, b.primary), (a.alternate, b.alternate)] {
            if ga.count != gb.count { return fail("line count \(ga.count) vs \(gb.count)") }
            for i in 0..<ga.count {
                let la = ga.line(at: i), lb = gb.line(at: i)
                if la.wrapped != lb.wrapped { return fail("line \(i) wrapped flag differs") }
                for x in 0..<la.count {
                    var ca = la[x], cb = lb[x]
                    // Grapheme ids are table indices; compare the clusters they name instead.
                    if ca.flags.contains(.grapheme) && cb.flags.contains(.grapheme) {
                        if a.graphemes.scalars(ca.codepoint) != b.graphemes.scalars(cb.codepoint) {
                            return fail("line \(i) col \(x): cluster \(a.graphemes.scalars(ca.codepoint)) vs \(b.graphemes.scalars(cb.codepoint))")
                        }
                        ca.codepoint = 0; cb.codepoint = 0
                    }
                    if ca != cb { return fail("line \(i) col \(x): \(ca) vs \(cb)") }
                }
            }
        }
        return true
    }

    func testBatchedPrintMatchesPerScalarPath() {
        for seed in UInt64(1)...UInt64(300 * InvariantTests.scale) {
            var rng = SeededRNG(seed)
            let cols = Int.random(in: 2...12, using: &rng), rows = Int.random(in: 1...6, using: &rng)
            let batched = Terminal(cols: cols, rows: rows, scrollback: 20)
            let reference = Terminal(cols: cols, rows: rows, scrollback: 20)
            var history: [String] = []
            for _ in 0..<120 {
                var s = ""
                for _ in 0..<Int.random(in: 1...5, using: &rng) { s += DifferentialTests.pieces.randomElement(using: &rng)! }
                history.append(s)
                Terminal.batchedPrintEnabled = true
                batched.feed(s)
                Terminal.batchedPrintEnabled = false
                reference.feed(s)
                Terminal.batchedPrintEnabled = true
                guard assertSameState(batched, reference, "seed \(seed), \(cols)x\(rows), inputs: \(history.suffix(6).map(\.debugDescription).joined(separator: " "))") else {
                    return
                }
            }
        }
    }

    /// The cached search index must find exactly what a simple per-line scan finds.
    func testSearchIndexMatchesReferenceSearch() {
        let alphabet = Array("abcAB中😀 e\u{301}xyz-_.")
        for seed in UInt64(1)...UInt64(80 * InvariantTests.scale) {
            var rng = SeededRNG(seed)
            let t = Terminal(cols: Int.random(in: 3...20, using: &rng), rows: 4, scrollback: 60)
            for _ in 0..<Int.random(in: 1...40, using: &rng) {
                let line = String((0..<Int.random(in: 0...45, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                t.feed(line + (Bool.random(using: &rng) ? "\r\n" : ""))
            }
            var queries = ["a", "ab", "AB", "b a", "中", "😀", "x-", "e\u{301}", "zz", "c.", "_"]
            queries.append(String((0..<Int.random(in: 1...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }))
            for q in queries {
                XCTAssertEqual(t.search(q), referenceSearch(t, q, regex: false), "seed \(seed) query \(q.debugDescription)")
            }
            for r in ["a+", "[a-c]{2}", "^a", "z$", "\\s+b", ".", "\\W*b", "[^a]+", "\\S+\\s", "(?s).{3}", "b|^x"] {
                XCTAssertEqual(t.search(r, regex: true), referenceSearch(t, r, regex: true), "seed \(seed) regex \(r)")
            }
        }
    }

    /// Straightforward search: each logical line on its own, via NSRegularExpression.
    func referenceSearch(_ t: Terminal, _ query: String, regex: Bool) -> [SearchMatch] {
        let caseSensitive = query.contains { $0.isUppercase }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        guard let re = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]) else { return [] }
        var out: [SearchMatch] = []
        let g = t.grid
        var i = 0
        while i < g.count {
            let (ll, next) = t.logicalLine(startingAt: i, in: g)
            i = next
            let ns = ll.text as NSString
            for m in re.matches(in: ll.text, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
                out.append(SearchMatch(start: ll.utf16Map[m.range.location], end: ll.utf16Map[m.range.location + m.range.length - 1]))
            }
        }
        return out
    }
}
