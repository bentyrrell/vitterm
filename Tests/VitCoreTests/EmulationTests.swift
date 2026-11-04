import XCTest
import Compression
@testable import VitCore

/// Escape-sequence behavior, checked against xterm semantics (in the spirit of esctest/vttest).
final class EmulationTests: XCTestCase {
    func term(_ cols: Int = 10, _ rows: Int = 6) -> Terminal { Terminal(cols: cols, rows: rows, scrollback: 50) }
    func row(_ t: Terminal, _ y: Int) -> String { t.text(of: t.grid.screenLine(y)) }
    func replies(_ t: Terminal) -> String {
        defer { t.pendingOutput.removeAll() }
        return String(decoding: t.pendingOutput, as: UTF8.self)
    }
    func events(_ t: Terminal) -> [TerminalEvent] {
        defer { t.pendingEvents.removeAll() }
        return t.pendingEvents
    }

    // MARK: Cursor save/restore and origin mode

    func testSaveRestoreCursorIncludesAttributesAndCharset() {
        let t = term()
        t.feed("\u{1B}[3;4H\u{1B}[1;31m\u{1B}(0\u{1B}7\u{1B}[H\u{1B}[0m\u{1B}(BX\u{1B}8q")
        XCTAssertEqual(t.cursorX, 4); XCTAssertEqual(t.cursorY, 2)
        let restored = t.cell(x: 3, y: 2)
        XCTAssertEqual(restored.codepoint, 0x2500, "DEC special graphics restored: q -> ─")
        XCTAssertTrue(restored.flags.contains(.bold))
        XCTAssertEqual(restored.fg, .palette(1))
        XCTAssertEqual(t.cell(x: 0, y: 0).flags, [], "X was written with the reset pen")
    }

    func testOriginModeConfinesCursorToScrollRegion() {
        let t = term()
        t.feed("\u{1B}[3;5r\u{1B}[?6h\u{1B}[1;1HA\u{1B}[99;1HB")
        XCTAssertEqual(row(t, 2), "A")
        XCTAssertEqual(row(t, 4), "B", "CUP clamps to the region bottom in origin mode")
        t.feed("\u{1B}[2;3H\u{1B}[6n")
        XCTAssertEqual(replies(t), "\u{1B}[2;3R", "CPR is relative to the region in origin mode")
        t.feed("\u{1B}[?6l\u{1B}[1;1HC")
        XCTAssertEqual(row(t, 0), "C", "origin mode off: absolute addressing")
    }

    // MARK: Writing

    func testAutowrapOffOverwritesLastColumn() {
        let t = term(5, 2)
        t.feed("\u{1B}[?7labcdefg")
        XCTAssertEqual(row(t, 0), "abcdg")
        XCTAssertEqual(row(t, 1), "")
        XCTAssertEqual(t.cursorX, 4)
    }

    func testInsertMode() {
        let t = term()
        t.feed("abc\u{1B}[1;1H\u{1B}[4hXY\u{1B}[4lZ")
        XCTAssertEqual(row(t, 0), "XYZbc", "IRM shifts right; replace mode overwrites")
    }

    func testEraseCharactersKeepsCursor() {
        let t = term()
        t.feed("abcdef\u{1B}[1;2H\u{1B}[3X")
        XCTAssertEqual(row(t, 0), "a   ef")
        XCTAssertEqual(t.cursorX, 1)
    }

    func testEraseUsesCurrentBackground() {
        let t = term(5, 2)
        t.feed("\u{1B}[44m\u{1B}[2J")
        XCTAssertEqual(t.cell(x: 3, y: 1).bg, .palette(4), "BCE: erased cells take the current background")
    }

    func testCursorMovementClearsPendingWrap() {
        let t = term(5, 2)
        t.feed("abcde")
        XCTAssertTrue(t.pendingWrap)
        t.feed("\u{1B}[D")
        XCTAssertFalse(t.pendingWrap)
        XCTAssertEqual(t.cursorX, 3)
        t.feed("X")
        XCTAssertEqual(row(t, 0), "abcXe")
    }

