import XCTest
@testable import VitCore

/// Deterministic RNG so fuzz failures are reproducible from the printed seed.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Structural invariants that must hold after any input. Returns a description of the first violation.
func invariantViolation(_ t: Terminal) -> String? {
    if t.cursorX < 0 || t.cursorX >= t.cols { return "cursorX \(t.cursorX) out of 0..<\(t.cols)" }
    if t.cursorY < 0 || t.cursorY >= t.rows { return "cursorY \(t.cursorY) out of 0..<\(t.rows)" }
    if !(0 <= t.scrollTop && t.scrollTop <= t.scrollBottom && t.scrollBottom < t.rows) {
        return "scroll region \(t.scrollTop)...\(t.scrollBottom) invalid for \(t.rows) rows"
    }
    for (name, g) in [("primary", t.primary), ("alternate", t.alternate)] {
        if g.cols != t.cols || g.rows != t.rows { return "\(name) grid \(g.cols)x\(g.rows) != terminal \(t.cols)x\(t.rows)" }
        if g.count != g.rows + g.scrollbackCount { return "\(name) count mismatch" }
        if g.scrollbackCount < 0 || g.scrollbackCount > max(g.maxScrollback, 0) {
            return "\(name) scrollback \(g.scrollbackCount) exceeds limit \(g.maxScrollback)"
        }
        var seen = Set<ObjectIdentifier>()
        for i in 0..<g.count {
            let line = g.line(at: i)
            if !seen.insert(ObjectIdentifier(line)).inserted { return "\(name) line object appears twice (logical \(i))" }
            if line.count != g.cols { return "\(name) line \(i) has \(line.count) cells, expected \(g.cols)" }
            if line.used < 0 || line.used > line.count { return "\(name) line \(i) used=\(line.used) out of range" }
            if line.used > line.capacity { return "\(name) line \(i): used \(line.used) exceeds capacity \(line.capacity)" }
            if i >= g.count - g.rows && line.capacity < line.count {
                return "\(name) screen line \(i) is compacted (capacity \(line.capacity) < \(line.count))"
            }
            // Raw storage within `used` must never contain released (poisoned) cells.
            for x in 0..<line.used where line.cells[x].codepoint == 0xA5A5_A5A5 {
                return "\(name) line \(i) col \(x): released cell leaked back into content"
            }
            for x in 0..<line.count {
                let c = line[x]
                if c.flags.contains(.wide) {
                    if x + 1 >= line.count || !line[x + 1].flags.contains(.wideSpacer) {
                        return "\(name) line \(i) col \(x): wide char without spacer"
                    }
                }
                if c.flags.contains(.wideSpacer) {
                    if x == 0 || !line[x - 1].flags.contains(.wide) {
                        return "\(name) line \(i) col \(x): orphan wide spacer"
                    }
                }
                if c.flags.contains(.grapheme) && Int(c.codepoint) >= t.graphemes.clusters.count {
                    return "\(name) line \(i) col \(x): grapheme index out of range"
                }
            }
        }
    }
    return nil
}

final class InvariantTests: XCTestCase {
    override func setUp() { Line.poisonReleasedCells = true }
    override func tearDown() { Line.poisonReleasedCells = false }

