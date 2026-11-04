import XCTest
import Metal
import CoreText
@testable import VitRender
@testable import VitCore

/// Fonts are pixel-sized at scale 2 using the system monospaced font, which exists on every Mac.
func testFonts(family: String = "", ligatures: Bool = true) -> FontSet {
    FontSet(spec: FontSpec(family: family, size: 13, ligatures: ligatures), scale: 2)
}

/// Cells of the first screen row after feeding `text` to a fresh terminal.
func cells(_ text: String, cols: Int = 40) -> [Cell] {
    let t = Terminal(cols: cols, rows: 2)
    t.feed(text)
    let line = t.grid.screenLine(0)
    return (0..<cols).map { line[$0] }
}

func shape(_ shaper: Shaper, _ row: [Cell], breakAt: Int = -1, graphemes: GraphemeTable? = nil) -> [ShapedGlyph] {
    var out: [ShapedGlyph] = []
    row.withUnsafeBufferPointer { p in
        shaper.shape(cells: p.baseAddress!, count: row.count,
                     grapheme: { graphemes?.scalars($0) ?? [0xFFFD] }, breakAt: breakAt, into: &out)
    }
    return out
}

var firaCodeInstalled: Bool {
    let f = CTFontCreateWithName("Fira Code" as CFString, 12, nil)
    return (CTFontCopyFamilyName(f) as String) == "Fira Code"
}

final class ShaperTests: XCTestCase {
    func testSpacesAndEmptyCellsProduceNoGlyphs() {
        let s = Shaper(fonts: testFonts())
        let g = shape(s, cells("ab  cd"))
        XCTAssertEqual(g.map(\.col), [0, 1, 4, 5])
        XCTAssertTrue(g.allSatisfy { $0.glyph != 0 && $0.special == 0 })
    }

    func testStylesUseTheirOwnFace() {
        let s = Shaper(fonts: testFonts())
        let g = shape(s, cells("a\u{1B}[1mb\u{1B}[3mc\u{1B}[22md"))
        XCTAssertEqual(g.map(\.font), [0, 1, 3, 2]) // regular, bold, bold italic, italic
    }