    func testNextLineAndIndex() {
        let t = term(5, 3)
        t.feed("ab\u{1B}Ec\u{1B}Dd")
        XCTAssertEqual(row(t, 0), "ab")
        XCTAssertEqual(row(t, 1), "c")
        XCTAssertEqual(row(t, 2), " d", "IND moves down without returning")
    }

    func testRepeatPrecedingCharacterWithWideChar() {
        let t = term(10, 2)
        t.feed("中\u{1B}[2b")
        XCTAssertEqual(row(t, 0), "中中中")
    }

    // MARK: Tabs

    func testTabStops() {
        let t = term(20, 2)
        t.feed("\u{1B}[1;4H\u{1B}H\u{1B}[1;1H\tX")
        XCTAssertEqual(t.cursorX, 4, "custom tab stop at column 3")
        t.feed("\u{1B}[3g\u{1B}[1;1H\tY")
        XCTAssertEqual(t.cell(x: 19, y: 0).codepoint, 0x59, "no stops: tab goes to the last column")
        t.feed("\u{1B}[1;10H\u{1B}H\u{1B}[1;15H\u{1B}[Z")
        XCTAssertEqual(t.cursorX, 9, "CBT goes back to the previous stop")
        t.feed("\u{1B}[1;1H\u{1B}[2I")
        XCTAssertEqual(t.cursorX, 19, "CHT skips forward by stops")
    }

    // MARK: Scrolling

    func testScrollUpDownWithinRegion() {
        let t = term(5, 5)
        t.feed("1\r\n2\r\n3\r\n4\r\n5\u{1B}[2;4r\u{1B}[S")
        XCTAssertEqual((0..<5).map { row(t, $0) }, ["1", "3", "4", "", "5"])
        t.feed("\u{1B}[2T")
        XCTAssertEqual((0..<5).map { row(t, $0) }, ["1", "", "", "3", "5"])
    }

    func testInsertDeleteLinesOutsideRegionAreIgnored() {
        let t = term(5, 5)
        t.feed("1\r\n2\r\n3\r\n4\r\n5\u{1B}[2;3r\u{1B}[5;1H\u{1B}[L\u{1B}[M")
        XCTAssertEqual((0..<5).map { row(t, $0) }, ["1", "2", "3", "4", "5"])
    }

    func testReverseIndexAtTopOfRegion() {
        let t = term(5, 4)
        t.feed("1\r\n2\r\n3\r\n4\u{1B}[2;3r\u{1B}[2;1H\u{1B}M")
        XCTAssertEqual((0..<4).map { row(t, $0) }, ["1", "", "2", "4"])
    }

    func testRegionScrollingDoesNotTouchScrollback() {
        let t = term(5, 4)
        t.feed("\u{1B}[2;4r\u{1B}[4;1H" + String(repeating: "x\n", count: 20))
        XCTAssertEqual(t.primary.scrollbackCount, 0)
    }

    func testViewportStaysAnchoredWhileScrolledBack() {
        let t = term(5, 3)
        for i in 0..<10 { t.feed("\(i)\r\n") }
        t.scrollOffset = 3
        let top = t.primary.line(at: t.primary.scrollbackCount - t.scrollOffset)
        t.feed("a\r\nb\r\n")
        let topAfter = t.primary.line(at: t.primary.scrollbackCount - t.scrollOffset)
        XCTAssertTrue(top === topAfter, "the same content stays at the top of the viewport")
        XCTAssertEqual(t.scrollOffset, 5)
    }

    func testClearScrollback() {
        let t = term(5, 2)
        for i in 0..<10 { t.feed("\(i)\r\n") }
        XCTAssertGreaterThan(t.primary.scrollbackCount, 0)
        t.feed("\u{1B}[3J")
        XCTAssertEqual(t.primary.scrollbackCount, 0)
    }

    // MARK: Screens and resets