    /// Sequences chosen to stress cursor movement, wide characters, scrolling, erasing and resizing.
    static let fragments: [String] = [
        "a", "hello ", "中", "文字", "😀", "e\u{301}", "👩\u{200D}💻", "\u{FE0F}", "\u{1F1EF}\u{1F1F5}", "x\u{200D}",
        "\r", "\n", "\r\n", "\t", "\u{08}", "\u{0B}", "\u{1B}D", "\u{1B}M", "\u{1B}E", "\u{1B}7", "\u{1B}8", "\u{1B}c",
        "\u{1B}[H", "\u{1B}[5;5H", "\u{1B}[999;999H", "\u{1B}[A", "\u{1B}[3B", "\u{1B}[10C", "\u{1B}[D", "\u{1B}[2G",
        "\u{1B}[J", "\u{1B}[1J", "\u{1B}[2J", "\u{1B}[3J", "\u{1B}[K", "\u{1B}[1K", "\u{1B}[2K",
        "\u{1B}[@", "\u{1B}[3@", "\u{1B}[P", "\u{1B}[4P", "\u{1B}[X", "\u{1B}[5X", "\u{1B}[L", "\u{1B}[2L", "\u{1B}[M", "\u{1B}[3M",
        "\u{1B}[S", "\u{1B}[2S", "\u{1B}[T", "\u{1B}[3T", "\u{1B}[4b", "\u{1B}[2;6r", "\u{1B}[r", "\u{1B}[3;2r",
        "\u{1B}[?6h", "\u{1B}[?6l", "\u{1B}[?7l", "\u{1B}[?7h", "\u{1B}[4h", "\u{1B}[4l", "\u{1B}[?2027h", "\u{1B}[?2027l",
        "\u{1B}[?1049h", "\u{1B}[?1049l", "\u{1B}[?47h", "\u{1B}[?47l", "\u{1B}[?1047h", "\u{1B}[?1047l", "\u{1B}[?1048h", "\u{1B}[?1048l",
        "\u{1B}#8", "\u{1B}(0lqk\u{1B}(B", "\u{1B}H", "\u{1B}[g", "\u{1B}[3g", "\u{1B}[I", "\u{1B}[Z", "\u{1B}[!p",
        "\u{1B}[1;31;48;5;200m", "\u{1B}[0m", "\u{1B}[41m", "\u{1B}[4:3;58:2::1:2:3m", "\u{1B}[7m", "\u{1B}[27m",
        "\u{1B}]8;;https://e.x\u{1B}\\", "\u{1B}]8;;\u{1B}\\", "\u{1B}]0;title\u{07}", "\u{1B}]133;A\u{07}",
        "\u{1B}_Ga=T,f=24,s=1,v=1,q=2;AAAA\u{1B}\\", "\u{1B}P$qm\u{1B}\\", "\u{1B}[6n", "\u{1B}[c",
        "\u{1B}[", "\u{1B}", "\u{1B}]", "\u{18}", "\u{1A}", "\u{C3}", "\u{E2}\u{82}", "\u{FF}",
    ]

    /// VITTERM_FUZZ_TRACE=<file>: record the input about to be fed, so a crash (which kills the test
    /// process before it can report) can be reproduced from the file.
    static let trace: FileHandle? = ProcessInfo.processInfo.environment["VITTERM_FUZZ_TRACE"].flatMap { path in
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }

    func runFuzz(seed: UInt64, steps: Int, scrollback: Int) {
        var rng = SeededRNG(seed)
        let t = Terminal(cols: Int.random(in: 2...24, using: &rng), rows: Int.random(in: 1...10, using: &rng), scrollback: scrollback)
        var history: [String] = []
        for step in 0..<steps {
            let r = Int.random(in: 0..<100, using: &rng)
            if r < 3 {
                let c = Int.random(in: 2...30, using: &rng), rws = Int.random(in: 1...12, using: &rng)
                history.append("<resize \(c)x\(rws)>")
                if let tr = InvariantTests.trace { try? tr.truncate(atOffset: 0); tr.write(Data("seed \(seed) step \(step) size \(t.cols)x\(t.rows)\n\(history.suffix(12).map(\.debugDescription).joined(separator: "\n"))\n".utf8)) }
                t.resize(cols: c, rows: rws)
            } else {
                var s = ""
                for _ in 0..<Int.random(in: 1...4, using: &rng) {
                    s += InvariantTests.fragments.randomElement(using: &rng)!
                }
                history.append(s)
                if let tr = InvariantTests.trace { try? tr.truncate(atOffset: 0); tr.write(Data("seed \(seed) step \(step) size \(t.cols)x\(t.rows)\n\(history.suffix(12).map(\.debugDescription).joined(separator: "\n"))\n".utf8)) }
                // Feed raw bytes, sometimes split mid-sequence across chunks.
                let bytes = Array(s.utf8)
                let split = Int.random(in: 0...bytes.count, using: &rng)
                t.feed(Array(bytes[..<split]))
                t.feed(Array(bytes[split...]))
            }
            t.pendingOutput.removeAll()
            t.pendingEvents.removeAll()
            if let v = invariantViolation(t) {
                let recent = history.suffix(8).map { $0.debugDescription }.joined(separator: " ")
                XCTFail("seed \(seed) step \(step): \(v)\nlast inputs: \(recent)")
                return
            }
        }
    }

