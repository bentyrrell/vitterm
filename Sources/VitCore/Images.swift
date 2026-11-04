import Foundation
import ImageIO
import Compression

/// A decoded image: RGBA8, premultiplied alpha, row-major, no padding.
public final class TerminalImage {
    public let id: UInt32
    public let number: UInt32
    public let width: Int
    public let height: Int
    public let rgba: Data
    /// Unique per upload so the renderer can key GPU textures.
    public let uploadID: UInt64

    init(id: UInt32, number: UInt32, width: Int, height: Int, rgba: Data, uploadID: UInt64) {
        self.id = id; self.number = number; self.width = width; self.height = height; self.rgba = rgba; self.uploadID = uploadID
    }
}

public struct ImagePlacement {
    public var imageID: UInt32
    public var placementID: UInt32
    public var onAlternate: Bool
    /// Absolute line number (see `Grid.absolute(screenRow:)`) of the top row.
    public var line: Int
    public var col: Int
    public var cols: Int
    public var rows: Int
    /// Source rectangle in image pixels.
    public var srcX: Int, srcY: Int, srcW: Int, srcH: Int
    /// Pixel offset inside the first cell.
    public var offsetX: Int, offsetY: Int
    public var z: Int32
    /// How the image fills its cell box: natural pixel size, stretched, or aspect-fit.
    public var fit: ImageFit
    /// Insertion order, for dropping the oldest placement when over the limit.
    var serial: UInt64 = 0
}

public enum ImageFit: Sendable { case natural, stretch, aspectFit }

public final class ImageStore {
    public private(set) var images: [UInt32: TerminalImage] = [:]
    public private(set) var placements: [ImagePlacement] = []
    /// Bumped whenever images or placements change.
    public private(set) var version: UInt64 = 0
    private var nextUpload: UInt64 = 1
    private var nextAutoID: UInt32 = 0x8000_0000
    private var totalBytes = 0
    public static var memoryLimit = 320 * 1024 * 1024
    /// Most placements kept; beyond this the oldest is dropped.
    public static let maxPlacements = 4096
    private var nextSerial: UInt64 = 0

    // Limits on untrusted image input (any program's output can send images).
    /// Largest image accepted, in pixels per side and in total (32 MP is 128 MB decoded).
    static let maxSide = 10_000
    static let maxPixels = 32_000_000
    /// Largest transfer (base64 payload, chunked or not), decompressed stream, or file read.
    nonisolated(unsafe) static var maxTransferBytes = 128 * 1024 * 1024
    /// Largest placement, in cells, and largest pixel offset within a cell.
    static let maxCells = 1000

    /// A numeric Kitty control key, clamped to ±2^40: wide enough for 32-bit ids and sizes, small
    /// enough that no later arithmetic (`top + y`, `x - 1`, `col + cols`) can overflow, since
    /// release builds don't check.
    static func key(_ c: [UInt8: String], _ k: Character, _ def: Int) -> Int {
        guard let v = c[k.asciiValue!].flatMap({ Int($0) }) else { return def }
        return min(max(v, -(1 << 40)), 1 << 40)
    }

    static func validSize(_ w: Int, _ h: Int) -> Bool {
        w > 0 && h > 0 && w <= maxSide && h <= maxSide && w * h <= maxPixels
    }

    /// Clamp a requested cell count (possibly absurd) to 0...maxCells.
    static func clampCells(_ v: Int) -> Int { min(max(v, 0), maxCells) }

    /// Cell count from a computed size, guarding against NaN/infinity and huge values.
    static func cells(_ d: Double) -> Int {
        guard d.isFinite else { return 1 }
        return Int(min(max(d.rounded(.up), 1), Double(maxCells)))
    }