    func testWideCharactersSpanTwoCells() {
        let fonts = testFonts()
        let s = Shaper(fonts: fonts)
        let g = shape(s, cells("中a"))
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g[0].col, 0)
        XCTAssertEqual(g[0].span, 2)
        XCTAssertEqual(g[1].col, 2)
        // SF Mono has no CJK: the glyph comes from a fallback font.
        XCTAssertGreaterThanOrEqual(Int(g[0].font), 4)
        XCTAssertTrue(fonts.fonts.count > 4)
    }

    func testCombiningMarksStayInTheirCell() {
        let t = Terminal(cols: 10, rows: 1)
        t.feed("e\u{301}x")
        let row = (0..<10).map { t.grid.screenLine(0)[$0] }
        let g = shape(Shaper(fonts: testFonts()), row, graphemes: t.graphemes)
        XCTAssertFalse(g.isEmpty)
        XCTAssertTrue(g.dropLast().allSatisfy { $0.col == 0 }, "\(g.map(\.col))")
        XCTAssertEqual(g.last?.col, 1)
    }

    func testBoxDrawingIsProcedural() {
        let g = shape(Shaper(fonts: testFonts()), cells("┌─┐█"))
        XCTAssertEqual(g.map(\.special), [0x250C, 0x2500, 0x2510, 0x2588])
        XCTAssertEqual(g.map(\.col), [0, 1, 2, 3])
    }

    func testRunCacheReturnsIdenticalResults() {
        let s = Shaper(fonts: testFonts())
        let row = cells("let x = foo(bar) -> baz != qux && 日本 ok", cols: 60)
        let first = shape(s, row)
        let missesAfterFirst = s.runCacheMisses
        let second = shape(s, row)
        XCTAssertEqual(s.runCacheMisses, missesAfterFirst, "second shaping must be served from the cache")
        XCTAssertGreaterThan(s.runCacheHits, 0)
        XCTAssertEqual(first.map(\.glyph), second.map(\.glyph))
        XCTAssertEqual(first.map(\.col), second.map(\.col))
        // Same text at a different column offset reuses the cache and shifts columns.
        let shifted = shape(s, cells("   let x = foo(bar) -> baz != qux && 日本 ok", cols: 60))
        XCTAssertEqual(shifted.map(\.glyph), first.map(\.glyph))
        XCTAssertEqual(shifted.map { $0.col - 3 }, first.map(\.col))
        // A fresh shaper (no cache) agrees.
        XCTAssertEqual(shape(Shaper(fonts: testFonts()), row).map(\.glyph), first.map(\.glyph))
    }

    func testRunCacheDistinguishesStyles() {
        let s = Shaper(fonts: testFonts())
        let plain = shape(s, cells("x->y"))
        let bold = shape(s, cells("\u{1B}[1mx->y"))
        XCTAssertNotEqual(plain.map(\.font), bold.map(\.font))
    }

    func testLigaturesWithFiraCode() throws {
        try XCTSkipUnless(firaCodeInstalled, "Fira Code not installed")
        let lig = Shaper(fonts: testFonts(family: "Fira Code", ligatures: true))
        let plain = Shaper(fonts: testFonts(family: "Fira Code", ligatures: false))
        let row = cells("a -> b")
        let withLig = shape(lig, row), without = shape(plain, row)
        // Both shapes cover the same cells, but the arrow uses different (contextual) glyphs.
        XCTAssertEqual(Set(withLig.map(\.col)), Set(without.map(\.col)))
        let arrowLig = withLig.filter { $0.col == 2 || $0.col == 3 }.map(\.glyph)
        let arrowPlain = without.filter { $0.col == 2 || $0.col == 3 }.map(\.glyph)
        XCTAssertNotEqual(arrowLig, arrowPlain, "ligature should change the arrow's glyphs")
        // A run boundary at the cursor prevents the ligature from forming across it.
        let split = shape(lig, row, breakAt: 3)
        XCTAssertEqual(split.filter { $0.col == 2 || $0.col == 3 }.map(\.glyph), arrowPlain)
    }
}

final class AtlasTests: XCTestCase {
    var device: MTLDevice!