    func testAlternateScreenVariants() {
        let t = term(5, 2)
        t.feed("main\u{1B}[?1049h\u{1B}[HALT")
        XCTAssertTrue(t.usingAlternate)
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(row(t, 0), "main")
        t.feed("\u{1B}[?1049h")
        XCTAssertEqual(row(t, 0), "", "1049 clears the alternate screen on entry")
        t.feed("\u{1B}[?1049l\u{1B}[?47h\u{1B}[Hkeep\u{1B}[?47l\u{1B}[?47h")
        XCTAssertEqual(row(t, 0), "keep", "47 does not clear")
        t.feed("\u{1B}[?47l\u{1B}[?1047h\u{1B}[Hgone\u{1B}[?1047l\u{1B}[?1047h")
        XCTAssertEqual(row(t, 0), "", "1047 clears when leaving")
    }

    func testDECALN() {
        let t = term(3, 2)
        t.feed("\u{1B}[2;2r\u{1B}#8")
        XCTAssertEqual(row(t, 0), "EEE")
        XCTAssertEqual(row(t, 1), "EEE")
        XCTAssertEqual(t.scrollBottom, 1, "margins reset")
        XCTAssertEqual(t.cursorX, 0); XCTAssertEqual(t.cursorY, 0)
    }

    func testSoftResetKeepsScreen() {
        let t = term()
        t.feed("text\u{1B}[4h\u{1B}[?7l\u{1B}[?25l\u{1B}[1m\u{1B}[!p")
        XCTAssertEqual(row(t, 0), "text")
        XCTAssertFalse(t.modes.insertMode)
        XCTAssertTrue(t.modes.autowrap)
        XCTAssertTrue(t.modes.cursorVisible)
        XCTAssertEqual(t.pen, Pen())
    }

    func testFullReset() {
        let t = term()
        t.feed("text\u{1B}]4;1;#123456\u{07}\u{1B}[?2004h\u{1B}[3;4r\u{1B}c")
        XCTAssertEqual(row(t, 0), "")
        XCTAssertFalse(t.modes.bracketedPaste)
        XCTAssertEqual(t.scrollTop, 0)
        XCTAssertEqual(t.palette[1], t.basePalette[1], "palette overrides are reset")
    }

    // MARK: Modes

    func testModeFlags() {
        let t = term()
        t.feed("\u{1B}[?1h\u{1B}=\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?2004h\u{1B}[?1004h\u{1B}[?2026h\u{1B}[?2031h\u{1B}[?12h")
        XCTAssertTrue(t.modes.cursorKeysApp)
        XCTAssertTrue(t.modes.keypadApp)
        XCTAssertEqual(t.modes.mouseTracking, .normal)
        XCTAssertEqual(t.modes.mouseEncoding, .sgr)
        XCTAssertTrue(t.modes.bracketedPaste)
        XCTAssertTrue(t.modes.focusEvents)
        XCTAssertTrue(t.modes.synchronizedOutput)
        XCTAssertTrue(t.modes.colorSchemeUpdates)
        XCTAssertEqual(t.modes.cursorBlink, true)
        t.feed("\u{1B}[?1002h")
        XCTAssertEqual(t.modes.mouseTracking, .button)
        t.feed("\u{1B}[?1003h")
        XCTAssertEqual(t.modes.mouseTracking, .any)
        t.feed("\u{1B}[?1003l\u{1B}[?1l\u{1B}>")
        XCTAssertEqual(t.modes.mouseTracking, .none)
        XCTAssertFalse(t.modes.cursorKeysApp)
        XCTAssertFalse(t.modes.keypadApp)
    }

    func testSaveRestorePrivateModes() {
        let t = term()
        t.feed("\u{1B}[?2004h\u{1B}[?2004s\u{1B}[?2004l\u{1B}[?2004r")
        XCTAssertTrue(t.modes.bracketedPaste)
    }

