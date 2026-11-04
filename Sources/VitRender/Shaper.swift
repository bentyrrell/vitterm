import CoreText
import Foundation
import VitCore

/// One positioned glyph in a row.
struct ShapedGlyph {
    var col: Int32          // cell column of the glyph's cluster
    var font: UInt16
    var glyph: CGGlyph
    var dx: Float           // pixel offset from the cell's left edge
    var dy: Float
    var special: UInt32     // non-zero: procedurally drawn codepoint
    var span: UInt8         // cells covered by the cluster (for emoji fitting)
}

/// Shapes rows of cells into glyphs. Breaks runs at style changes, spaces and procedurally drawn
/// characters; uses CoreText for anything that might ligate or needs complex shaping.
final class Shaper {
    let fonts: FontSet
    private var utf16: [UniChar] = []

    init(fonts: FontSet) {
        self.fonts = fonts
        utf16.reserveCapacity(512)
    }

    /// Characters that can participate in programming ligatures.
    @inline(__always) static func ligatureProne(_ b: UInt32) -> Bool {
        switch b {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E: return true
        default: return false
        }
    }

    /// Shape a row. `cells` has `count` entries; `grapheme` resolves grapheme-table indices.
    /// `breakAt` (e.g. the cursor column) forces a run boundary so ligatures don't straddle it.
    func shape(cells: UnsafePointer<Cell>, count: Int, grapheme: (UInt32) -> [UInt32], breakAt: Int, into out: inout [ShapedGlyph]) {
        out.removeAll(keepingCapacity: true)
        var col = 0
        while col < count {
            let c = cells[col]
            if c.flags.contains(.wideSpacer) || (c.codepoint == 0 && !c.flags.contains(.grapheme)) || (c.codepoint == 0x20 && !c.flags.contains(.grapheme)) {
                col += 1
                continue
            }
            if !c.flags.contains(.grapheme) && BoxDrawing.handles(c.codepoint) {
                out.append(ShapedGlyph(col: Int32(col), font: 0, glyph: 0, dx: 0, dy: 0, special: c.codepoint, span: 1))
                col += 1
                continue
            }
            // Gather a run.
            let style = fonts.style(bold: c.flags.contains(.bold), italic: c.flags.contains(.italic))
            let start = col
            var simple = true      // only ASCII and no ligature candidates
            var end = col
            while end < count {
                let e = cells[end]
                if e.flags.contains(.wideSpacer) { end += 1; continue }
                if end > start && end == breakAt { break }
                if end == breakAt + 1 && end > start && breakAt >= 0 { break }
                let isGrapheme = e.flags.contains(.grapheme)
                if !isGrapheme && (e.codepoint == 0 || e.codepoint == 0x20) { break }
                if !isGrapheme && BoxDrawing.handles(e.codepoint) { break }
                if fonts.style(bold: e.flags.contains(.bold), italic: e.flags.contains(.italic)) != style { break }
                if isGrapheme || e.codepoint >= 0x80 { simple = false }
                else if fonts.ligatures && Shaper.ligatureProne(e.codepoint) { simple = false }
                end += 1
            }
            if simple {
                shapeSimple(cells: cells, from: start, to: end, style: style, into: &out)
            } else {
                shapeCoreText(cells: cells, from: start, to: end, style: style, grapheme: grapheme, into: &out)
            }
            col = end
        }
    }

    private func shapeSimple(cells: UnsafePointer<Cell>, from: Int, to: Int, style: Int, into out: inout [ShapedGlyph]) {
        for col in from..<to {
            let c = cells[col]
            if c.flags.contains(.wideSpacer) { continue }
            if let (f, g) = fonts.glyph(for: c.codepoint, style: style) {
                out.append(ShapedGlyph(col: Int32(col), font: UInt16(f), glyph: g, dx: 0, dy: 0, special: 0, span: 1))
            }
        }
    }

    // MARK: Run cache
    //
    // Shaping with CoreText costs tens of microseconds per run, but terminal output is extremely
    // repetitive (identifiers, operators, prompts), so shaped runs are cached by their content.
    // Two generations give LRU-like behavior with bounded memory: when the young generation fills
    // up it becomes the old one, and hits in the old generation are promoted.