    override func setUpWithError() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        device = d
    }

    func testShelfPackerNeverOverlaps() {
        var p = ShelfPacker(width: 100, height: 60)
        var rects: [CGRect] = []
        var rng = SystemRandomNumberGenerator()
        while true {
            let w = Int.random(in: 3...30, using: &rng), h = Int.random(in: 3...20, using: &rng)
            guard let (x, y) = p.alloc(w, h) else { break }
            let r = CGRect(x: x, y: y, width: w, height: h)
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 100, height: 60).contains(r))
            XCTAssertFalse(rects.contains { $0.intersects(r) }, "overlap at \(r)")
            rects.append(r)
        }
        XCTAssertGreaterThan(rects.count, 5)
        XCTAssertNil(p.alloc(101, 1), "wider than the atlas")
    }

    func testGlyphEntriesAreStableAndDeduplicated() {
        let fonts = testFonts()
        let atlas = GlyphAtlas(device: device, fonts: fonts, thicken: false)
        let g = fonts.glyph(for: 0x41, style: 0)!
        let a = atlas.entry(font: g.font, glyph: g.glyph, span: 1)
        XCTAssertFalse(a.isEmpty)
        XCTAssertLessThanOrEqual(Int(a.h), fonts.cellHeight * 2)
        let b = atlas.entry(font: g.font, glyph: g.glyph, span: 1)
        XCTAssertEqual(a.x, b.x); XCTAssertEqual(a.y, b.y)
        // Space has no ink.
        let sp = fonts.glyph(for: 0x20, style: 0)!
        XCTAssertTrue(atlas.entry(font: sp.font, glyph: sp.glyph, span: 1).isEmpty)
    }

    func testAtlasGrowthKeepsExistingEntriesValid() {
        let fonts = testFonts()
        let atlas = GlyphAtlas(device: device, fonts: fonts, thicken: false)
        let g = fonts.glyph(for: 0x57, style: 0)!
        let first = atlas.entry(font: g.font, glyph: g.glyph, span: 1)
        let startWidth = atlas.gray.width
        // Rasterize thousands of CJK glyphs to force growth.
        for cp in UInt32(0x4E00)..<UInt32(0x4E00 + 3000) {
            if let h = fonts.glyph(for: cp, style: 0) { _ = atlas.entry(font: h.font, glyph: h.glyph, span: 2) }
        }
        XCTAssertGreaterThan(atlas.gray.width, startWidth, "atlas should have grown")
        XCTAssertEqual(atlas.generation, 0, "growth must not invalidate entries")
        let again = atlas.entry(font: g.font, glyph: g.glyph, span: 1)
        XCTAssertEqual(first.x, again.x); XCTAssertEqual(first.y, again.y)
        // The glyph's pixels were preserved by the copy into the larger texture.
        var px = [UInt8](repeating: 0, count: Int(first.w) * Int(first.h))
        atlas.gray.getBytes(&px, bytesPerRow: Int(first.w), from: MTLRegionMake2D(Int(first.x), Int(first.y), Int(first.w), Int(first.h)), mipmapLevel: 0)
        XCTAssertGreaterThan(px.filter { $0 > 128 }.count, 10)
        atlas.reset()
        XCTAssertEqual(atlas.generation, 1)
    }

    func testColorEmojiUsesColorAtlas() {
        let fonts = testFonts()
        let atlas = GlyphAtlas(device: device, fonts: fonts, thicken: false)
        guard let g = fonts.glyph(for: 0x1F600, style: 0) else { return XCTFail("no emoji glyph") }
        XCTAssertTrue(fonts.isColorFont(g.font))
        let e = atlas.entry(font: g.font, glyph: g.glyph, span: 2)
        XCTAssertTrue(e.isColor)
        // Fitted inside two cells.
        XCTAssertLessThanOrEqual(Int(e.w), fonts.cellWidth * 2 + 2)
        XCTAssertLessThanOrEqual(Int(e.h), fonts.cellHeight + 2)
    }

    func testCellMetricsAreSane() {
        let f = testFonts()
        XCTAssertGreaterThan(f.cellWidth, 10)
        XCTAssertGreaterThan(f.cellHeight, f.cellWidth)
        XCTAssertTrue((0..<f.cellHeight).contains(f.baseline))
        XCTAssertTrue((f.baseline..<f.cellHeight).contains(f.underlinePosition))
        XCTAssertTrue((0..<f.baseline).contains(f.strikePosition))
    }
}

/// Procedurally drawn box-drawing glyphs must connect seamlessly with their neighbors.
final class BoxDrawingTests: XCTestCase {
    struct Bitmap {
        let w: Int, h: Int
        var px: [UInt8]
        func ink(_ x: Int, _ y: Int) -> Bool { px[y * w + x] > 127 }
        /// Ink runs along an edge: (count of inked pixels, number of separate runs).
        func edge(_ side: Int) -> (count: Int, runs: Int) {
            let n = side == 0 || side == 2 ? w : h
            var count = 0, runs = 0, prev = false
            for i in 0..<n {
                let on: Bool
                switch side {
                case 0: on = ink(i, 0)          // top
                case 1: on = ink(w - 1, i)      // right
                case 2: on = ink(i, h - 1)      // bottom
                default: on = ink(0, i)         // left
                }
                if on { count += 1; if !prev { runs += 1 } }
                prev = on
            }
            return (count, runs)
        }
    }

