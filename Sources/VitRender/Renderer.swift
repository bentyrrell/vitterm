import Metal
import QuartzCore
import CoreText
import VitCore

// Layouts must match Shaders.metal.
struct Uniforms {
    var viewport: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var textGamma: Float
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

struct RectInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var color: UInt32
    var kind: UInt32
    var thickness: Float
    var pad: Float = 0
}

struct GlyphInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: UInt32
    var flags: UInt32
}

struct ImageInstance {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uv: SIMD4<Float>
    var alpha: Float
    var pad0: Float = 0, pad1: Float = 0, pad2: Float = 0
}

enum RectKind: UInt32 { case solid = 0, curly, dotted, dashed, hollow }

/// Per-frame visual options supplied by the view.
public struct RenderOptions {
    public var paddingX: CGFloat = 0           // pixels
    public var paddingY: CGFloat = 0
    public var focused = true
    public var cursorStyle: CursorShape = .block
    public var cursorBlinkVisible = true
    public var selectionBackground: UInt32? = nil
    public var selectionForeground: UInt32? = nil
    public var cursorText: UInt32? = nil
    public var boldIsBright = false
    public var backgroundOpacity: Double = 1
    /// 0 = no dimming; otherwise the alpha of a background-colored overlay.
    public var dim: Double = 0
    public var broadcastBorder: UInt32? = nil
    public var flash: Double = 0
    public var textGamma: Float = 1
    /// Animated cursor trail; nil disables it.
    public var cursorTrail: CursorTrailOptions? = nil
    public init() {}
}

/// Transient overlays drawn on top of the grid.
public struct RenderOverlay {
    public var selection: Selection? = nil
    public var matches: [SearchMatch] = []
    public var currentMatch: Int? = nil
    /// Hovered hyperlink cells: absolute line + inclusive column ranges.
    public var hoverLink: [(line: Int, cols: ClosedRange<Int>)] = []
    public var markedText: String = ""
    public init() {}
}

/// Renders one terminal surface into a CAMetalLayer.
public final class TerminalRenderer {
    let ctx = MetalContext.shared
    public private(set) var fonts: FontSet
    var atlas: GlyphAtlas
    var shaper: Shaper

    private let inflight = DispatchSemaphore(value: 3)
    /// Frames handed to the compositor but not yet presented (or discarded). A drawable only
    /// returns to the layer's pool after the frame after it is on screen, so with 3 drawables
    /// allowing more than 2 of these makes `nextDrawable()` block the main thread until a vsync.
    private var unpresented = 0
    private let unpresentedLock = UnfairLock()
    private static let maxUnpresented = 2
    private var frameIndex = 0
    private var buffers: [[MTLBuffer?]] = Array(repeating: [nil, nil, nil, nil], count: 3) // rects, glyphs, overRects, images

    private var rects: [RectInstance] = []
    private var overRects: [RectInstance] = []
    private var glyphs: [GlyphInstance] = []
    private var belowImages: [(MTLTexture, ImageInstance)] = []
    private var aboveImages: [(MTLTexture, ImageInstance)] = []
    private var trail = CursorTrail()
    private var trailPolygon: [SIMD2<Float>] = []
    private var trailColor = SIMD4<Float>(0, 0, 0, 0)
    /// True while an animation (cursor trail) needs more frames.
    public var isAnimating: Bool { trail.needsFrames }

    /// Shaped glyphs per line, keyed by line uid and valid for one line generation. Resolved atlas
    /// entries are cached alongside (valid for one atlas generation), so unchanged rows cost no
    /// shaping and no glyph lookups.
    private struct RowShape {
        var generation: UInt64
        var breakAt: Int
        var glyphs: [ShapedGlyph]
        var entries: [GlyphEntry]
        var atlasGeneration: Int
        var lastFrame: UInt64
    }
    private var rowCache: [UInt64: RowShape] = [:]
    private var frameCounter: UInt64 = 0
    private var scratchEntries: [GlyphEntry] = []
    private var scratchGlyphs: [ShapedGlyph] = []

    // Snapshot storage.
    private var snapCells: [Cell] = []
    private var snapRows: [(uid: UInt64, gen: UInt64, absLine: Int)] = []
    private var fgColors: [UInt32] = []