    /// Read a regular file for `t=f`/`t=t`, refusing devices, pipes, sockets and anything over the
    /// size limit. Opened non-blocking and checked with fstat on the open descriptor, so a path
    /// swapped for a FIFO after a check can't hang the PTY thread.
    static func readRegularFile(_ path: String, offset: Int, length: Int) -> Data? {
        guard path.hasPrefix("/"), !path.hasPrefix("/dev/") else { return nil }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(st.st_size)
        let start = min(max(offset, 0), size)
        let want = length > 0 ? min(length, size - start) : size - start
        guard want <= maxTransferBytes else { return nil }
        var out = Data(count: want)
        var got = 0
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            while got < want {
                let n = pread(fd, buf.baseAddress! + got, want - got, off_t(start + got))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return n == 0 }
                got += n
            }
            return true
        }
        guard ok else { return nil }
        if got < want { out.count = got }
        return out
    }

    /// For `t=t`: the resolved path, if `path` is a graphics temp file we may delete (inside a temp
    /// directory after resolving `..` and symlinks, with the protocol's marker in its own name).
    static func deletableTempFile(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let r = String(cString: resolved)
        guard (r as NSString).lastPathComponent.contains("tty-graphics-protocol") else { return nil }
        var roots = ["/private/tmp/", "/private/var/folders/"]
        if let t = realpath(NSTemporaryDirectory(), nil) { roots.append(String(cString: t) + "/"); free(t) }
        return roots.contains(where: { r.hasPrefix($0) }) ? r : nil
    }

    // Chunked kitty transmission in progress.
    var pendingControl: [UInt8: String] = [:]
    var pendingData: [UInt8] = []
    var pendingActive = false

    public init() {}

    public var isEmpty: Bool { placements.isEmpty }

    func add(id: UInt32?, number: UInt32, width: Int, height: Int, rgba: Data) -> TerminalImage {
        let id = id ?? { nextAutoID &+= 1; return nextAutoID }()
        if let old = images[id] { totalBytes -= old.rgba.count }
        let img = TerminalImage(id: id, number: number, width: width, height: height, rgba: rgba, uploadID: nextUpload)
        nextUpload &+= 1
        images[id] = img
        totalBytes += rgba.count
        evictIfNeeded(keep: id)
        version &+= 1
        return img
    }

    func evictIfNeeded(keep: UInt32) {
        guard totalBytes > ImageStore.memoryLimit else { return }
        // Evict images without placements first, then oldest uploads.
        let placed = Set(placements.map(\.imageID))
        let order = images.values.sorted { a, b in
            let pa = placed.contains(a.id), pb = placed.contains(b.id)
            if pa != pb { return !pa }
            return a.uploadID < b.uploadID
        }
        for img in order where totalBytes > ImageStore.memoryLimit && img.id != keep {
            remove(imageID: img.id)
        }
    }

    func remove(imageID: UInt32) {
        if let img = images.removeValue(forKey: imageID) { totalBytes -= img.rgba.count }
        placements.removeAll { $0.imageID == imageID }
        version &+= 1
    }

    func place(_ p: ImagePlacement) {
        if p.placementID != 0 {
            placements.removeAll { $0.imageID == p.imageID && $0.placementID == p.placementID }
        }
        // Bounded: drop the oldest placement beyond the limit (each costs work in every frame).
        if placements.count >= ImageStore.maxPlacements, let oldest = placements.indices.min(by: { placements[$0].serial < placements[$1].serial }) {
            let id = placements[oldest].imageID
            placements.remove(at: oldest)
            if !placements.contains(where: { $0.imageID == id }) && images[id]?.number == 0 && id >= 0x8000_0000 { remove(imageID: id) }
        }
        var q = p
        nextSerial &+= 1
        q.serial = nextSerial
        // Keep sorted by z (stable: after existing placements with the same z) without re-sorting.
        let at = placements.firstIndex { $0.z > q.z } ?? placements.count
        placements.insert(q, at: at)
        version &+= 1
    }

    func removePlacements(where pred: (ImagePlacement) -> Bool, freeImages: Bool) {
        let removed = placements.filter(pred)
        guard !removed.isEmpty else { return }
        placements.removeAll(where: pred)
        if freeImages {
            let still = Set(placements.map(\.imageID))
            for id in Set(removed.map(\.imageID)) where !still.contains(id) { remove(imageID: id) }
        }
        version &+= 1
    }

    public func removeAll() {
        images.removeAll()
        placements.removeAll()
        totalBytes = 0
        version &+= 1
    }

    /// Drop placements that scrolled out of scrollback.
    func prune(primaryFirstLine: Int) {
        if placements.contains(where: { !$0.onAlternate && $0.line + $0.rows <= primaryFirstLine }) {
            removePlacements(where: { !$0.onAlternate && $0.line + $0.rows <= primaryFirstLine }, freeImages: true)
        }
    }

    func clampPlacements(rows: Int) { version &+= 1 }

    // MARK: Decoding

    static func decodeEncoded(_ data: Data) -> (Int, Int, Data)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? Int, let ph = props[kCGImagePropertyPixelHeight] as? Int,
              validSize(pw, ph), // check before decoding anything
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return rasterize(cg)
    }

    static func rasterize(_ cg: CGImage) -> (Int, Int, Data)? {
        let w = cg.width, h = cg.height
        guard validSize(w, h) else { return nil }
        var out = Data(count: w * h * 4)
        let ok = out.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (w, h, out) : nil
    }

    /// Raw RGB/RGBA (straight alpha) to premultiplied RGBA.
    static func fromRaw(_ data: Data, width: Int, height: Int, channels: Int) -> Data? {
        guard validSize(width, height), data.count >= width * height * channels else { return nil }
        var out = Data(count: width * height * 4)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self), d = dst.bindMemory(to: UInt8.self)
                for i in 0..<(width * height) {
                    let a: UInt16 = channels == 4 ? UInt16(s[i * channels + 3]) : 255
                    d[i * 4 + 0] = UInt8(UInt16(s[i * channels + 0]) * a / 255)
                    d[i * 4 + 1] = UInt8(UInt16(s[i * channels + 1]) * a / 255)
                    d[i * 4 + 2] = UInt8(UInt16(s[i * channels + 2]) * a / 255)
                    d[i * 4 + 3] = UInt8(a)
                }
            }
        }
        return out
    }

    /// Inflate zlib (RFC 1950) data.
    static func inflate(_ data: Data, maxOutput: Int = ImageStore.maxTransferBytes) -> Data? {
        guard data.count > 6 else { return nil }
        let body = data.subdata(in: 2..<(data.count - 4)) // strip zlib header and adler32
        var out = Data()
        let chunk = 1 << 16
        let ok: Bool = body.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return false }
            defer { compression_stream_destroy(stream) }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
            defer { dst.deallocate() }
            stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress!
            stream.pointee.src_size = src.count
            while true {
                stream.pointee.dst_ptr = dst
                stream.pointee.dst_size = chunk
                let st = compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(dst, count: chunk - stream.pointee.dst_size)
                if st == COMPRESSION_STATUS_END { return true }
                if st == COMPRESSION_STATUS_ERROR || out.count > maxOutput { return false }
            }
        }
        return ok ? out : nil
    }
}

