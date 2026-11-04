import Metal
import CoreText
import CoreGraphics

/// Glyph cache key packed into one integer (cheap to hash): font, glyph id and span for font
/// glyphs; the codepoint with the top bit set for procedurally drawn characters.
@inline(__always) func glyphKey(font: Int, glyph: CGGlyph, span: Int) -> UInt64 {
    UInt64(font) << 24 | UInt64(glyph) << 8 | UInt64(span & 0xFF)
}
@inline(__always) func specialKey(_ cp: UInt32) -> UInt64 { 1 << 63 | UInt64(cp) }

struct GlyphEntry {
    var x: UInt16, y: UInt16, w: UInt16, h: UInt16
    /// Offset of the bitmap's top-left from (cell left, cell top).
    var left: Int16, top: Int16
    var isColor: Bool
    var isEmpty: Bool { w == 0 || h == 0 }
}

/// A simple shelf packer.
struct ShelfPacker {
    var width: Int, height: Int
    var shelfY = 0, shelfH = 0, cursorX = 0

    mutating func alloc(_ w: Int, _ h: Int) -> (Int, Int)? {
        guard w <= width else { return nil }
        if cursorX + w > width {
            shelfY += shelfH
            shelfH = 0
            cursorX = 0
        }
        if shelfY + h > height { return nil }
        let r = (cursorX, shelfY)
        cursorX += w
        shelfH = max(shelfH, h)
        return r
    }
}

/// Glyph cache backed by two textures: R8 coverage for text and BGRA for color emoji.
final class GlyphAtlas {
    let device: MTLDevice
    let fonts: FontSet
    let thicken: Bool
    private(set) var gray: MTLTexture
    private(set) var color: MTLTexture
    private var grayPacker: ShelfPacker
    private var colorPacker: ShelfPacker
    private var cache: [UInt64: GlyphEntry] = [:]
    /// Bumped when the atlas is cleared; entries from before are invalid.
    private(set) var generation = 0
    private let maxSize = 8192
    private let pad = 1

    init(device: MTLDevice, fonts: FontSet, thicken: Bool) {
        self.device = device
        self.fonts = fonts
        self.thicken = thicken
        gray = GlyphAtlas.makeTexture(device, .r8Unorm, 1024)
        color = GlyphAtlas.makeTexture(device, .bgra8Unorm, 512)
        grayPacker = ShelfPacker(width: 1024, height: 1024)
        colorPacker = ShelfPacker(width: 512, height: 512)
    }

    static func makeTexture(_ device: MTLDevice, _ format: MTLPixelFormat, _ size: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        // Zero it.
        let bpp = format == .r8Unorm ? 1 : 4
        let zeros = [UInt8](repeating: 0, count: size * bpp * 64)
        var y = 0
        while y < size {
            let h = min(64, size - y)
            t.replace(region: MTLRegionMake2D(0, y, size, h), mipmapLevel: 0, withBytes: zeros, bytesPerRow: size * bpp)
            y += h
        }
        return t
    }