    private var imageTextures: [UInt64: MTLTexture] = [:]

    public var cellWidth: Int { fonts.cellWidth }
    public var cellHeight: Int { fonts.cellHeight }

    public init(spec: FontSpec, scale: CGFloat) {
        (fonts, atlas) = MetalContext.shared.fonts(for: spec, scale: scale)
        shaper = Shaper(fonts: fonts)
    }

    public func setFont(_ spec: FontSpec, scale: CGFloat) {
        (fonts, atlas) = ctx.fonts(for: spec, scale: scale)
        shaper = Shaper(fonts: fonts)
        rowCache.removeAll()
    }

    public func configure(layer: CAMetalLayer) {
        layer.device = ctx.device
        layer.pixelFormat = ctx.pixelFormat
        layer.framebufferOnly = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
    }

    // MARK: Colors

    @inline(__always) static func pack(_ rgb: UInt32, _ a: UInt8 = 255) -> UInt32 {
        (rgb >> 16 & 0xFF) | (rgb & 0xFF00) | ((rgb & 0xFF) << 16) | (UInt32(a) << 24)
    }

    // MARK: Drawing

    /// Render a frame. Returns false if the frame was skipped (GPU busy or no drawable).
    @discardableResult
    public func draw(layer: CAMetalLayer, terminal t: Terminal, overlay: RenderOverlay, options o: RenderOptions,
                     synchronous: Bool = false, onPresented: ((CFTimeInterval) -> Void)? = nil) -> Bool {
        // Skip (the caller retries next tick) rather than block waiting for a drawable.
        if !synchronous && unpresentedLock.withLock({ unpresented >= TerminalRenderer.maxUnpresented }) { return false }
        if inflight.wait(timeout: synchronous ? .now() + 0.1 : .now()) != .success { return false }
        let drawableSize = layer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0, let drawable = layer.nextDrawable() else {
            inflight.signal()
            return false
        }
        unpresentedLock.withLock { unpresented += 1 }
        // Called when shown, and also (with presentedTime 0) when the drawable is discarded.
        let unpresentedLock = self.unpresentedLock
        drawable.addPresentedHandler { [weak self] _ in unpresentedLock.withLock { self?.unpresented -= 1 } }
        guard let cb = encodeFrame(target: drawable.texture, size: drawableSize, terminal: t, overlay: overlay, options: o) else {
            inflight.signal()
            return false
        }
        let sem = inflight
        cb.addCompletedHandler { _ in sem.signal() }
        if let onPresented { drawable.addPresentedHandler { d in onPresented(d.presentedTime) } }
        if synchronous {
            cb.commit()
            cb.waitUntilScheduled()
            drawable.present()
        } else {
            cb.present(drawable)
            cb.commit()
        }
        return true
    }

    /// Counters from the most recent frame build (for tests and benchmarks).
    public struct FrameStats: Equatable {
        public var rects = 0, glyphs = 0, overlays = 0
        /// Rows shaped from scratch vs. served from the per-line shape cache.
        public var shapedRows = 0, cachedRows = 0
    }
    public private(set) var lastStats = FrameStats()

    /// Run the CPU side of a frame (snapshot, shaping, instance building) without touching the GPU.
    @discardableResult
    public func prepareFrame(terminal t: Terminal, overlay: RenderOverlay, options o: RenderOptions, size: CGSize) -> FrameStats {
        let state = snapshot(t, overlay: overlay)
        build(state, overlay: overlay, options: o, viewport: size)
        return lastStats
    }