    func testCursorStyle() {
        let t = term()
        t.feed("\u{1B}[5 q")
        XCTAssertEqual(t.cursorShape, .bar)
        XCTAssertEqual(t.cursorShapeBlinks, true)
        t.feed("\u{1B}[2 q")
        XCTAssertEqual(t.cursorShape, .block)
        XCTAssertEqual(t.cursorShapeBlinks, false)
        t.feed("\u{1B}[0 q")
        XCTAssertNil(t.cursorShape, "0 restores the user's default")
    }

    // MARK: Reports

    func testModeReports() {
        let t = term()
        t.feed("\u{1B}[?2004$p")
        XCTAssertEqual(replies(t), "\u{1B}[?2004;2$y")
        t.feed("\u{1B}[?2004h\u{1B}[?2004$p")
        XCTAssertEqual(replies(t), "\u{1B}[?2004;1$y")
        t.feed("\u{1B}[?9999$p")
        XCTAssertEqual(replies(t), "\u{1B}[?9999;0$y")
        t.feed("\u{1B}[4$p")
        XCTAssertEqual(replies(t), "\u{1B}[4;2$y")
    }

    func testIdentificationReplies() {
        let t = term()
        t.feed("\u{1B}[c")
        XCTAssertTrue(replies(t).hasPrefix("\u{1B}[?62;"))
        t.feed("\u{1B}[>c")
        XCTAssertTrue(replies(t).hasPrefix("\u{1B}[>1;"))
        t.feed("\u{1B}[>q")
        XCTAssertEqual(replies(t), "\u{1B}P>|vitterm 0.1.0\u{1B}\\")
        t.feed("\u{1B}[5n")
        XCTAssertEqual(replies(t), "\u{1B}[0n")
    }

    func testWindowReports() {
        let t = term(80, 24)
        t.cellPixelWidth = 9
        t.cellPixelHeight = 18
        t.feed("\u{1B}[18t\u{1B}[16t\u{1B}[14t")
        XCTAssertEqual(replies(t), "\u{1B}[8;24;80t\u{1B}[6;18;9t\u{1B}[4;432;720t")
    }

    func testColorSchemeQuery() {
        let t = term()
        t.applyColors(ansi: [], foreground: 0xFFFFFF, background: 0x101010, cursor: nil)
        t.feed("\u{1B}[?996n")
        XCTAssertEqual(replies(t), "\u{1B}[?997;1n", "dark")
        t.applyColors(ansi: [], foreground: 0x000000, background: 0xFAFAFA, cursor: nil)
        t.feed("\u{1B}[?996n")
        XCTAssertEqual(replies(t), "\u{1B}[?997;2n", "light")
    }

    func testCapabilityQueries() {
        let t = term()
        t.feed("\u{1B}P+q544e;436f;78797a\u{1B}\\")   // TN, Co, xyz
        let r = replies(t)
        XCTAssertTrue(r.contains("1+r544e=" + Terminal.hexEncode("xterm-256color")))
        XCTAssertTrue(r.contains("1+r436f=" + Terminal.hexEncode("256")))
        XCTAssertTrue(r.contains("0+r78797a"), "unknown capability")
        t.feed("\u{1B}P$qm\u{1B}\\")
        XCTAssertEqual(replies(t), "\u{1B}P1$r0m\u{1B}\\")
        t.feed("\u{1B}[3;5r\u{1B}P$qr\u{1B}\\")
        XCTAssertEqual(replies(t), "\u{1B}P1$r3;5r\u{1B}\\")
    }

    // MARK: OSC

    func testTitleStack() {
        let t = term()
        t.feed("\u{1B}]2;one\u{07}\u{1B}[22t\u{1B}]2;two\u{07}")
        XCTAssertEqual(t.title, "two")
        t.feed("\u{1B}[23t")
        XCTAssertEqual(t.title, "one")
    }