    func draw(_ cp: UInt32, w: Int = 18, h: Int = 37, line: Int = 2) -> Bitmap? {
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            return BoxDrawing.draw(cp, in: ctx, width: w, height: h, lineWidth: line)
        }
        return ok ? Bitmap(w: w, h: h, px: px) : nil
    }

    func testLineCharactersTouchExactlyTheirEdges() {
        for (w, h, lw) in [(18, 37, 2), (17, 34, 1), (20, 41, 3)] {
            for (cp, weights) in BoxDrawing.lines {
                guard let b = draw(cp, w: w, h: h, line: lw) else { XCTFail("U+\(String(cp, radix: 16)) not drawn"); continue }
                let dirs = [weights.0, weights.1, weights.2, weights.3] // up, right, down, left
                for side in 0..<4 {
                    let (count, runs) = b.edge(side)
                    let name = "U+\(String(cp, radix: 16, uppercase: true)) side \(side) at \(w)x\(h)/\(lw)"
                    switch dirs[side] {
                    case 0: XCTAssertEqual(count, 0, "\(name): unexpected ink")
                    case 1: XCTAssertEqual(runs, 1, name); XCTAssertEqual(count, lw, "\(name): light width")
                    case 2: XCTAssertEqual(runs, 1, name); XCTAssertEqual(count, lw * 2, "\(name): heavy width")
                    default: XCTAssertEqual(runs, 2, "\(name): double line"); XCTAssertEqual(count, lw * 2, name)
                    }
                }
            }
        }
    }

    /// Opposite edges line up, so adjacent cells join without a step.
    func testHorizontalAndVerticalContinuity() {
        for cp: UInt32 in [0x2500, 0x2501, 0x2550, 0x253C, 0x254B, 0x256C] {
            let b = draw(cp)!
            let left = (0..<b.h).filter { b.ink(0, $0) }, right = (0..<b.h).filter { b.ink(b.w - 1, $0) }
            XCTAssertEqual(left, right, "U+\(String(cp, radix: 16)) left/right edges misaligned")
        }
        for cp: UInt32 in [0x2502, 0x2503, 0x2551, 0x253C, 0x254B, 0x256C] {
            let b = draw(cp)!
            let top = (0..<b.w).filter { b.ink($0, 0) }, bottom = (0..<b.w).filter { b.ink($0, b.h - 1) }
            XCTAssertEqual(top, bottom, "U+\(String(cp, radix: 16)) top/bottom edges misaligned")
        }
    }

    func testBlockElementsFillTheRightFraction() {
        func coverage(_ cp: UInt32) -> Double {
            let b = draw(cp, w: 16, h: 32)!
            return Double(b.px.reduce(0) { $0 + Int($1) }) / Double(255 * b.px.count)
        }
        XCTAssertEqual(coverage(0x2588), 1, accuracy: 0.001)     // █
        XCTAssertEqual(coverage(0x2580), 0.5, accuracy: 0.04)    // ▀
        XCTAssertEqual(coverage(0x2584), 0.5, accuracy: 0.04)    // ▄
        XCTAssertEqual(coverage(0x258C), 0.5, accuracy: 0.04)    // ▌
        XCTAssertEqual(coverage(0x2581), 1.0 / 8, accuracy: 0.04) // ▁
        XCTAssertEqual(coverage(0x2591), 0.25, accuracy: 0.03)   // ░
        XCTAssertEqual(coverage(0x2592), 0.5, accuracy: 0.03)    // ▒
        XCTAssertEqual(coverage(0x2593), 0.75, accuracy: 0.03)   // ▓
        XCTAssertEqual(coverage(0x2599), 0.75, accuracy: 0.04)   // ▙
        let upper = draw(0x2580, w: 16, h: 32)!
        XCTAssertTrue(upper.ink(8, 2) && !upper.ink(8, 29), "▀ fills the top half only")
    }

    func testPowerlineTriangles() {
        let b = draw(0xE0B0)!
        XCTAssertEqual(b.edge(3).count, b.h, "left edge fully inked")
        XCTAssertLessThan(b.edge(1).count, 4, "right edge is the triangle's tip")
        let mirrored = draw(0xE0B2)!
        XCTAssertEqual(mirrored.edge(1).count, mirrored.h)
    }

    func testEveryHandledCodepointDraws() {
        var cps: [UInt32] = Array(0x2500...0x259F)
        cps += [0xE0B0, 0xE0B1, 0xE0B2, 0xE0B3, 0xE0B4, 0xE0B6]
        for cp in cps where BoxDrawing.handles(cp) {
            guard let b = draw(cp) else { XCTFail("U+\(String(cp, radix: 16)) not drawn"); continue }
            XCTAssertTrue(b.px.contains { $0 > 0 }, "U+\(String(cp, radix: 16)) drew nothing")
        }
    }
}