// MARK: - Protocol handling

extension Terminal {
    /// Kitty graphics protocol: `ESC _ G <control> ; <base64 payload> ESC \`.
    func kittyGraphics(_ body: UnsafeBufferPointer<UInt8>) {
        var semi = 0
        while semi < body.count && body[semi] != 0x3B { semi += 1 }
        var control: [UInt8: String] = [:]
        for kv in String(decoding: UnsafeBufferPointer(rebasing: body[0..<semi]), as: UTF8.self).split(separator: ",") {
            guard let eq = kv.firstIndex(of: "="), let k = kv.first?.asciiValue else { continue }
            control[k] = String(kv[kv.index(after: eq)...])
        }
        let payload = semi < body.count ? Array(body[(semi + 1)...]) : []

        let store = images
        // Continuation of a chunked transfer.
        if store.pendingActive {
            guard store.pendingData.count + payload.count <= ImageStore.maxTransferBytes else {
                // Too large: abandon the transfer rather than grow without bound.
                store.pendingActive = false
                store.pendingData = []
                return
            }
            store.pendingData.append(contentsOf: payload)
            if control[UInt8(ascii: "m")] == "1" { return }
            store.pendingActive = false
            let ctl = store.pendingControl
            let data = store.pendingData
            store.pendingData = []
            kittyExecute(ctl, payload: data)
            return
        }
        if control[UInt8(ascii: "m")] == "1" {
            store.pendingActive = true
            store.pendingControl = control
            store.pendingData = payload
            return
        }
        kittyExecute(control, payload: payload)
    }

