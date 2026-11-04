import Metal
import Foundation

/// Process-wide Metal objects shared by every terminal view.
public final class MetalContext {
    public static let shared: MetalContext = {
        guard let c = MetalContext() else { fatalError("Metal is not available on this Mac") }
        return c
    }()

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    let rectPipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    let imagePipeline: MTLRenderPipelineState
    let trailPipeline: MTLRenderPipelineState
    public let pixelFormat: MTLPixelFormat = .bgra8Unorm

    private var fontCache: [String: (FontSet, GlyphAtlas)] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        queue.label = "vitterm"

        guard let library = MetalContext.loadLibrary(device) else { return nil }

        func pipeline(_ v: String, _ f: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = library.makeFunction(name: f)
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = true
            // Premultiplied alpha.
            a.sourceRGBBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .one
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let r = pipeline("rect_vertex", "rect_fragment"),
              let g = pipeline("glyph_vertex", "glyph_fragment"),
              let i = pipeline("image_vertex", "image_fragment"),
              let t = pipeline("trail_vertex", "trail_fragment") else { return nil }
        trailPipeline = t
        rectPipeline = r
        glyphPipeline = g
        imagePipeline = i
    }

    /// Prefer the precompiled metallib shipped in the app bundle; fall back to compiling the source.
    static func loadLibrary(_ device: MTLDevice) -> MTLLibrary? {
        if let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
           let lib = try? device.makeLibrary(URL: url) {
            return lib
        }
        if let url = (Bundle.main.url(forResource: "Shaders", withExtension: "metal") ?? Bundle.module.url(forResource: "Shaders", withExtension: "metal")),
           let src = try? String(contentsOf: url, encoding: .utf8) {
            do {
                return try device.makeLibrary(source: src, options: nil)
            } catch {
                NSLog("vitterm: shader compile failed: \(error)")
            }
        }
        return nil
    }

    /// Fonts + atlas for a given font configuration and backing scale, shared between views.
    func fonts(for spec: FontSpec, scale: CGFloat) -> (FontSet, GlyphAtlas) {
        let key = "\(spec.cacheKey)@\(scale)"
        if let f = fontCache[key] { return f }
        let fs = FontSet(spec: spec, scale: scale)
        let atlas = GlyphAtlas(device: device, fonts: fs, thicken: spec.thicken)
        fontCache[key] = (fs, atlas)
        if fontCache.count > 12 { fontCache = fontCache.filter { $0.key == key } }
        return (fs, atlas)
    }

    public func purgeFonts() { fontCache.removeAll() }
}
