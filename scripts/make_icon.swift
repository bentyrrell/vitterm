// Builds the vitterm app icon from Resources/AppIcon-source.jpg at the sizes iconutil needs.
// The source is a rounded-square icon on a light background: find the dark body, crop it, mask it
// with rounded corners (so no background shows), and place it on the macOS icon grid.
//   make_icon <source image> <output .iconset dir>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make_icon <source image> <out.iconset>\n".data(using: .utf8)!); exit(1)
}
let out = args[2]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// Read pixels and find the bounding box of the dark body (the background is near-white).
let w = src.width, h = src.height
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
var px = [UInt8](repeating: 0, count: w * h * 4)
let rd = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
rd.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
func dark(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    return (Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2])) / 3 < 110
}
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<h { for x in 0..<w where dark(x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
// Inset a little so the soft, light edge of the source never shows; keep it square.
let inset = 4
let side = min(maxX - minX, maxY - minY) - 2 * inset
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
guard let body = src.cropping(to: CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)) else { exit(1) }

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // macOS icon grid: 824/1024 body, centered, with room for the shadow.
    let b = s * 824 / 1024
    let rect = CGRect(x: (s - b) / 2, y: (s - b) / 2 + s * 0.006, width: b, height: b)
    let path = CGPath(roundedRect: rect, cornerWidth: b * 0.225, cornerHeight: b * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(body, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("body \(minX)...\(maxX) x \(minY)...\(maxY), cropped \(side)px")