    /// Grow (or, at max size, clear) a texture so a w×h bitmap fits.
    private func makeRoom(colorAtlas: Bool) {
        let tex = colorAtlas ? color : gray
        let size = tex.width
        if size * 2 <= maxSize {
            let n = GlyphAtlas.makeTexture(device, tex.pixelFormat, size * 2)
            // Copy old contents via CPU (shared storage, small and rare).
            let bpp = tex.pixelFormat == .r8Unorm ? 1 : 4
            var buf = [UInt8](repeating: 0, count: size * size * bpp)
            tex.getBytes(&buf, bytesPerRow: size * bpp, from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0)
            n.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: buf, bytesPerRow: size * bpp)
            if colorAtlas {
                color = n
                // Existing packing stays valid; extend the area by starting a new shelf region below.
                colorPacker = ShelfPacker(width: size * 2, height: size * 2, shelfY: size, shelfH: 0, cursorX: 0)
            } else {
                gray = n
                grayPacker = ShelfPacker(width: size * 2, height: size * 2, shelfY: size, shelfH: 0, cursorX: 0)
            }
        } else {
            reset()
        }
    }

    func reset() {
        cache.removeAll()
        gray = GlyphAtlas.makeTexture(device, .r8Unorm, 1024)
        color = GlyphAtlas.makeTexture(device, .bgra8Unorm, 512)
        grayPacker = ShelfPacker(width: 1024, height: 1024)
        colorPacker = ShelfPacker(width: 512, height: 512)
        generation += 1
    }

    // MARK: Lookup

    func entry(font: Int, glyph: CGGlyph, span: Int) -> GlyphEntry {
        let isColor = fonts.isColorFont(font)
        let key = glyphKey(font: font, glyph: glyph, span: isColor ? span : 0)
        if let e = cache[key] { return e }
        let e = rasterize(font: font, glyph: glyph, span: span, isColor: isColor)
        cache[key] = e
        return e
    }

    func special(_ cp: UInt32) -> GlyphEntry {
        let key = specialKey(cp)
        if let e = cache[key] { return e }
        let w = fonts.cellWidth, h = fonts.cellHeight
        var bitmap = [UInt8](repeating: 0, count: w * h)
        let ok = bitmap.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            return BoxDrawing.draw(cp, in: ctx, width: w, height: h, lineWidth: max(1, fonts.underlineThickness))
        }
        let e = ok ? upload(gray: bitmap, w: w, h: h, left: 0, top: 0) : GlyphEntry(x: 0, y: 0, w: 0, h: 0, left: 0, top: 0, isColor: false)
        cache[key] = e
        return e
    }

    private func upload(gray bitmap: [UInt8], w: Int, h: Int, left: Int, top: Int) -> GlyphEntry {
        var spot = grayPacker.alloc(w + pad, h + pad)
        if spot == nil { makeRoom(colorAtlas: false); spot = grayPacker.alloc(w + pad, h + pad) }
        guard let (x, y) = spot else { return GlyphEntry(x: 0, y: 0, w: 0, h: 0, left: 0, top: 0, isColor: false) }
        gray.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: bitmap, bytesPerRow: w)
        return GlyphEntry(x: UInt16(x), y: UInt16(y), w: UInt16(w), h: UInt16(h), left: Int16(left), top: Int16(top), isColor: false)
    }

    private func rasterize(font fi: Int, glyph: CGGlyph, span: Int, isColor: Bool) -> GlyphEntry {
        var font = fonts.fonts[fi]
        var g = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &rect, 1)
        let empty = GlyphEntry(x: 0, y: 0, w: 0, h: 0, left: 0, top: 0, isColor: isColor)
        if rect.isEmpty || rect.width <= 0 || rect.height <= 0 { return empty }

        var originX: CGFloat = 0
        var centerVertically = false
        let baseline = CGFloat(fonts.baseline)
        if isColor {
            // Fit emoji into `span` cells: scale its ink box to ~95% of the cell height (bounded by
            // the available width), then center it in the cells.
            let availW = CGFloat(fonts.cellWidth * max(span, 1))
            let availH = CGFloat(fonts.cellHeight)
            let s = min(availW * 0.98 / rect.width, availH * 0.95 / rect.height)
            if abs(s - 1) > 0.01 {
                font = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * s, nil, nil)
                CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &rect, 1)
            }
            originX = ((availW - rect.width) / 2 - rect.minX).rounded()
            centerVertically = true
        }

        let x0 = Int((rect.minX + originX).rounded(.down)) - 1
        let x1 = Int((rect.maxX + originX).rounded(.up)) + 1
        let y0 = Int(rect.minY.rounded(.down)) - 1
        let y1 = Int(rect.maxY.rounded(.up)) + 1
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, w < 2048, h < 2048 else { return empty }
        // Glyph-space y is up from baseline; bitmap top is y1 above the baseline.
        let top = centerVertically ? (fonts.cellHeight - h) / 2 : Int(baseline) - y1
        let pos = CGPoint(x: CGFloat(-x0) + originX, y: CGFloat(-y0))

        if isColor {
            var bitmap = [UInt8](repeating: 0, count: w * h * 4)
            let ok = bitmap.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                var p = pos
                CTFontDrawGlyphs(font, &g, &p, 1, ctx)
                return true
            }
            guard ok else { return empty }
            var spot = colorPacker.alloc(w + pad, h + pad)
            if spot == nil { makeRoom(colorAtlas: true); spot = colorPacker.alloc(w + pad, h + pad) }
            guard let (x, y) = spot else { return empty }
            color.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0, withBytes: bitmap, bytesPerRow: w * 4)
            return GlyphEntry(x: UInt16(x), y: UInt16(y), w: UInt16(w), h: UInt16(h), left: Int16(x0), top: Int16(top), isColor: true)
        }

        var bitmap = [UInt8](repeating: 0, count: w * h)
        let ok = bitmap.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(true)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.setFillColor(gray: 1, alpha: 1)
            if thicken {
                ctx.setTextDrawingMode(.fillStroke)
                ctx.setStrokeColor(gray: 1, alpha: 1)
                ctx.setLineWidth(max(0.5, fonts.scale * 0.35))
            }
            var p = pos
            CTFontDrawGlyphs(font, &g, &p, 1, ctx)
            return true
        }
        guard ok else { return empty }
        return upload(gray: bitmap, w: w, h: h, left: x0, top: top)
    }
}