    private func kittyExecute(_ c: [UInt8: String], payload: [UInt8]) {
        func int(_ k: Character, _ def: Int = 0) -> Int { ImageStore.key(c, k, def) }
        func str(_ k: Character) -> String? { c[k.asciiValue!] }
        let action = str("a") ?? "t"
        let quiet = int("q")
        let id = UInt32(clamping: int("i"))
        let number = UInt32(clamping: int("I"))

        func respond(_ msg: String, ok: Bool) {
            if quiet >= 2 || (ok && quiet >= 1) { return }
            if id == 0 && number == 0 { return }
            var keys = id != 0 ? "i=\(id)" : ""
            if number != 0 { keys += (keys.isEmpty ? "" : ",") + "I=\(number)" }
            reply("\u{1B}_G\(keys);\(msg)\u{1B}\\")
        }

        switch action {
        case "t", "T", "q":
            let t0 = DispatchTime.now().uptimeNanoseconds
            let decodedImage = kittyDecode(c, payload: payload)
            imageWorkNanos &+= DispatchTime.now().uptimeNanoseconds &- t0
            guard let decoded = decodedImage else {
                respond("EBADF:could not decode image", ok: false)
                return
            }
            if action == "q" { respond("OK", ok: true); return }
            let img = images.add(id: id != 0 ? id : nil, number: number, width: decoded.0, height: decoded.1, rgba: decoded.2)
            if action == "T" { kittyPlace(img, c) }
            respond("OK", ok: true)
        case "p":
            let img = id != 0 ? images.images[id] : images.images.values.filter { $0.number == number }.max { $0.uploadID < $1.uploadID }
            guard let img else { respond("ENOENT:no such image", ok: false); return }
            kittyPlace(img, c)
            respond("OK", ok: true)
        case "d":
            kittyDelete(c)
        default:
            break
        }
        dirty = true
    }

    private func kittyDecode(_ c: [UInt8: String], payload: [UInt8]) -> (Int, Int, Data)? {
        func int(_ k: Character, _ def: Int = 0) -> Int { ImageStore.key(c, k, def) }
        let medium = c[UInt8(ascii: "t")] ?? "d"
        let format = int("f", 32)
        guard var raw = Data(base64Encoded: Data(payload), options: .ignoreUnknownCharacters) else { return nil }
        switch medium {
        case "d":
            break
        case "f", "t":
            guard allowImageFiles, let path = String(data: raw, encoding: .utf8) else { return nil }
            // Temp files must resolve into a temp directory and carry the protocol's marker in
            // their own name; they are deleted after reading.
            var deletable: String?
            if medium == "t" {
                guard let d = ImageStore.deletableTempFile(path) else { return nil }
                deletable = d
            }
            guard let data = ImageStore.readRegularFile(deletable ?? path, offset: int("O"), length: int("S")) else { return nil }
            raw = data
            if let deletable { unlink(deletable) }
        default:
            return nil
        }
        if c[UInt8(ascii: "o")] == "z" {
            // Raw pixels can't decompress to more than w*h*channels; encoded images get the
            // general transfer limit. Stops decompression bombs.
            let w = int("s"), h = int("v")
            let cap = (format == 24 || format == 32) && ImageStore.validSize(w, h) ? w * h * (format == 24 ? 3 : 4) : ImageStore.maxTransferBytes
            guard let inflated = ImageStore.inflate(raw, maxOutput: cap) else { return nil }
            raw = inflated
        }
        switch format {
        case 100:
            return ImageStore.decodeEncoded(raw)
        case 24, 32:
            let w = int("s"), h = int("v")
            guard let rgba = ImageStore.fromRaw(raw, width: w, height: h, channels: format == 24 ? 3 : 4) else { return nil }
            return (w, h, rgba)
        default:
            return nil
        }
    }