    private var runCache: [[UInt16]: [ShapedGlyph]] = [:]
    private var runCacheOld: [[UInt16]: [ShapedGlyph]] = [:]
    static let runCacheLimit = 4096
    private var key: [UInt16] = []
    private var relCols: [UInt16] = []
    private(set) var runCacheHits = 0
    private(set) var runCacheMisses = 0

    private func shapeCoreText(cells: UnsafePointer<Cell>, from: Int, to: Int, style: Int, grapheme: (UInt32) -> [UInt32], into out: inout [ShapedGlyph]) {
        utf16.removeAll(keepingCapacity: true)
        relCols.removeAll(keepingCapacity: true)
        @inline(__always) func push(_ s: UInt32, _ rel: UInt16) {
            if s < 0x10000 {
                utf16.append(UInt16(s)); relCols.append(rel)
            } else if s <= 0x10FFFF {
                let v = s - 0x10000
                utf16.append(UInt16(0xD800 + (v >> 10))); relCols.append(rel)
                utf16.append(UInt16(0xDC00 + (v & 0x3FF))); relCols.append(rel)
            }
        }
        for col in from..<to {
            let c = cells[col]
            if c.flags.contains(.wideSpacer) { continue }
            let rel = UInt16(truncatingIfNeeded: col - from)
            if c.flags.contains(.grapheme) {
                for s in grapheme(c.codepoint) { push(s, rel) }
            } else {
                push(c.codepoint, rel)
            }
        }
        guard !utf16.isEmpty else { return }

        // Key: style, run width in cells, then the text and the column of each UTF-16 unit (the
        // columns capture wide-character layout).
        key.removeAll(keepingCapacity: true)
        key.append(UInt16(style))
        key.append(UInt16(truncatingIfNeeded: to - from))
        key.append(contentsOf: utf16)
        key.append(contentsOf: relCols)

        let cached: [ShapedGlyph]
        if let hit = runCache[key] {
            cached = hit
            runCacheHits += 1
        } else if let hit = runCacheOld[key] {
            cached = hit
            runCache[key] = hit
            runCacheHits += 1
        } else {
            cached = shapeUncached(cells: cells, from: from, to: to, style: style)
            if runCache.count >= Shaper.runCacheLimit {
                runCacheOld = runCache
                runCache = [:]
                runCache.reserveCapacity(Shaper.runCacheLimit)
            }
            runCache[key] = cached
            runCacheMisses += 1
        }
        let base = Int32(from)
        for var g in cached {
            g.col += base
            out.append(g)
        }
    }

    /// Shape `utf16` (already filled for the run) with CoreText. Returned columns are relative to `from`.
    private func shapeUncached(cells: UnsafePointer<Cell>, from: Int, to: Int, style: Int) -> [ShapedGlyph] {
        var out: [ShapedGlyph] = []
        let str = CFStringCreateWithCharacters(nil, utf16, utf16.count)!
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: fonts.fonts[style],
            kCTLigatureAttributeName: fonts.ligatures ? 1 : 0,
        ]
        let astr = CFAttributedStringCreate(nil, str, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(astr)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        var clusterOriginX: [UInt16: CGFloat] = [:]
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            guard n > 0 else { continue }
            let runAttrs = CTRunGetAttributes(run) as NSDictionary
            let runFont = runAttrs[kCTFontAttributeName] as! CTFont
            let fi = fonts.index(of: runFont, style: style)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            var indices = [CFIndex](repeating: 0, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: n), &indices)
            for i in 0..<n {
                let idx = max(0, min(indices[i], relCols.count - 1))
                let rel = relCols[idx]
                let origin = clusterOriginX[rel] ?? positions[i].x
                if clusterOriginX[rel] == nil { clusterOriginX[rel] = positions[i].x }
                if glyphs[i] == 0 { continue }
                let wide = cells[from + Int(rel)].flags.contains(.wide)
                out.append(ShapedGlyph(col: Int32(rel), font: UInt16(fi), glyph: glyphs[i],
                                       dx: Float(positions[i].x - origin), dy: Float(positions[i].y),
                                       special: 0, span: wide ? 2 : 1))
            }
        }
        return out
    }
}