    /// Render offscreen and return the image (for tests and debugging).
    public func renderImage(terminal t: Terminal, overlay: RenderOverlay, options o: RenderOptions, size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: ctx.pixelFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = ctx.device.makeTexture(descriptor: d) else { return nil }
        inflight.wait()
        guard let cb = encodeFrame(target: tex, size: size, terminal: t, overlay: overlay, options: o) else { inflight.signal(); return nil }
        cb.commit()
        cb.waitUntilCompleted()
        inflight.signal()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func encodeFrame(target: MTLTexture, size drawableSize: CGSize, terminal t: Terminal, overlay: RenderOverlay,
                             options o: RenderOptions) -> MTLCommandBuffer? {
        let atlasGen = atlas.generation
        let state = snapshot(t, overlay: overlay)
        build(state, overlay: overlay, options: o, viewport: drawableSize)
        if atlas.generation != atlasGen {
            // The atlas was cleared mid-frame; rebuild so no entries point at stale regions.
            rowCache.removeAll()
            build(state, overlay: overlay, options: o, viewport: drawableSize)
        }

        guard let cb = ctx.queue.makeCommandBuffer() else { return nil }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        let bg = state.reverse ? state.defaultFg : state.defaultBg
        let alpha = o.backgroundOpacity
        rp.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg >> 16 & 0xFF) / 255 * alpha, green: Double(bg >> 8 & 0xFF) / 255 * alpha,
            blue: Double(bg & 0xFF) / 255 * alpha, alpha: alpha)

        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        var uniforms = Uniforms(viewport: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                                cellSize: SIMD2(Float(fonts.cellWidth), Float(fonts.cellHeight)),
                                textGamma: o.textGamma)
        let fi = frameIndex
        frameIndex = (frameIndex + 1) % 3

        func upload<T>(_ arr: [T], slot: Int) -> MTLBuffer? {
            guard !arr.isEmpty else { return nil }
            let bytes = arr.count * MemoryLayout<T>.stride
            var buf = buffers[fi][slot]
            if buf == nil || buf!.length < bytes {
                buf = ctx.device.makeBuffer(length: max(bytes, 64 * 1024) * 3 / 2, options: .storageModeShared)
                buffers[fi][slot] = buf
            }
            arr.withUnsafeBytes { _ = memcpy(buf!.contents(), $0.baseAddress!, bytes) }
            return buf
        }

        func drawRects(_ arr: [RectInstance], slot: Int) {
            guard let b = upload(arr, slot: slot) else { return }
            enc.setRenderPipelineState(ctx.rectPipeline)
            enc.setVertexBuffer(b, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: arr.count)
        }

