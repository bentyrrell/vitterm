import XCTest
@testable import VitCore

final class TerminalTests: XCTestCase {
    func term(_ cols: Int = 10, _ rows: Int = 4, scrollback: Int = 100) -> Terminal {
        Terminal(cols: cols, rows: rows, scrollback: scrollback)
    }

    func testPrintAndWrap() {
        let t = term(5, 3)
        t.feed("hello world")
        XCTAssertEqual(t.screenText(), "hello\n worl\nd")
        XCTAssertTrue(t.grid.screenLine(0).wrapped)
        XCTAssertEqual(t.cursorX, 1)
        XCTAssertEqual(t.cursorY, 2)
    }

    func testPendingWrap() {
        let t = term(5, 3)
        t.feed("abcde")
        XCTAssertEqual(t.cursorX, 4)
        XCTAssertTrue(t.pendingWrap)
        t.feed("\r\n")
        XCTAssertEqual(t.cursorY, 1)
        XCTAssertFalse(t.grid.screenLine(0).wrapped)
    }

    func testScrollIntoScrollback() {
        let t = term(5, 2)
        t.feed("1\r\n2\r\n3\r\n4")
        XCTAssertEqual(t.screenText(), "3\n4")
        XCTAssertEqual(t.primary.scrollbackCount, 2)
        XCTAssertEqual(t.text(of: t.primary.line(at: 0)), "1")
    }

    func testScrollbackLimitRecyclesLines() {
        let t = term(5, 2, scrollback: 3)
        for i in 0..<20 { t.feed("\(i)\r\n") }
        XCTAssertEqual(t.primary.scrollbackCount, 3)
        XCTAssertEqual(t.text(of: t.primary.line(at: 0)), "16")
        XCTAssertEqual(t.screenText(), "19\n")
        XCTAssertEqual(t.primary.dropped, 16)
    }

    func testCursorMovement() {
        let t = term()
        t.feed("\u{1B}[3;4H")
        XCTAssertEqual(t.cursorX, 3); XCTAssertEqual(t.cursorY, 2)
        t.feed("\u{1B}[A\u{1B}[2C")
        XCTAssertEqual(t.cursorX, 5); XCTAssertEqual(t.cursorY, 1)
        t.feed("\u{1B}[100B\u{1B}[100D")
        XCTAssertEqual(t.cursorX, 0); XCTAssertEqual(t.cursorY, 3)
    }