    func testWorkingDirectoryReport() {
        let t = term()
        t.feed("\u{1B}]7;file://localhost/Users/me/with%20space\u{07}")
        XCTAssertEqual(t.workingDirectory, "/Users/me/with space")
        t.feed("\u{1B}]7;file:///tmp/a b\u{07}")
        XCTAssertEqual(t.workingDirectory, "/tmp/a b", "unencoded paths are accepted too")
        t.feed("\u{1B}]7;file://some-other-host/etc\u{07}")
        XCTAssertEqual(t.workingDirectory, "/tmp/a b", "directories on other hosts (ssh) are ignored")
        t.feed("\u{1B}]1337;CurrentDir=/var/log\u{07}")
        XCTAssertEqual(t.workingDirectory, "/var/log")
        let cwdEvents = events(t).filter { if case .workingDirectory = $0 { return true }; return false }
        XCTAssertEqual(cwdEvents.count, 3)
    }

    func testClipboard() {
        let t = term()
        t.feed("\u{1B}]52;c;\(Data("hello".utf8).base64EncodedString())\u{07}\u{1B}]52;c;?\u{07}")
        let e = events(t)
        XCTAssertEqual(e.count, 1, "reads are ignored unless allowed")
        if case .clipboardWrite(let s) = e.first { XCTAssertEqual(s, "hello") } else { XCTFail("\(e)") }
        t.allowClipboardRead = true
        t.feed("\u{1B}]52;c;?\u{07}")
        if case .clipboardRead = events(t).first {} else { XCTFail("expected clipboard read") }
        t.replyClipboard("pasted")
        XCTAssertEqual(replies(t), "\u{1B}]52;c;\(Data("pasted".utf8).base64EncodedString())\u{1B}\\")
    }

    func testNotificationsAndProgress() {
        let t = term()
        t.feed("\u{1B}]9;build done\u{07}\u{1B}]777;notify;Title;Body\u{07}\u{1B}]9;4;1;40\u{07}")
        let e = events(t)
        guard e.count == 3 else { return XCTFail("\(e)") }
        if case .notification(let title, let body) = e[0] { XCTAssertEqual(title, ""); XCTAssertEqual(body, "build done") } else { XCTFail() }
        if case .notification(let title, let body) = e[1] { XCTAssertEqual(title, "Title"); XCTAssertEqual(body, "Body") } else { XCTFail() }
        if case .progress(let state, let value) = e[2] { XCTAssertEqual(state, 1); XCTAssertEqual(value, 40) } else { XCTFail() }
    }

    func testDynamicColors() {
        let t = term()
        t.applyColors(ansi: [], foreground: 0xAAAAAA, background: 0x111111, cursor: nil)
        t.feed("\u{1B}]10;#ff0000\u{07}\u{1B}]11;rgb:00/00/ff\u{07}\u{1B}]12;#0f0\u{07}")
        XCTAssertEqual(t.defaultForeground, 0xFF0000)
        XCTAssertEqual(t.defaultBackground, 0x0000FF)
        XCTAssertEqual(t.cursorColor, 0x00FF00)
        t.feed("\u{1B}]11;?\u{07}")
        XCTAssertEqual(replies(t), "\u{1B}]11;rgb:0000/0000/ffff\u{1B}\\")
        t.feed("\u{1B}]110\u{07}\u{1B}]111\u{07}")
        XCTAssertEqual(t.defaultForeground, 0xAAAAAA)
        XCTAssertEqual(t.defaultBackground, 0x111111)
        t.feed("\u{1B}]4;3;#010203;5;#040506\u{07}\u{1B}]104;3\u{07}")
        XCTAssertEqual(t.palette[3], t.basePalette[3])
        XCTAssertEqual(t.palette[5], 0x040506)
    }

    func testColorSpecParsing() {
        XCTAssertEqual(Terminal.parseColor("rgb:f/8/0"), 0xFF8800)
        XCTAssertEqual(Terminal.parseColor("rgb:ffff/8080/0000"), 0xFF8000)
        XCTAssertEqual(Terminal.parseColor("#abc"), 0xAABBCC)
        XCTAssertEqual(Terminal.parseColor("#aabbcc"), 0xAABBCC)
        XCTAssertEqual(Terminal.parseColor("#aaabbbccc"), 0xAABBCC)
        XCTAssertNil(Terminal.parseColor("red"))
        XCTAssertNil(Terminal.parseColor("rgb:1/2"))
    }