        func drawImages(_ list: [(MTLTexture, ImageInstance)]) {
            guard !list.isEmpty else { return }
            enc.setRenderPipelineState(ctx.imagePipeline)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            for (tex, inst) in list {
                var i = inst
                enc.setVertexBytes(&i, length: MemoryLayout<ImageInstance>.stride, index: 0)
                enc.setFragmentTexture(tex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
            }
        }

        drawRects(rects, slot: 0)
        if !trailPolygon.isEmpty {
            enc.setRenderPipelineState(ctx.trailPipeline)
            trailPolygon.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&trailColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: trailPolygon.count)
        }
        drawImages(belowImages)
        if let gb = upload(glyphs, slot: 1) {
            enc.setRenderPipelineState(ctx.glyphPipeline)
            enc.setVertexBuffer(gb, offset: 0, index: 0)
            enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(atlas.gray, index: 0)
            enc.setFragmentTexture(atlas.color, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        drawImages(aboveImages)
        drawRects(overRects, slot: 2)
        enc.endEncoding()
        return cb
    }

    // MARK: Snapshot

    struct Snapshot {
        var cols = 0, rows = 0
        var cursorX = 0, cursorY = -1        // viewport row, -1 if hidden/off screen
        var cursorVisible = true
        var cursorWide = false
        var defaultFg: UInt32 = 0, defaultBg: UInt32 = 0, cursorColor: UInt32? = nil
        var palette: [UInt32] = []
        var reverse = false
        /// Grapheme clusters referenced by rows that need shaping this frame.
        var clusters: [UInt32: [UInt32]] = [:]
        var extras: [CellExtra] = []
        var viewportTop = 0                  // absolute line of viewport row 0
        var placements: [ImagePlacement] = []
        var images: [UInt32: TerminalImage] = [:]
        var usingAlternate = false
        var scrollOffset = 0
        var scrollbackCount = 0
        var cursorShape: CursorShape? = nil
        var markedRow = -1
    }

    private func snapshot(_ t: Terminal, overlay: RenderOverlay) -> Snapshot {
        var s = Snapshot()
        t.lock.lock()
        defer { t.lock.unlock() }
        let g = t.grid
        s.cols = t.cols
        s.rows = t.rows
        s.defaultFg = t.defaultForeground
        s.defaultBg = t.defaultBackground
        s.cursorColor = t.cursorColor
        s.palette = t.palette
        s.reverse = t.modes.reverseVideo
        s.extras = t.extras.entries
        s.usingAlternate = t.usingAlternate
        s.scrollOffset = t.usingAlternate ? 0 : min(t.scrollOffset, g.scrollbackCount)
        s.scrollbackCount = g.scrollbackCount
        s.cursorShape = t.cursorShape
        let firstLogical = g.scrollbackCount - s.scrollOffset
        s.viewportTop = g.dropped + firstLogical
        let cy = t.cursorY + s.scrollOffset
        s.cursorVisible = t.modes.cursorVisible
        if cy < t.rows {
            s.cursorY = cy
            s.cursorX = t.cursorX
            s.cursorWide = t.grid.screenLine(t.cursorY)[t.cursorX].flags.contains(.wide)
        }
        if !t.images.isEmpty {
            s.placements = t.images.placements
            s.images = t.images.images
        }

        let cols = t.cols
        if snapCells.count < cols * t.rows { snapCells = [Cell](repeating: .empty, count: cols * t.rows) }
        snapRows.removeAll(keepingCapacity: true)
        snapCells.withUnsafeMutableBufferPointer { dst in
            for y in 0..<t.rows {
                let line = g.line(at: firstLogical + y)
                // Only the first `used` cells are meaningful; the rest of the row is empty.
                let n = min(cols, line.used)
                (dst.baseAddress! + y * cols).update(from: line.cells, count: n)
                if n < cols { memset(dst.baseAddress! + y * cols + n, 0, (cols - n) * MemoryLayout<Cell>.stride) }
                snapRows.append((line.uid, line.generation, s.viewportTop + y))
                // Rows whose shaping is cached don't need cluster text; copy only what's needed
                // rather than the whole (shared, copy-on-write) grapheme table.
                if rowCache[line.uid]?.generation != line.generation || y == cy {
                    for x in 0..<min(line.used, n) where line.cells[x].flags.contains(.grapheme) {
                        let id = line.cells[x].codepoint
                        if s.clusters[id] == nil { s.clusters[id] = t.graphemes.scalars(id) }
                    }
                }
            }
        }

        // IME preedit text replaces cells at the cursor (rendered underlined).
        if !overlay.markedText.isEmpty && s.cursorY >= 0 {
            s.markedRow = s.cursorY
            var x = s.cursorX
            for u in overlay.markedText.unicodeScalars {
                let w = CharWidth.of(u.value)
                guard w > 0, x + w <= cols else { continue }
                var c = Cell(codepoint: u.value)
                c.flags.underline = .single
                if w == 2 { c.flags.insert(.wide) }
                snapCells[s.cursorY * cols + x] = c
                if w == 2 { snapCells[s.cursorY * cols + x + 1] = Cell(flags: [.wideSpacer]) }
                x += w
            }
            s.cursorX = min(x, cols - 1)
        }
        return s
    }

    // MARK: Building instances

    private func resolve(_ c: TermColor, _ s: Snapshot, isBg: Bool, bold: Bool, boldIsBright: Bool) -> UInt32 {
        switch c.tag {
        case 1:
            var i = Int(c.paletteIndex)
            if bold && boldIsBright && !isBg && i < 8 { i += 8 }
            return s.palette[i]
        case 2:
            return c.rgb
        default:
            return isBg ? (s.reverse ? s.defaultFg : s.defaultBg) : (s.reverse ? s.defaultBg : s.defaultFg)
        }
    }

    private func build(_ s: Snapshot, overlay: RenderOverlay, options o: RenderOptions, viewport: CGSize) {
        rects.removeAll(keepingCapacity: true)
        overRects.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        belowImages.removeAll(keepingCapacity: true)
        aboveImages.removeAll(keepingCapacity: true)
        frameCounter &+= 1
        let frame = frameCounter
        let atlasGen = atlas.generation
        var shapedRows = 0, cachedRows = 0

        let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
        let px = Float(o.paddingX), py = Float(o.paddingY)
        let cols = s.cols
        let effectiveBg = s.reverse ? s.defaultFg : s.defaultBg
        let cursorColor = s.cursorColor ?? (s.reverse ? s.defaultBg : s.defaultFg)
        let cursorShape = s.cursorShape ?? o.cursorStyle
        let showCursor = s.cursorVisible && s.cursorY >= 0 && o.cursorBlinkVisible && s.scrollOffset == 0 || (s.markedRow >= 0)
        let blockCursor = showCursor && o.focused && cursorShape == .block && s.markedRow < 0
        let selBg = o.selectionBackground ?? 0x3A4A6B
        let matchBg: UInt32 = 0xE5C07B, currentMatchBg: UInt32 = 0xF08C3C, matchFg: UInt32 = 0x101010

        if fgColors.count < cols { fgColors = [UInt32](repeating: 0, count: cols) }

        // Index search matches by line.
        var matchCols: [Int: [(ClosedRange<Int>, Bool)]] = [:]
        if !overlay.matches.isEmpty {
            let top = s.viewportTop, bottom = s.viewportTop + s.rows - 1
            for (i, m) in overlay.matches.enumerated() where m.end.line >= top && m.start.line <= bottom {
                for line in max(m.start.line, top)...min(m.end.line, bottom) {
                    let a = line == m.start.line ? m.start.col : 0
                    let b = line == m.end.line ? m.end.col : cols - 1
                    if a <= b { matchCols[line, default: []].append((a...b, i == overlay.currentMatch)) }
                }
            }
        }
        var hover: [Int: ClosedRange<Int>] = [:]
        for h in overlay.hoverLink { hover[h.line] = h.cols }

        let clusters = s.clusters
        let graphemeLookup: (UInt32) -> [UInt32] = { i in clusters[i] ?? [0xFFFD] }

        snapCells.withUnsafeBufferPointer { all in
            for y in 0..<s.rows {
                let row = all.baseAddress! + y * cols
                let (uid, gen, absLine) = snapRows[y]
                let top = py + Float(y) * ch
                let selCols = (overlay.selection?.onAlternate == s.usingAlternate) ? overlay.selection?.columns(onLine: absLine, cols: cols) : nil
                let lineMatches = matchCols[absLine]
                let isCursorRow = y == s.cursorY

                // Pass 1: colors, backgrounds and decorations.
                var runStart = 0
                var runColor: UInt32 = 0
                var runActive = false
                func flushBg(_ end: Int) {
                    if runActive {
                        rects.append(RectInstance(origin: SIMD2(px + Float(runStart) * cw, top),
                                                  size: SIMD2(Float(end - runStart) * cw, ch),
                                                  color: TerminalRenderer.pack(runColor), kind: 0, thickness: 0))
                        runActive = false
                    }
                }
                var ulStart = 0, ulKey: (UInt16, UInt32) = (0, 0), ulActive = false
                func flushUnderline(_ end: Int) {
                    guard ulActive else { return }
                    ulActive = false
                    let style = UnderlineStyle(rawValue: ulKey.0) ?? .single
                    let thick = Float(fonts.underlineThickness)
                    let x = px + Float(ulStart) * cw, w = Float(end - ulStart) * cw
                    let uy = top + Float(fonts.underlinePosition)
                    let color = ulKey.1
                    switch style {
                    case .single: overRects.append(RectInstance(origin: SIMD2(x, uy), size: SIMD2(w, thick), color: color, kind: 0, thickness: thick))
                    case .double:
                        overRects.append(RectInstance(origin: SIMD2(x, uy - thick), size: SIMD2(w, thick), color: color, kind: 0, thickness: thick))
                        overRects.append(RectInstance(origin: SIMD2(x, min(uy + thick, top + ch - thick)), size: SIMD2(w, thick), color: color, kind: 0, thickness: thick))
                    case .curly:
                        let hgt = max(thick * 3, 4)
                        overRects.append(RectInstance(origin: SIMD2(x, min(uy - thick, top + ch - hgt)), size: SIMD2(w, hgt), color: color, kind: RectKind.curly.rawValue, thickness: thick))
                    case .dotted: overRects.append(RectInstance(origin: SIMD2(x, uy), size: SIMD2(w, thick), color: color, kind: RectKind.dotted.rawValue, thickness: thick))
                    case .dashed: overRects.append(RectInstance(origin: SIMD2(x, uy), size: SIMD2(w, thick), color: color, kind: RectKind.dashed.rawValue, thickness: thick))
                    case .none: break
                    }
                }

                for x in 0..<cols {
                    let c = row[x]
                    let bold = c.flags.contains(.bold)
                    var fg = resolve(c.fg, s, isBg: false, bold: bold, boldIsBright: o.boldIsBright)
                    var bg = resolve(c.bg, s, isBg: true, bold: false, boldIsBright: false)
                    if c.flags.contains(.inverse) { swap(&fg, &bg) }
                    var alpha: UInt8 = c.flags.contains(.faint) ? 140 : 255

                    if let sc = selCols, sc.contains(x) {
                        bg = selBg
                        if let sf = o.selectionForeground { fg = sf }
                    }
                    if let lm = lineMatches {
                        for (r, cur) in lm where r.contains(x) { bg = cur ? currentMatchBg : matchBg; fg = matchFg; alpha = 255 }
                    }
                    var cellIsCursor = false
                    if blockCursor && isCursorRow && (x == s.cursorX || (s.cursorWide && x == s.cursorX + 1)) {
                        bg = cursorColor
                        fg = o.cursorText ?? effectiveBg
                        alpha = 255
                        cellIsCursor = true
                    }
                    if c.flags.contains(.invisible) { alpha = 0 }
                    fgColors[x] = TerminalRenderer.pack(fg, alpha)

                    if bg != effectiveBg || cellIsCursor {
                        if runActive && runColor == bg { /* extend */ }
                        else { flushBg(x); runStart = x; runColor = bg; runActive = true }
                    } else {
                        flushBg(x)
                    }

                    // Underline (cell style, or hovered hyperlink).
                    var ul = c.flags.underline
                    var ulColor = fgColors[x]
                    if c.extra != 0 && Int(c.extra) < s.extras.count {
                        let e = s.extras[Int(c.extra)]
                        if !e.underlineColor.isDefault { ulColor = TerminalRenderer.pack(resolve(e.underlineColor, s, isBg: false, bold: false, boldIsBright: false), alpha) }
                    }
                    if let h = hover[absLine], h.contains(x) { ul = .single; ulColor = TerminalRenderer.pack(fg) }
                    if ul != .none && !c.flags.contains(.invisible) {
                        let key = (ul.rawValue, ulColor)
                        if !(ulActive && ulKey == key) { flushUnderline(x); ulStart = x; ulKey = key; ulActive = true }
                    } else {
                        flushUnderline(x)
                    }
                    if c.flags.contains(.strikethrough) {
                        overRects.append(RectInstance(origin: SIMD2(px + Float(x) * cw, top + Float(fonts.strikePosition)),
                                                      size: SIMD2(cw, Float(fonts.underlineThickness)), color: fgColors[x], kind: 0, thickness: 0))
                    }
                    if c.flags.contains(.overline) {
                        overRects.append(RectInstance(origin: SIMD2(px + Float(x) * cw, top),
                                                      size: SIMD2(cw, Float(fonts.underlineThickness)), color: fgColors[x], kind: 0, thickness: 0))
                    }
                }
                flushBg(cols)
                flushUnderline(cols)

                // Pass 2: glyphs (shaped once per line generation; atlas entries resolved once per
                // atlas generation).
                // Runs are split at a visible cursor so a ligature never straddles it. That only matters
                // with ligatures on and a visible cursor; otherwise don't let cursor moves bust the cache.
                let breakAt = (isCursorRow && s.cursorVisible && fonts.ligatures) ? s.cursorX : -1
                let cacheable = y != s.markedRow
                var shape: RowShape
                if cacheable, var cached = rowCache[uid], cached.generation == gen, cached.breakAt == breakAt {
                    cachedRows += 1
                    if cached.atlasGeneration != atlasGen {
                        cached.entries = resolveEntries(cached.glyphs)
                        cached.atlasGeneration = atlasGen
                    }
                    cached.lastFrame = frame
                    rowCache[uid] = cached
                    shape = cached
                } else {
                    shapedRows += 1
                    shaper.shape(cells: row, count: cols, grapheme: graphemeLookup, breakAt: breakAt, into: &scratchGlyphs)
                    shape = RowShape(generation: gen, breakAt: breakAt, glyphs: scratchGlyphs, entries: resolveEntries(scratchGlyphs),
                                     atlasGeneration: atlasGen, lastFrame: frame)
                    if cacheable { rowCache[uid] = shape }
                }

                shape.glyphs.withUnsafeBufferPointer { gs in
                    shape.entries.withUnsafeBufferPointer { es in
                        for i in 0..<gs.count {
                            let sg = gs[i]
                            let e = es[i]
                            if e.isEmpty { continue }
                            let col = Int(sg.col)
                            let color = fgColors[col]
                            if color >> 24 == 0 { continue }
                            let gx = px + Float(col) * cw + Float(e.left) + sg.dx
                            let gy = top + Float(e.top) - sg.dy
                            glyphs.append(GlyphInstance(origin: SIMD2(gx.rounded(), gy), size: SIMD2(Float(e.w), Float(e.h)),
                                                        uv: SIMD2(Float(e.x), Float(e.y)),
                                                        color: e.isColor ? (UInt32(color >> 24) << 24) : color,
                                                        flags: e.isColor ? 1 : 0))
                        }
                    }
                }
            }
        }

        // Cursor shapes drawn over text.
        if showCursor && s.cursorY >= 0 && !blockCursor {
            let x = px + Float(s.cursorX) * cw
            let y = py + Float(s.cursorY) * ch
            let w = s.cursorWide ? cw * 2 : cw
            let color = TerminalRenderer.pack(cursorColor)
            let thick = Float(max(1, fonts.underlineThickness))
            if s.markedRow >= 0 {
                overRects.append(RectInstance(origin: SIMD2(x, y), size: SIMD2(max(1, Float(fonts.scale)), ch), color: color, kind: 0, thickness: 0))
            } else if !o.focused {
                overRects.append(RectInstance(origin: SIMD2(x, y), size: SIMD2(w, ch), color: color, kind: RectKind.hollow.rawValue, thickness: max(1, Float(fonts.scale))))
            } else if cursorShape == .bar {
                overRects.append(RectInstance(origin: SIMD2(x, y), size: SIMD2(max(1, (Float(fonts.scale) * 1.5).rounded()), ch), color: color, kind: 0, thickness: 0))
            } else {
                overRects.append(RectInstance(origin: SIMD2(x, y + ch - thick * 2), size: SIMD2(w, thick * 2), color: color, kind: 0, thickness: 0))
            }
        }

        buildTrail(s, options: o, cursorShape: cursorShape)
        buildImages(s, options: o)

        // Scroll position indicator.
        if s.scrollOffset > 0 && s.scrollbackCount > 0 {
            let total = Float(s.scrollbackCount + s.rows)
            let vh = Float(viewport.height)
            let h = max(vh * Float(s.rows) / total, 20)
            let pos = Float(s.scrollbackCount - s.scrollOffset) / Float(s.scrollbackCount)
            let y = (vh - h) * pos
            let w = Float(max(3, fonts.scale * 3))
            overRects.append(RectInstance(origin: SIMD2(Float(viewport.width) - w - 2, y), size: SIMD2(w, h),
                                          color: TerminalRenderer.pack(s.reverse ? s.defaultBg : s.defaultFg, 90), kind: 0, thickness: 0))
        }

        let full = SIMD2(Float(viewport.width), Float(viewport.height))
        if o.flash > 0 {
            overRects.append(RectInstance(origin: .zero, size: full, color: TerminalRenderer.pack(s.defaultFg, UInt8(min(1, o.flash) * 40)), kind: 0, thickness: 0))
        }
        if o.dim > 0 {
            overRects.append(RectInstance(origin: .zero, size: full, color: TerminalRenderer.pack(effectiveBg, UInt8(min(1, o.dim) * 255)), kind: 0, thickness: 0))
        }
        if let b = o.broadcastBorder {
            let t = Float(max(2, fonts.scale * 1.5))
            overRects.append(RectInstance(origin: .zero, size: full, color: TerminalRenderer.pack(b, 230), kind: RectKind.hollow.rawValue, thickness: t))
        }

        // Evict shape cache entries for lines that weren't on screen this frame.
        if rowCache.count > s.rows * 3 {
            rowCache = rowCache.filter { $0.value.lastFrame == frame }
        }
        lastStats = FrameStats(rects: rects.count, glyphs: glyphs.count, overlays: overRects.count,
                               shapedRows: shapedRows, cachedRows: cachedRows)
    }

    private func resolveEntries(_ shaped: [ShapedGlyph]) -> [GlyphEntry] {
        scratchEntries.removeAll(keepingCapacity: true)
        for sg in shaped {
            scratchEntries.append(sg.special != 0 ? atlas.special(sg.special) : atlas.entry(font: Int(sg.font), glyph: sg.glyph, span: Int(sg.span)))
        }
        return scratchEntries
    }

    private func buildTrail(_ s: Snapshot, options o: RenderOptions, cursorShape: CursorShape) {
        trailPolygon.removeAll(keepingCapacity: true)
        guard let opts = o.cursorTrail, s.cursorVisible, s.cursorY >= 0, s.scrollOffset == 0, s.markedRow < 0 else {
            trail.reset()
            return
        }
        let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
        let x = Float(o.paddingX) + Float(s.cursorX) * cw
        let y = Float(o.paddingY) + Float(s.cursorY) * ch
        let w = s.cursorWide ? cw * 2 : cw
        // The trail takes the shape of the cursor: full cell, thin bar, or underline strip.
        let box: [SIMD2<Float>]
        switch cursorShape {
        case .bar: box = CursorTrail.box(x, y, max(1, (Float(fonts.scale) * 1.5).rounded()), ch)
        case .underline:
            let t = Float(max(1, fonts.underlineThickness)) * 2
            box = CursorTrail.box(x, y + ch - t, w, t)
        case .block: box = CursorTrail.box(x, y, w, ch)
        }
        trailPolygon = trail.update(cursor: box, cell: SIMD2(cw, ch), options: opts)
        let c = opts.color
        trailColor = SIMD4(Float(c >> 16 & 0xFF) / 255, Float(c >> 8 & 0xFF) / 255, Float(c & 0xFF) / 255, opts.opacity)
    }

    private func buildImages(_ s: Snapshot, options o: RenderOptions) {
        guard !s.placements.isEmpty else {
            if !imageTextures.isEmpty && s.images.isEmpty { imageTextures.removeAll() }
            return
        }
        let cw = Float(fonts.cellWidth), ch = Float(fonts.cellHeight)
        let px = Float(o.paddingX), py = Float(o.paddingY)
        var live = Set<UInt64>()
        for p in s.placements where p.onAlternate == s.usingAlternate {
            guard let img = s.images[p.imageID] else { continue }
            let rowTop = p.line - s.viewportTop
            if rowTop + p.rows <= 0 || rowTop >= s.rows { continue }
            live.insert(img.uploadID)
            let tex: MTLTexture
            if let t = imageTextures[img.uploadID] { tex = t } else {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: img.width, height: img.height, mipmapped: false)
                d.usage = .shaderRead
                guard let t = ctx.device.makeTexture(descriptor: d) else { continue }
                img.rgba.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 4) }
                imageTextures[img.uploadID] = t
                tex = t
            }
            let boxW = Float(p.cols) * cw, boxH = Float(p.rows) * ch
            var w: Float, h: Float
            switch p.fit {
            case .natural: w = Float(p.srcW); h = Float(p.srcH)
            case .stretch: w = boxW; h = boxH
            case .aspectFit:
                let sc = min(boxW / Float(p.srcW), boxH / Float(p.srcH))
                w = Float(p.srcW) * sc; h = Float(p.srcH) * sc
            }
            let origin = SIMD2(px + Float(p.col) * cw + Float(p.offsetX), py + Float(rowTop) * ch + Float(p.offsetY))
            let uv = SIMD4(Float(p.srcX) / Float(img.width), Float(p.srcY) / Float(img.height),
                           Float(p.srcX + p.srcW) / Float(img.width), Float(p.srcY + p.srcH) / Float(img.height))
            let inst = ImageInstance(origin: origin, size: SIMD2(w, h), uv: uv, alpha: 1)
            if p.z < 0 { belowImages.append((tex, inst)) } else { aboveImages.append((tex, inst)) }
        }
        if imageTextures.count > live.count + 16 {
            let keep = Set(s.images.values.map(\.uploadID))
            imageTextures = imageTextures.filter { keep.contains($0.key) }
        }
    }
}