    private func kittyPlace(_ img: TerminalImage, _ c: [UInt8: String]) {
        func int(_ k: Character, _ def: Int = 0) -> Int { ImageStore.key(c, k, def) }
        let sx = max(0, int("x")), sy = max(0, int("y"))
        let sw = int("w") > 0 ? min(int("w"), img.width - sx) : img.width - sx
        let sh = int("h") > 0 ? min(int("h"), img.height - sy) : img.height - sy
        guard sw > 0 && sh > 0 else { return }
        let cw = max(cellPixelWidth, 1), ch = max(cellPixelHeight, 1)
        // Offsets are within the first cell; counts are clamped (untrusted, and used in cursor math).
        let offX = min(max(int("X"), 0), cw - 1), offY = min(max(int("Y"), 0), ch - 1)
        let ncols = int("c") > 0 ? ImageStore.clampCells(int("c")) : ImageStore.clampCells((sw + offX + cw - 1) / cw)
        let nrows = int("r") > 0 ? ImageStore.clampCells(int("r")) : ImageStore.clampCells((sh + offY + ch - 1) / ch)
        let fit: ImageFit = (int("c") > 0 || int("r") > 0) ? .stretch : .natural
        placeImage(img, cols: ncols, rows: nrows, src: (sx, sy, sw, sh), offset: (offX, offY),
                   z: Int32(clamping: int("z")), placementID: UInt32(clamping: int("p")), moveCursor: int("C") == 0, fit: fit)
    }

    func placeImage(_ img: TerminalImage, cols requestedCols: Int, rows requestedRows: Int, src: (Int, Int, Int, Int), offset: (Int, Int),
                    z: Int32, placementID: UInt32, moveCursor: Bool, fit: ImageFit) {
        let ncols = ImageStore.clampCells(requestedCols), nrows = ImageStore.clampCells(requestedRows)
        let p = ImagePlacement(imageID: img.id, placementID: placementID, onAlternate: usingAlternate,
                               line: grid.absolute(screenRow: cursorY), col: cursorX,
                               cols: max(1, ncols), rows: max(1, nrows),
                               srcX: src.0, srcY: src.1, srcW: src.2, srcH: src.3,
                               offsetX: offset.0, offsetY: offset.1, z: z, fit: fit)
        images.place(p)
        if moveCursor {
            for _ in 0..<(max(1, nrows) - 1) { index() }
            cursorX = min(cursorX + max(1, ncols), cols - 1)
            pendingWrap = false
        }
    }

    private func kittyDelete(_ c: [UInt8: String]) {
        func int(_ k: Character, _ def: Int = 0) -> Int { ImageStore.key(c, k, def) }
        let d = c[UInt8(ascii: "d")] ?? "a"
        let free = d.uppercased() == d
        let alt = usingAlternate
        let top = grid.absolute(screenRow: 0)
        func covers(_ p: ImagePlacement, x: Int, y: Int) -> Bool {
            let absY = top + y
            return x >= p.col && x < p.col + p.cols && absY >= p.line && absY < p.line + p.rows
        }
        switch d.lowercased() {
        case "a":
            images.removePlacements(where: { $0.onAlternate == alt && $0.line + $0.rows > top }, freeImages: free)
        case "i":
            let id = UInt32(clamping: int("i"))
            let pid = UInt32(clamping: int("p"))
            if free && pid == 0 { images.remove(imageID: id) }
            else { images.removePlacements(where: { $0.imageID == id && (pid == 0 || $0.placementID == pid) }, freeImages: free) }
        case "n":
            let n = UInt32(clamping: int("I"))
            let ids = Set(images.images.values.filter { $0.number == n }.map(\.id))
            images.removePlacements(where: { ids.contains($0.imageID) }, freeImages: free)
        case "c":
            images.removePlacements(where: { covers($0, x: cursorX, y: cursorY) }, freeImages: free)
        case "p":
            let x = int("x") - 1, y = int("y") - 1
            images.removePlacements(where: { covers($0, x: x, y: y) }, freeImages: free)
        case "x":
            let x = int("x") - 1
            images.removePlacements(where: { x >= $0.col && x < $0.col + $0.cols }, freeImages: free)
        case "y":
            let y = top + int("y") - 1
            images.removePlacements(where: { y >= $0.line && y < $0.line + $0.rows }, freeImages: free)
        case "z":
            let z = Int32(clamping: int("z"))
            images.removePlacements(where: { $0.z == z }, freeImages: free)
        default:
            break
        }
    }