    /// VITTERM_FUZZ_SCALE multiplies the amount of fuzzing (scripts/test.sh --extended uses 20).
    static var scale: UInt64 { UInt64(ProcessInfo.processInfo.environment["VITTERM_FUZZ_SCALE"] ?? "") ?? 1 }

    func testFuzzInvariantsManySeeds() {
        for seed in UInt64(1)...UInt64(150 * InvariantTests.scale) {
            runFuzz(seed: seed, steps: 400, scrollback: seed % 3 == 0 ? 0 : 50)
        }
    }

    func testFuzzLongRun() {
        runFuzz(seed: 0xC0FFEE, steps: 20_000 * Int(InvariantTests.scale), scrollback: 200)
    }

    /// Found by extended fuzzing: a cursor saved on a taller screen, then a resize while on the
    /// alternate screen, made reflow index past the end of the grid.
    func testResizeOnAlternateScreenWithStaleSavedCursor() {
        let t = Terminal(cols: 30, rows: 8, scrollback: 0)
        t.feed("\u{1B}[8;1H\u{1B}7")      // save cursor on the last of 8 rows
        t.resize(cols: 30, rows: 2)
        t.feed("\u{1B}[?47h")              // alternate screen without saving the cursor
        t.resize(cols: 4, rows: 4)
        XCTAssertNil(invariantViolation(t))
        t.feed("\u{1B}[?47l\u{1B}8x")
        XCTAssertNil(invariantViolation(t))
    }

    /// Insert at a wide spacer must not leave half a wide character behind.
    func testInsertCharsAtWideSpacer() {
        let t = Terminal(cols: 10, rows: 2)
        t.feed("a中b\u{1B}[1;3H\u{1B}[@")   // cursor on the spacer half of 中
        XCTAssertNil(invariantViolation(t))
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "a   b")
    }

    /// Reflow preserves the text of every logical line, for any sequence of widths.
    func testReflowRoundTripPreservesText() {
        var rng = SeededRNG(42)
        for _ in 0..<60 {
            let startCols = Int.random(in: 5...40, using: &rng)
            let t = Terminal(cols: startCols, rows: 6, scrollback: 1000)
            var logical: [String] = []
            for _ in 0..<Int.random(in: 1...12, using: &rng) {
                let len = Int.random(in: 0...90, using: &rng)
                let line = String((0..<len).map { _ in "abcdefghij中😀 ".randomElement(using: &rng)! })
                    .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
                logical.append(line)
                t.feed(line + "\r\n")
            }
            for _ in 0..<5 { t.resize(cols: Int.random(in: 3...50, using: &rng), rows: Int.random(in: 2...8, using: &rng)) }
            t.resize(cols: startCols, rows: 6)
            XCTAssertNil(invariantViolation(t))
            var got = t.logicalLineTexts()
            // The cursor sits on an empty line after the last newline; drop trailing empty lines.
            while got.last == "" { got.removeLast() }
            var expected = logical
            while expected.last == "" { expected.removeLast() }
            XCTAssertEqual(got, expected)
        }
    }
}