    func testPromptMarks() {
        let t = term(10, 3)
        t.feed("\u{1B}]133;A\u{07}$ ls\r\nout\r\n\u{1B}]133;A\u{07}$ pwd\r\nout\r\nx")
        let marks = t.promptLines()
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(t.text(of: t.grid.line(absolute: marks[1])!), "$ pwd")
    }

    func testHyperlinkRanges() {
        let t = term(30, 2)
        t.feed("a \u{1B}]8;id=x;https://a.example\u{1B}\\link\u{1B}]8;;\u{1B}\\ b")
        let l = t.link(at: GridPoint(line: t.grid.absolute(screenRow: 0), col: 4))
        XCTAssertEqual(l?.url, "https://a.example")
        XCTAssertEqual(l?.ranges.first?.cols, 2...5)
        XCTAssertNil(t.link(at: GridPoint(line: t.grid.absolute(screenRow: 0), col: 0)))
    }

    // MARK: Unicode

    func testVariationSelectorWidensInGraphemeMode() {
        let t = term()
        t.feed("\u{1B}[?2027h❤\u{FE0F}x")
        XCTAssertTrue(t.cell(x: 0, y: 0).flags.contains(.wide))
        XCTAssertEqual(t.cell(x: 2, y: 0).codepoint, 0x78)
        // Without grapheme mode, the heart stays one cell (matching wcwidth-based applications).
        let u = term()
        u.feed("❤\u{FE0F}x")
        XCTAssertFalse(u.cell(x: 0, y: 0).flags.contains(.wide))
        XCTAssertEqual(u.cell(x: 1, y: 0).codepoint, 0x78)
    }

    func testRegionalIndicatorPairs() {
        let t = term()
        t.feed("\u{1B}[?2027h🇯🇵🇫🇷")
        XCTAssertEqual(t.string(for: t.cell(x: 0, y: 0)), "🇯🇵")
        XCTAssertEqual(t.string(for: t.cell(x: 1, y: 0)), "🇫🇷")
    }

    func testInvalidUTF8BecomesReplacementCharacter() {
        let t = term()
        t.feed([0x61, 0xFF, 0x62, 0xC3, 0x28])
        XCTAssertEqual(row(t, 0), "a\u{FFFD}b\u{FFFD}(")
    }

    func testC1ControlsInUTF8AreIgnored() {
        let t = term()
        t.feed([0x61, 0xC2, 0x9B, 0x62])  // U+009B (CSI as C1) must not start a sequence
        XCTAssertEqual(row(t, 0), "ab")
    }

    // MARK: Kitty protocols

    func testKittyKeyboardStackPerScreen() {
        let t = term()
        t.feed("\u{1B}[>5u\u{1B}[?1049h")
        XCTAssertEqual(t.kittyKeyboardFlags, 0, "the alternate screen has its own stack")
        t.feed("\u{1B}[>1u\u{1B}[=4;2u")
        XCTAssertEqual(t.kittyKeyboardFlags, 5, "mode 2 ORs flags in")
        t.feed("\u{1B}[=1;3u")
        XCTAssertEqual(t.kittyKeyboardFlags, 4, "mode 3 clears flags")
        t.feed("\u{1B}[?1049l")
        XCTAssertEqual(t.kittyKeyboardFlags, 5)
        t.feed("\u{1B}[<5u")
        XCTAssertEqual(t.kittyKeyboardFlags, 0, "popping more than the stack holds empties it")
    }

