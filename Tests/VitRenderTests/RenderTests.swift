import XCTest
import Metal
@testable import VitRender
@testable import VitCore

/// Renders terminals offscreen through the real Metal pipeline and checks pixels.
final class RenderTests: XCTestCase {
    static let bg: UInt32 = 0x202020, fg: UInt32 = 0xEEEEEE, cursor: UInt32 = 0x00FF00
    static let palette: [UInt32] = [0x000000, 0xFF0000, 0x00CC00, 0xCCCC00, 0x0000FF, 0xCC00CC, 0x00CCCC, 0xCCCCCC,
                                    0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF]
    let pad = 6
    var renderer: TerminalRenderer!

    override func setUpWithError() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        renderer = TerminalRenderer(spec: FontSpec(family: "", size: 13), scale: 2)
    }

    func terminal(_ cols: Int = 12, _ rows: Int = 4) -> Terminal {
        let t = Terminal(cols: cols, rows: rows, scrollback: 100)
        t.applyColors(ansi: RenderTests.palette, foreground: RenderTests.fg, background: RenderTests.bg, cursor: RenderTests.cursor)
        return t
    }

    struct Pixels {
        let w: Int, h: Int, data: [UInt8]
        func rgb(_ x: Int, _ y: Int) -> UInt32 {
            let i = (y * w + x) * 4
            return UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
        }
    }

    func options(focused: Bool = true) -> RenderOptions {
        var o = RenderOptions()
        o.paddingX = CGFloat(pad); o.paddingY = CGFloat(pad)
        o.focused = focused
        o.selectionBackground = 0x0000FF
        return o
    }

    func render(_ t: Terminal, overlay: RenderOverlay = RenderOverlay(), options o: RenderOptions? = nil) -> Pixels {
        let size = CGSize(width: t.cols * renderer.cellWidth + 2 * pad, height: t.rows * renderer.cellHeight + 2 * pad)
        let img = renderer.renderImage(terminal: t, overlay: overlay, options: o ?? options(), size: size)!
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Pixels(w: w, h: h, data: data)
    }

    func center(_ col: Int, _ row: Int) -> (Int, Int) {
        (pad + col * renderer.cellWidth + renderer.cellWidth / 2, pad + row * renderer.cellHeight + renderer.cellHeight / 2)
    }

    /// Pixels in a cell that differ clearly from the background.
    func ink(_ p: Pixels, _ col: Int, _ row: Int, bg: UInt32 = RenderTests.bg) -> Int {
        var n = 0
        for y in (pad + row * renderer.cellHeight)..<(pad + (row + 1) * renderer.cellHeight) {
            for x in (pad + col * renderer.cellWidth)..<(pad + (col + 1) * renderer.cellWidth) where distance(p.rgb(x, y), bg) > 60 {
                n += 1
            }
        }
        return n
    }

    func distance(_ a: UInt32, _ b: UInt32) -> Int {
        abs(Int(a >> 16 & 0xFF) - Int(b >> 16 & 0xFF)) + abs(Int(a >> 8 & 0xFF) - Int(b >> 8 & 0xFF)) + abs(Int(a & 0xFF) - Int(b & 0xFF))
    }

    func assertColor(_ p: Pixels, _ xy: (Int, Int), _ expected: UInt32, tolerance: Int = 6, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let got = p.rgb(xy.0, xy.1)
        XCTAssertLessThanOrEqual(distance(got, expected), tolerance,
                                 "\(msg) at \(xy): got #\(String(got, radix: 16)) expected #\(String(expected, radix: 16))", file: file, line: line)
    }

    // MARK: Tests

    func testBackgroundAndPadding() {
        let t = terminal()
        t.feed("\u{1B}[?25l")
        let p = render(t)
        assertColor(p, (1, 1), RenderTests.bg, "padding")
        assertColor(p, center(5, 2), RenderTests.bg, "empty cell")
        assertColor(p, (p.w - 2, p.h - 2), RenderTests.bg, "bottom-right padding")
    }

    func testCellBackgroundColors() {
        let t = terminal()
        t.feed("\u{1B}[41m \u{1B}[48;5;21m \u{1B}[48;2;10;200;30m \u{1B}[0m \u{1B}[7m \u{1B}[?25l")
        let p = render(t)
        assertColor(p, center(0, 0), 0xFF0000, "palette red")
        assertColor(p, center(1, 0), Terminal.xtermPalette[21], "256-color")
        assertColor(p, center(2, 0), 0x0AC81E, "truecolor")
        assertColor(p, center(3, 0), RenderTests.bg, "reset")
        assertColor(p, center(4, 0), RenderTests.fg, "inverse space shows foreground as background")
    }

    func testGlyphsDrawInk() {
        let t = terminal()
        t.feed("A.\u{1B}[8mZ\u{1B}[?25l")
        let p = render(t)
        XCTAssertGreaterThan(ink(p, 0, 0), 40, "'A' should have ink")
        XCTAssertGreaterThan(ink(p, 1, 0), 3, "'.' has a little ink")
        XCTAssertEqual(ink(p, 2, 0), 0, "invisible (SGR 8) text draws nothing")
        XCTAssertEqual(ink(p, 3, 0), 0)
    }

    func testFaintTextIsDimmer() {
        let t = terminal()
        t.feed("█\u{1B}[2m█\u{1B}[?25l")
        let p = render(t)
        let normal = p.rgb(center(0, 0).0, center(0, 0).1) >> 16, faint = p.rgb(center(1, 0).0, center(1, 0).1) >> 16
        XCTAssertLessThan(faint, normal - 40)
    }

    func testBlockCursor() {
        let t = terminal()
        t.feed("\u{1B}[2;3H")
        let p = render(t)
        assertColor(p, center(2, 1), RenderTests.cursor, "block cursor")
        // Unfocused: hollow outline, empty middle.
        let q = render(t, options: options(focused: false))
        assertColor(q, center(2, 1), RenderTests.bg, "hollow cursor middle")
        let edge = (pad + 2 * renderer.cellWidth + 1, pad + 1 * renderer.cellHeight + renderer.cellHeight / 2)
        assertColor(q, edge, RenderTests.cursor, tolerance: 30, "hollow cursor edge")
    }

    func testCursorTextUsesBackgroundColor() {
        let t = terminal()
        t.feed("█\u{1B}[1;1H")
        let p = render(t)
        // A full block under the block cursor is drawn in the background color on the cursor color.
        assertColor(p, center(0, 0), RenderTests.bg, tolerance: 20, "glyph under cursor")
    }

    func testHiddenCursor() {
        let t = terminal()
        t.feed("\u{1B}[?25l")
        assertColor(render(t), center(0, 0), RenderTests.bg)
    }

    func testCursorShapes() {
        let t = terminal()
        t.feed("\u{1B}[6 q")   // steady bar
        let p = render(t)
        assertColor(p, (pad + 1, center(0, 0).1), RenderTests.cursor, tolerance: 20, "bar at left edge")
        assertColor(p, center(0, 0), RenderTests.bg, "bar leaves the middle empty")
        t.feed("\u{1B}[4 q")   // steady underline
        let q = render(t)
        assertColor(q, (center(0, 0).0, pad + renderer.cellHeight - 2), RenderTests.cursor, tolerance: 20, "underline at bottom")
        assertColor(q, center(0, 0), RenderTests.bg)
    }

    func testSelectionHighlight() {
        let t = terminal()
        t.feed("\u{1B}[?25l")
        var o = RenderOverlay()
        let top = t.grid.absolute(screenRow: 0)
        o.selection = Selection(anchor: GridPoint(line: top, col: 2), head: GridPoint(line: top + 1, col: 1), mode: .character, onAlternate: false)
        let p = render(t, overlay: o)
        assertColor(p, center(1, 0), RenderTests.bg, "before selection")
        assertColor(p, center(2, 0), 0x0000FF, "selection start")
        assertColor(p, center(11, 0), 0x0000FF, "selection continues to end of line")
        assertColor(p, center(1, 1), 0x0000FF, "selection end")
        assertColor(p, center(2, 1), RenderTests.bg, "after selection")
        // Block selection is a rectangle.
        o.selection?.mode = .block
        let b = render(t, overlay: o)
        assertColor(b, center(5, 0), RenderTests.bg, "outside block columns")
        assertColor(b, center(1, 0), 0x0000FF, "inside block columns")
    }

    func testSearchHighlights() {
        let t = terminal()
        t.feed("ab ab\u{1B}[?25l")
        var o = RenderOverlay()
        o.matches = t.search("ab")
        o.currentMatch = 1
        XCTAssertEqual(o.matches.count, 2)
        let p = render(t, overlay: o)
        assertColor(p, (pad + 1, center(0, 0).1 + renderer.cellHeight / 2 - 2), 0xE5C07B, tolerance: 10, "match")
        assertColor(p, (pad + 3 * renderer.cellWidth + 1, center(3, 0).1 + renderer.cellHeight / 2 - 2), 0xF08C3C, tolerance: 10, "current match")
    }

    func testUnderlineAndStrikethroughPositions() {
        let t = terminal()
        t.feed("\u{1B}[4m \u{1B}[0m \u{1B}[9m \u{1B}[0m\u{1B}[?25l")
        let p = render(t)
        let f = renderer.fonts
        let cx = center(0, 0).0
        assertColor(p, (cx, pad + f.underlinePosition), RenderTests.fg, tolerance: 20, "underline")
        assertColor(p, center(0, 0), RenderTests.bg, "no ink in the middle of an underlined space")
        assertColor(p, (center(1, 0).0, pad + f.underlinePosition), RenderTests.bg, "no underline on plain cell")
        assertColor(p, (center(2, 0).0, pad + f.strikePosition), RenderTests.fg, tolerance: 20, "strikethrough")
    }

    func testColoredAndCurlyUnderline() {
        let t = terminal()
        t.feed("\u{1B}[4:3;58:2::255:0:0m      \u{1B}[0m\u{1B}[?25l")
        let p = render(t)
        // Somewhere in the band around the underline position there is red ink.
        var red = 0
        for y in (pad + renderer.fonts.underlinePosition - 6)..<(pad + renderer.cellHeight) {
            for x in pad..<(pad + 6 * renderer.cellWidth) where distance(p.rgb(x, y), 0xFF0000) < 120 { red += 1 }
        }
        XCTAssertGreaterThan(red, 20, "curly red underline")
    }

    func testReverseVideoMode() {
        let t = terminal()
        t.feed("\u{1B}[?5h\u{1B}[?25l")
        assertColor(render(t), center(3, 1), RenderTests.fg, "background becomes the foreground color")
    }

    func testWideCharacterSpansTwoCells() {
        let t = terminal()
        t.feed("中\u{1B}[?25l")
        let p = render(t)
        XCTAssertGreaterThan(ink(p, 0, 0), 20)
        XCTAssertGreaterThan(ink(p, 1, 0), 20, "the glyph extends into the second cell")
        XCTAssertEqual(ink(p, 2, 0), 0)
    }

    func testBoxDrawingTilesAcrossCells() {
        let t = terminal()
        t.feed("──────\u{1B}[?25l")
        let p = render(t)
        // Find the inked row in the first cell and check it's continuous across all six cells.
        let cy = (pad..<(pad + renderer.cellHeight)).first { y in distance(p.rgb(pad + 2, y), RenderTests.bg) > 60 }
        XCTAssertNotNil(cy)
        if let y = cy {
            for x in pad..<(pad + 6 * renderer.cellWidth) {
                XCTAssertGreaterThan(distance(p.rgb(x, y), RenderTests.bg), 60, "gap at x=\(x)")
            }
        }
    }

    func testInlineImage() {
        let t = terminal()
        t.cellPixelWidth = renderer.cellWidth
        t.cellPixelHeight = renderer.cellHeight
        let red = Data([255, 0, 0, 255, 0, 0, 255, 0, 0, 255, 0, 0]).base64EncodedString()
        t.feed("\u{1B}_Ga=T,f=24,s=2,v=2,c=3,r=2,q=2;\(red)\u{1B}\\\u{1B}[?25l")
        let p = render(t)
        assertColor(p, center(0, 0), 0xFF0000, tolerance: 10, "image")
        assertColor(p, center(2, 1), 0xFF0000, tolerance: 10, "image stretched over 3x2 cells")
        assertColor(p, center(4, 0), RenderTests.bg, "outside the image")
    }

    func testOverlays() {
        let t = terminal()
        t.feed("\u{1B}[?25l")
        var o = options()
        o.broadcastBorder = 0xFF0000
        let p = render(t, options: o)
        XCTAssertGreaterThan(p.rgb(1, p.h / 2) >> 16, 0xB0, "broadcast border")
        assertColor(p, center(5, 2), RenderTests.bg, "border only at the edges")
        var d = options()
        d.dim = 0.5
        d.focused = false
        let q = render(t, options: d)
        assertColor(q, center(5, 2), RenderTests.bg, "dimming with the background color keeps empty cells unchanged")
    }

    func testIMEMarkedTextIsDrawnAtCursor() {
        let t = terminal()
        t.feed("ab")
        var o = RenderOverlay()
        o.markedText = "日本"
        let p = render(t, overlay: o)
        XCTAssertGreaterThan(ink(p, 2, 0), 20, "preedit text")
        XCTAssertGreaterThan(ink(p, 4, 0), 20)
    }

    func testScrolledViewportShowsScrollbackAndIndicator() {
        let t = terminal(12, 3)
        for i in 0..<10 { t.feed("\u{1B}[4\(i % 8)m\(i)\u{1B}[K\u{1B}[0m\r\n") }
        t.feed("\u{1B}[?25l")
        t.scrollOffset = 5
        let p = render(t)
        // Row 0 now shows line "3" (bg palette[3]).
        assertColor(p, center(5, 0), RenderTests.palette[3], tolerance: 10, "scrollback line")
        // A scroll position indicator appears at the right edge.
        let x = p.w - 4
        XCTAssertTrue((0..<p.h).contains { distance(p.rgb(x, $0), RenderTests.bg) > 20 }, "scroll indicator")
    }

    // MARK: Caching

    func testRowShapesAreCachedUntilALineChanges() {
        let t = terminal(20, 5)
        t.feed("one\r\ntwo\r\nthree\u{1B}[?25l")
        let size = CGSize(width: 400, height: 300)
        let first = renderer.prepareFrame(terminal: t, overlay: RenderOverlay(), options: options(), size: size)
        XCTAssertEqual(first.shapedRows, 5)
        let second = renderer.prepareFrame(terminal: t, overlay: RenderOverlay(), options: options(), size: size)
        XCTAssertEqual(second.shapedRows, 0)
        XCTAssertEqual(second.cachedRows, 5)
        XCTAssertEqual(second.glyphs, 3 + 3 + 5)
        t.feed("\u{1B}[2;1Hxx")
        let third = renderer.prepareFrame(terminal: t, overlay: RenderOverlay(), options: options(), size: size)
        XCTAssertEqual(third.shapedRows, 1, "only the edited line is reshaped")
        XCTAssertEqual(third.glyphs, 3 + 3 + 5)
    }

    /// The renderer must only read the meaningful part of each line (released cells are poisoned).
    func testRendererIgnoresReleasedCells() {
        Line.poisonReleasedCells = true
        defer { Line.poisonReleasedCells = false }
        let t = terminal(30, 6)
        for i in 0..<200 { t.feed(String(repeating: "w", count: (i * 7) % 29) + "\r\n") }
        t.feed("tail\u{1B}[?25l")
        let stats = renderer.prepareFrame(terminal: t, overlay: RenderOverlay(), options: options(), size: CGSize(width: 800, height: 400))
        let expected = t.screenText().filter { $0 != " " && $0 != "\n" }.count
        XCTAssertEqual(stats.glyphs, expected)
    }
}