    /// iTerm2 `OSC 1337 ; File=key=value;...:base64` and a few other 1337 commands.
    func iterm2(_ body: UnsafeBufferPointer<UInt8>) {
        var colon = 0
        while colon < body.count && body[colon] != 0x3A { colon += 1 }
        let header = String(decoding: UnsafeBufferPointer(rebasing: body[0..<colon]), as: UTF8.self)
        if header.hasPrefix("CurrentDir=") {
            guard let dir = Terminal.sanitizeDirectory(String(header.dropFirst("CurrentDir=".count))) else { return }
            workingDirectory = dir
            pendingEvents.append(.workingDirectory(dir))
            return
        }
        guard header.hasPrefix("File="), colon < body.count else { return }
        var args: [String: String] = [:]
        for kv in header.dropFirst(5).split(separator: ";") {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            args[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        guard args["inline"] == "1" else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let decodedImage = Data(base64Encoded: Data(UnsafeBufferPointer(rebasing: body[(colon + 1)...])), options: .ignoreUnknownCharacters)
            .flatMap { ImageStore.decodeEncoded($0) }
        imageWorkNanos &+= DispatchTime.now().uptimeNanoseconds &- t0
        guard let decoded = decodedImage else { return }
        let (w, h, rgba) = decoded
        let cw = max(cellPixelWidth, 1), ch = max(cellPixelHeight, 1)

        // Sizes are untrusted: clamp before any arithmetic.
        func dimension(_ spec: String?, total: Int, cell: Int, natural: Int) -> Int? {
            guard let spec, spec != "auto" else { return nil }
            if spec.hasSuffix("px"), let v = Int(spec.dropLast(2)) {
                return max(1, ImageStore.clampCells((min(max(v, 0), ImageStore.maxSide) + cell - 1) / cell))
            }
            if spec.hasSuffix("%"), let v = Int(spec.dropLast()) { return max(1, ImageStore.clampCells(total * min(max(v, 0), 100) / 100)) }
            if let v = Int(spec) { return max(1, ImageStore.clampCells(v)) }
            return nil
        }
        var ncols = dimension(args["width"], total: cols, cell: cw, natural: w)
        var nrows = dimension(args["height"], total: rows, cell: ch, natural: h)
        let preserve = args["preserveAspectRatio"] != "0"
        switch (ncols, nrows) {
        case (nil, nil):
            var pw = Double(w), ph = Double(h)
            let maxW = Double((cols - cursorX) * cw)
            if pw > maxW { ph *= maxW / pw; pw = maxW }
            ncols = ImageStore.cells(pw / Double(cw))
            nrows = ImageStore.cells(ph / Double(ch))
        case (let c?, nil):
            nrows = ImageStore.cells(Double(c) * Double(cw) * Double(h) / Double(w) / Double(ch))
        case (nil, let r?):
            ncols = ImageStore.cells(Double(r) * Double(ch) * Double(w) / Double(h) / Double(cw))
        case (let c?, let r?):
            if preserve {
                // Fit inside the box.
                let scale = min(Double(c) * Double(cw) / Double(w), Double(r) * Double(ch) / Double(h))
                ncols = ImageStore.cells(Double(w) * scale / Double(cw))
                nrows = ImageStore.cells(Double(h) * scale / Double(ch))
            }
        }
        let img = images.add(id: nil, number: 0, width: w, height: h, rgba: rgba)
        placeImage(img, cols: min(ncols ?? 1, cols), rows: nrows ?? 1, src: (0, 0, w, h), offset: (0, 0),
                   z: 0, placementID: 0, moveCursor: true, fit: .aspectFit)
        // iTerm2 leaves the cursor on the line below the image.
        index()
        cursorX = 0
    }
}