    func testEraseLine() {
        let t = term()
        t.feed("abcdefghij\u{1B}[1;5H\u{1B}[K")
        XCTAssertEqual(t.screenText().split(separator: "\n", omittingEmptySubsequences: false)[0], "abcd")
        t.feed("\u{1B}[1K")
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "")
    }

    func testEraseDisplay() {
        let t = term(5, 3)
        t.feed("aaaaa\r\nbbbbb\r\nccccc\u{1B}[2;3H\u{1B}[J")
        XCTAssertEqual(t.screenText(), "aaaaa\nbb\n")
    }

    func testInsertDeleteChars() {
        let t = term()
        t.feed("abcdef\u{1B}[1;2H\u{1B}[2@")
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "a  bcdef")
        t.feed("\u{1B}[3P")
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "acdef")
    }

    func testScrollRegion() {
        let t = term(5, 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.feed("\u{1B}[2;3r\u{1B}[3;1H\n")
        XCTAssertEqual(t.screenText(), "1\n3\n\n4")
        XCTAssertEqual(t.primary.scrollbackCount, 0, "region scrolls must not touch scrollback")
        t.feed("\u{1B}[2;1H\u{1B}M")
        XCTAssertEqual(t.screenText(), "1\n\n3\n4")
    }

    func testInsertDeleteLines() {
        let t = term(5, 4)
        t.feed("1\r\n2\r\n3\r\n4\u{1B}[2;1H\u{1B}[L")
        XCTAssertEqual(t.screenText(), "1\n\n2\n3")
        t.feed("\u{1B}[2M")
        XCTAssertEqual(t.screenText(), "1\n3\n\n")
    }

    func testSGR() {
        let t = term()
        t.feed("\u{1B}[1;3;31;48;5;200mX\u{1B}[38;2;1;2;3;4:3mY\u{1B}[0mZ")
        let x = t.cell(x: 0, y: 0)
        XCTAssertTrue(x.flags.contains(.bold))
        XCTAssertTrue(x.flags.contains(.italic))
        XCTAssertEqual(x.fg, .palette(1))
        XCTAssertEqual(x.bg, .palette(200))
        let y = t.cell(x: 1, y: 0)
        XCTAssertEqual(y.fg, .rgb(1, 2, 3))
        XCTAssertEqual(y.flags.underline, .curly)
        let z = t.cell(x: 2, y: 0)
        XCTAssertEqual(z.fg, .default)
        XCTAssertEqual(z.flags, [])
    }

    func testSGRColonTrueColor() {
        let t = term()
        t.feed("\u{1B}[38:2::10:20:30mA\u{1B}[48:2:40:50:60mB\u{1B}[58:5:9mC")
        XCTAssertEqual(t.cell(x: 0, y: 0).fg, .rgb(10, 20, 30))
        XCTAssertEqual(t.cell(x: 1, y: 0).bg, .rgb(40, 50, 60))
        let c = t.cell(x: 2, y: 0)
        XCTAssertEqual(t.extras[c.extra].underlineColor, .palette(9))
    }

    func testWideChars() {
        let t = term(5, 2)
        t.feed("a中b")
        XCTAssertTrue(t.cell(x: 1, y: 0).flags.contains(.wide))
        XCTAssertTrue(t.cell(x: 2, y: 0).flags.contains(.wideSpacer))
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "a中b")
        XCTAssertEqual(t.cursorX, 4)
        // A wide char that doesn't fit wraps.
        t.feed("中")
        XCTAssertEqual(t.screenText(), "a中b\n中")
    }

    func testOverwriteHalfOfWideChar() {
        let t = term(5, 2)
        t.feed("中\u{1B}[1;2Hx")
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), " x")
        XCTAssertFalse(t.cell(x: 0, y: 0).flags.contains(.wide))
    }

    func testCombiningCharacters() {
        let t = term()
        t.feed("e\u{301}x")
        XCTAssertEqual(t.string(for: t.cell(x: 0, y: 0)), "e\u{301}")
        XCTAssertEqual(t.cell(x: 1, y: 0).codepoint, 0x78)
    }

    func testGraphemeClusteringMode() {
        let t = term(10, 2)
        t.feed("\u{1B}[?2027h👩\u{200D}💻x")
        XCTAssertEqual(t.string(for: t.cell(x: 0, y: 0)), "👩\u{200D}💻")
        XCTAssertEqual(t.cell(x: 2, y: 0).codepoint, 0x78)
    }

    func testAlternateScreen() {
        let t = term(5, 2)
        t.feed("main\u{1B}[?1049h\u{1B}[HALT")
        XCTAssertEqual(t.screenText(), "ALT\n")
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(t.screenText(), "main\n")
        XCTAssertEqual(t.cursorX, 4)
    }

    func testDECSpecialGraphics() {
        let t = term()
        t.feed("\u{1B}(0lqk\u{1B}(Bq")
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "┌─┐q")
    }

    func testTabs() {
        let t = term(20, 2)
        t.feed("a\tb")
        XCTAssertEqual(t.cursorX, 9)
    }

    func testDeviceStatusReports() {
        let t = term()
        t.feed("\u{1B}[2;3H\u{1B}[6n")
        XCTAssertEqual(String(decoding: t.pendingOutput, as: UTF8.self), "\u{1B}[2;3R")
        t.pendingOutput.removeAll()
        t.feed("\u{1B}[c")
        XCTAssertTrue(String(decoding: t.pendingOutput, as: UTF8.self).hasPrefix("\u{1B}[?62"))
    }

    func testOSCTitleAndHyperlink() {
        let t = term()
        t.feed("\u{1B}]2;hello\u{07}\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\x")
        XCTAssertEqual(t.title, "hello")
        let c = t.cell(x: 0, y: 0)
        XCTAssertEqual(t.hyperlinks.uri(t.extras[c.extra].hyperlink), "https://example.com")
        XCTAssertEqual(t.cell(x: 4, y: 0).extra, 0)
    }

    func testOSCColorQuery() {
        let t = term()
        t.feed("\u{1B}]4;1;rgb:ff/00/00\u{1B}\\\u{1B}]4;1;?\u{07}")
        XCTAssertEqual(t.palette[1], 0xFF0000)
        XCTAssertEqual(String(decoding: t.pendingOutput, as: UTF8.self), "\u{1B}]4;1;rgb:ffff/0000/0000\u{1B}\\")
    }

    func testReflowNarrower() {
        let t = term(10, 3)
        t.feed("abcdefgh\r\nxy")
        t.resize(cols: 4, rows: 3)
        // "abcdefgh" -> "abcd" "efgh" ; "xy"
        XCTAssertEqual(t.screenText(), "abcd\nefgh\nxy")
        XCTAssertEqual(t.cursorX, 2)
        XCTAssertEqual(t.cursorY, 2)
    }

    func testReflowWider() {
        let t = term(4, 3)
        t.feed("abcdefgh")
        XCTAssertEqual(t.screenText(), "abcd\nefgh\n")
        t.resize(cols: 10, rows: 3)
        XCTAssertEqual(t.screenText(), "abcdefgh\n\n")
        XCTAssertEqual(t.cursorY, 0)
        XCTAssertEqual(t.cursorX, 8)
    }

    func testShrinkRowsPushesToScrollback() {
        let t = term(5, 4)
        t.feed("1\r\n2\r\n3\r\n4")
        t.resize(cols: 5, rows: 2)
        XCTAssertEqual(t.screenText(), "3\n4")
        XCTAssertEqual(t.primary.scrollbackCount, 2)
        t.resize(cols: 5, rows: 4)
        XCTAssertEqual(t.screenText(), "1\n2\n3\n4")
    }

    func testShrinkRowsKeepsCursorLine() {
        let t = term(5, 4)
        t.feed("1")
        t.resize(cols: 5, rows: 2)
        XCTAssertEqual(t.screenText(), "1\n")
        XCTAssertEqual(t.primary.scrollbackCount, 0)
    }

    func testREP() {
        let t = term()
        t.feed("x\u{1B}[4b")
        XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "xxxxx")
    }

    func testKittyKeyboardStack() {
        let t = term()
        t.feed("\u{1B}[>1u\u{1B}[>3u")
        XCTAssertEqual(t.kittyKeyboardFlags, 3)
        t.feed("\u{1B}[<u")
        XCTAssertEqual(t.kittyKeyboardFlags, 1)
        t.feed("\u{1B}[?u")
        XCTAssertEqual(String(decoding: t.pendingOutput, as: UTF8.self), "\u{1B}[?1u")
    }

    func testKittyGraphicsRawRGB() {
        let t = term(20, 5)
        t.cellPixelWidth = 2; t.cellPixelHeight = 2
        // 2x2 red pixels, RGB
        let px = Data([255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0]).base64EncodedString()
        t.feed("\u{1B}_Ga=T,f=24,s=2,v=2,i=7;\(px)\u{1B}\\")
        XCTAssertEqual(t.images.images[7]?.width, 2)
        XCTAssertEqual(t.images.placements.count, 1)
        XCTAssertEqual(String(decoding: t.pendingOutput, as: UTF8.self), "\u{1B}_Gi=7;OK\u{1B}\\")
        t.feed("\u{1B}_Ga=d,d=I,i=7\u{1B}\\")
        XCTAssertTrue(t.images.placements.isEmpty)
    }

    func testKittyGraphicsChunked() {
        let t = term(20, 5)
        let px = Data([0, 255, 0]).base64EncodedString() // 1x1 green
        let a = String(px.prefix(2)), b = String(px.dropFirst(2))
        t.feed("\u{1B}_Ga=t,f=24,s=1,v=1,i=3,q=2,m=1;\(a)\u{1B}\\\u{1B}_Gm=0;\(b)\u{1B}\\")
        XCTAssertNotNil(t.images.images[3])
    }

    func testFuzzDoesNotCrash() {
        let t = term(17, 7)
        var rng = SystemRandomNumberGenerator()
        let fragments = ["\u{1B}[", "\u{1B}]", "\u{1B}P", "\u{1B}_G", ";", "1", "38", "2", "?", "h", "l", "m", "H", "J",
                         "K", "@", "P", "L", "M", "r", "中", "e\u{301}", "\r", "\n", "\t", "\u{1B}\\", "\u{07}", "x",
                         "\u{1B}[?1049h", "\u{1B}[?1049l", "😀", "\u{1B}[4;9r", "\u{1B}[S", "\u{1B}[T", "\u{1B}[99X"]
        for i in 0..<20000 {
            t.feed(fragments.randomElement(using: &rng)!)
            if i % 2000 == 0 { t.resize(cols: Int.random(in: 2...30, using: &rng), rows: Int.random(in: 1...12, using: &rng)) }
        }
        XCTAssertLessThan(t.cursorX, t.cols)
        XCTAssertLessThan(t.cursorY, t.rows)
    }
}