    func testKittyGraphicsQueryAndErrors() {
        let t = term()
        let px = Data([1, 2, 3]).base64EncodedString()
        t.feed("\u{1B}_Ga=q,i=31,f=24,s=1,v=1;\(px)\u{1B}\\")
        XCTAssertEqual(replies(t), "\u{1B}_Gi=31;OK\u{1B}\\")
        XCTAssertNil(t.images.images[31], "queries don't store images")
        t.feed("\u{1B}_Ga=t,i=32,f=24,s=5,v=5;\(px)\u{1B}\\")
        XCTAssertTrue(replies(t).hasPrefix("\u{1B}_Gi=32;EBADF"), "too little data for 5x5")
        t.feed("\u{1B}_Ga=p,i=99\u{1B}\\")
        XCTAssertTrue(replies(t).hasPrefix("\u{1B}_Gi=99;ENOENT"))
    }

    func testKittyGraphicsPlacementAndDeletion() {
        let t = term(20, 6)
        t.cellPixelWidth = 10; t.cellPixelHeight = 20
        let px = Data(repeating: 200, count: 30 * 40 * 3).base64EncodedString()
        t.feed("\u{1B}_Ga=T,f=24,s=30,v=40,i=5,q=2;\(px)\u{1B}\\")
        XCTAssertEqual(t.images.placements.first?.cols, 3)
        XCTAssertEqual(t.images.placements.first?.rows, 2)
        XCTAssertEqual(t.cursorX, 3, "cursor moves past the image")
        XCTAssertEqual(t.cursorY, 1)
        t.feed("\u{1B}[5;1H\u{1B}_Ga=p,i=5,C=1,q=2\u{1B}\\")
        XCTAssertEqual(t.images.placements.count, 2)
        XCTAssertEqual(t.cursorX, 0, "C=1 leaves the cursor in place")
        t.feed("\u{1B}_Ga=d,d=y,y=5,q=2\u{1B}\\")
        XCTAssertEqual(t.images.placements.count, 1, "delete placements intersecting row 5")
        t.feed("\u{1B}_Ga=d,d=I,i=5,q=2\u{1B}\\")
        XCTAssertTrue(t.images.placements.isEmpty)
        XCTAssertNil(t.images.images[5], "uppercase deletes free the image data")
    }

    func testKittyGraphicsZlibPayload() throws {
        let t = term()
        let raw = Data([10, 20, 30, 40, 50, 60])                 // 2x1 RGB
        let compressed = try XCTUnwrap(zlibCompress(raw))
        t.feed("\u{1B}_Ga=t,f=24,s=2,v=1,o=z,i=7,q=2;\(compressed.base64EncodedString())\u{1B}\\")
        let img = try XCTUnwrap(t.images.images[7])
        XCTAssertEqual(img.width, 2)
        XCTAssertEqual([UInt8](img.rgba.prefix(4)), [10, 20, 30, 255])
    }

    func testITerm2ImageSizing() {
        let t = term(40, 10)
        t.cellPixelWidth = 10; t.cellPixelHeight = 20
        let png = makePNG(width: 100, height: 40)
        t.feed("\u{1B}]1337;File=inline=1;width=5:\(png.base64EncodedString())\u{07}")
        let p = try! XCTUnwrap(t.images.placements.first)
        XCTAssertEqual(p.cols, 5)
        XCTAssertEqual(p.rows, 1, "aspect ratio preserved: 50px wide -> 20px tall")
        XCTAssertEqual(t.cursorX, 0, "cursor moves to the line after the image")
        // Non-inline files are downloads and are not displayed.
        t.feed("\u{1B}]1337;File=name=eA==:\(png.base64EncodedString())\u{07}")
        XCTAssertEqual(t.images.placements.count, 1)
    }

    // MARK: Helpers

    func zlibCompress(_ data: Data) -> Data? {
        // zlib header + raw deflate + adler32, matching what the protocol sends.
        var out = Data([0x78, 0x9C])
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count + 64)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { compression_encode_buffer(dst, data.count + 64, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) }
        guard n > 0 else { return nil }
        out.append(dst, count: n)
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return out
    }

    func makePNG(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