final class FeatureTests: XCTestCase {
    func testSearchAcrossWrap() {
        let t = Terminal(cols: 5, rows: 3, scrollback: 10)
        t.feed("hello world\r\nfoo")
        let m = t.search("lo wo")
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].start, GridPoint(line: 0, col: 3))
        XCTAssertEqual(m[0].end, GridPoint(line: 1, col: 2))
        XCTAssertEqual(t.search("FOO").count, 0, "smart case: uppercase query is case-sensitive")
        XCTAssertEqual(t.search("foo").count, 1)
    }

    func testURLDetection() {
        let t = Terminal(cols: 40, rows: 2, scrollback: 10)
        t.feed("see https://example.com/a?b=1. ok")
        let l = t.link(at: GridPoint(line: 0, col: 10))
        XCTAssertEqual(l?.url, "https://example.com/a?b=1")
        XCTAssertNil(t.link(at: GridPoint(line: 0, col: 1)))
    }

    func testSelectionText() {
        let t = Terminal(cols: 5, rows: 3, scrollback: 10)
        t.feed("abcdefg\r\nxy")
        let sel = Selection(anchor: GridPoint(line: 0, col: 2), head: GridPoint(line: 2, col: 0), mode: .character, onAlternate: false)
        XCTAssertEqual(t.text(of: sel), "cdefg\nx")
    }

    func testWordBounds() {
        let t = Terminal(cols: 20, rows: 2, scrollback: 10)
        t.feed("foo bar/baz.qux end")
        let (a, b) = t.wordBounds(at: GridPoint(line: 0, col: 5), separators: " /")
        XCTAssertEqual(a.col, 4); XCTAssertEqual(b.col, 6)
    }

    func testLegacyKeys() {
        let ctx = KeyEncoder.Context()
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .char(0x61), mods: .ctrl, text: "a"), ctx), [0x01])
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .up, mods: [], text: ""), ctx), Array("\u{1B}[A".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .up, mods: [], text: ""), KeyEncoder.Context(cursorKeysApp: true)), Array("\u{1B}OA".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .right, mods: [.ctrl, .shift], text: ""), ctx), Array("\u{1B}[1;6C".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .char(0x62), mods: .alt, text: "∫", unmodifiedText: "b"), ctx), Array("\u{1B}b".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .f(5), mods: [], text: ""), ctx), Array("\u{1B}[15~".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .tab, mods: .shift, text: ""), ctx), Array("\u{1B}[Z".utf8))
    }

    func testKittyKeys() {
        let ctx = KeyEncoder.Context(kittyFlags: 1)
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .escape, mods: [], text: ""), ctx), Array("\u{1B}[27u".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .char(0x61), mods: [], text: "a"), ctx), Array("a".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .char(0x61), mods: .ctrl, text: "a"), ctx), Array("\u{1B}[97;5u".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .enter, mods: .shift, text: "\r"), ctx), Array("\u{1B}[13;2u".utf8))
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .up, mods: [], text: ""), ctx), Array("\u{1B}[A".utf8))
        let all = KeyEncoder.Context(kittyFlags: 1 | 2 | 8)
        XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .char(0x61), mods: [], text: "a", event: .release), all), Array("\u{1B}[97;1:3u".utf8))
    }
}
