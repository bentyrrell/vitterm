import Foundation

extension Terminal {
    public func oscDispatch(_ data: UnsafeBufferPointer<UInt8>) {
        lastPrintValid = false
        // Split off the numeric command.
        var sep = 0
        while sep < data.count && data[sep] != 0x3B { sep += 1 }
        guard let cmd = Int(String(decoding: UnsafeBufferPointer(rebasing: data[0..<sep]), as: UTF8.self)) else { return }
        let rest = sep < data.count ? UnsafeBufferPointer(rebasing: data[(sep + 1)...]) : UnsafeBufferPointer(start: nil, count: 0)

        // OSC 1337 File= can be huge; avoid making a String of it unless needed.
        if cmd == 1337 {
            iterm2(rest)
            return
        }
        let payload = String(decoding: rest, as: UTF8.self)

        switch cmd {
        case 0, 2:
            let t = Terminal.sanitizeTitle(payload)
            title = t
            pendingEvents.append(.title(t))
        case 1:
            break
        case 4:
            setPaletteColors(payload)
        case 7:
            // file://host/path (path may or may not be percent-encoded), or a bare path. Only local
            // hosts count: a remote shell (ssh) reporting its directory must not steer new local
            // tabs or the window's proxy icon to an arbitrary local path.
            var path: String?
            if payload.hasPrefix("file://") {
                let rest = payload.dropFirst(7)
                if let slash = rest.firstIndex(of: "/"), Terminal.isLocalHost(String(rest[..<slash])) {
                    let raw = String(rest[slash...])
                    path = raw.removingPercentEncoding ?? raw
                }
            } else if payload.hasPrefix("/") {
                path = payload
            }
            if let path, let p = Terminal.sanitizeDirectory(path) {
                workingDirectory = p
                pendingEvents.append(.workingDirectory(p))
            }
        case 8:
            // OSC 8 ; params ; URI
            guard let semi = payload.firstIndex(of: ";") else { return }
            let params = payload[..<semi]
            let uri = String(payload[payload.index(after: semi)...])
            if uri.isEmpty {
                pen.hyperlink = 0
            } else {
                var id = ""
                for kv in params.split(separator: ":") where kv.hasPrefix("id=") { id = String(kv.dropFirst(3)) }
                pen.hyperlink = hyperlinks.intern(id: id, uri: uri)
            }
            updatePenExtra()
        case 9:
            if payload.hasPrefix("4;") {
                let parts = payload.split(separator: ";").compactMap { Int($0) }
                if parts.count >= 2 { pendingEvents.append(.progress(state: parts[1], value: parts.count > 2 ? parts[2] : 0)) }
            } else {
                pendingEvents.append(.notification(title: "", body: payload))
            }
        case 10, 11, 12:
            dynamicColors(start: cmd, payload)
        case 52:
            clipboard(payload)
        case 104:
            if payload.isEmpty {
                palette = basePalette
            } else {
                for s in payload.split(separator: ";") { if let i = Int(s), i >= 0 && i < 256 { palette[i] = basePalette[i] } }
            }
            pendingEvents.append(.colorsChanged)
            grid.touchAll()
        case 110: defaultForeground = baseForeground; pendingEvents.append(.colorsChanged); grid.touchAll()
        case 111: defaultBackground = baseBackground; pendingEvents.append(.colorsChanged); grid.touchAll()
        case 112: cursorColor = baseCursorColor; pendingEvents.append(.colorsChanged)
        case 133:
            // Shell integration: A = prompt start.
            if payload.hasPrefix("A") { currentLine.promptMark = true }
        case 777:
            let parts = payload.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
            if parts.count >= 3 && parts[0] == "notify" {
                pendingEvents.append(.notification(title: String(parts[1]), body: String(parts[2])))
            }
        default:
            break
        }
    }

    func setPaletteColors(_ payload: String) {
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        var i = 0
        var changed = false
        while i + 1 < parts.count {
            guard let idx = Int(parts[i]), idx >= 0 && idx < 256 else { i += 2; continue }
            let spec = parts[i + 1]
            if spec == "?" {
                reply("\u{1B}]4;\(idx);\(Terminal.formatColor(palette[idx]))\u{1B}\\")
            } else if let c = Terminal.parseColor(String(spec)) {
                palette[idx] = c
                changed = true
            }
            i += 2
        }
        if changed {
            pendingEvents.append(.colorsChanged)
            grid.touchAll()
        }
    }

    func dynamicColors(start: Int, _ payload: String) {
        var cmd = start
        for spec in payload.split(separator: ";", omittingEmptySubsequences: false) {
            if spec == "?" {
                let c: UInt32
                switch cmd {
                case 10: c = defaultForeground
                case 11: c = defaultBackground
                default: c = cursorColor ?? defaultForeground
                }
                reply("\u{1B}]\(cmd);\(Terminal.formatColor(c))\u{1B}\\")
            } else if let c = Terminal.parseColor(String(spec)) {
                switch cmd {
                case 10: defaultForeground = c
                case 11: defaultBackground = c
                case 12: cursorColor = c
                default: break
                }
                pendingEvents.append(.colorsChanged)
                grid.touchAll()
            }
            cmd += 1
            if cmd > 12 { break }
        }
    }

    func clipboard(_ payload: String) {
        guard let semi = payload.firstIndex(of: ";") else { return }
        let data = payload[payload.index(after: semi)...]
        if data == "?" {
            if allowClipboardRead { pendingEvents.append(.clipboardRead) }
            return
        }
        // Base64 is 4/3 the size of the text it encodes.
        guard data.utf8.count <= Terminal.maxClipboardWrite / 3 * 4 + 4 else { return }
        if let d = Data(base64Encoded: String(data)), let s = String(data: d, encoding: .utf8) {
            pendingEvents.append(.clipboardWrite(s))
        }
    }

    /// The local host names an OSC 7 URL may name (empty and "localhost" included).
    nonisolated(unsafe) public static var localHostNames: Set<String> = {
        var names: Set<String> = ["", "localhost"]
        let h = ProcessInfo.processInfo.hostName.lowercased()
        names.insert(h)
        if let short = h.split(separator: ".").first { names.insert(String(short)) }
        var buf = [CChar](repeating: 0, count: 256)
        if gethostname(&buf, buf.count) == 0 {
            let g = String(cString: buf).lowercased()
            names.insert(g)
            if let short = g.split(separator: ".").first { names.insert(String(short)) }
        }
        return names
    }()

    static func isLocalHost(_ host: String) -> Bool { localHostNames.contains(host.lowercased()) }

    /// A reported working directory: absolute, bounded, and free of control and bidi characters
    /// (it is shown in tab titles and the window's proxy icon). Nil if unacceptable.
    public static func sanitizeDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { u in
                  switch u.value {
                  case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
                  default: return false
                  }
              }) else { return nil }
        return path
    }

    /// Largest OSC 52 clipboard write accepted, in bytes.
    public static let maxClipboardWrite = 4 * 1024 * 1024
    /// Longest window title kept, in characters.
    public static let maxTitleLength = 1024

    /// Window titles come from untrusted output: drop control characters (C0, DEL, C1) and bidi
    /// overrides/isolates that could make a title display as something else, and cap the length.
    public static func sanitizeTitle(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x00...0x1F, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: continue
            default: scalars.append(u)
            }
        }
        let t = String(scalars)
        return t.count > maxTitleLength ? String(t.prefix(maxTitleLength)) : t
    }

    /// Answer an OSC 52 read request (called by the UI with the pasteboard contents).
    public func replyClipboard(_ text: String) {
        reply("\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{1B}\\")
    }

    /// Parse `rgb:r/g/b` (1-4 hex digits per channel) and `#rgb` style specs into 0x00RRGGBB.
    public static func parseColor(_ s: String) -> UInt32? {
        func channel(_ h: Substring) -> UInt32? {
            guard !h.isEmpty && h.count <= 4, let v = UInt32(h, radix: 16) else { return nil }
            let max = (UInt32(1) << (4 * UInt32(h.count))) - 1
            return (v * 255 + max / 2) / max
        }
        if s.hasPrefix("rgb:") {
            let parts = s.dropFirst(4).split(separator: "/")
            guard parts.count == 3, let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
            return r << 16 | g << 8 | b
        }
        if s.hasPrefix("#") {
            let hex = s.dropFirst()
            guard hex.count % 3 == 0 && hex.count >= 3 && hex.count <= 12 else { return nil }
            let n = hex.count / 3
            let a = hex.startIndex, b = hex.index(a, offsetBy: n), c = hex.index(b, offsetBy: n)
            guard let r = channel(hex[a..<b]), let g = channel(hex[b..<c]), let bl = channel(hex[c...]) else { return nil }
            return r << 16 | g << 8 | bl
        }
        return nil
    }

    static func formatColor(_ c: UInt32) -> String {
        let r = c >> 16 & 0xFF, g = c >> 8 & 0xFF, b = c & 0xFF
        return String(format: "rgb:%02x%02x/%02x%02x/%02x%02x", r, r, g, g, b, b)
    }

    // MARK: DCS

    public func dcsDispatch(_ header: CSISequence, data: UnsafeBufferPointer<UInt8>) {
        lastPrintValid = false
        let s = String(decoding: data, as: UTF8.self)
        switch (header.intermediate, header.final) {
        case (0x24, 0x71): // $ q  DECRQSS
            switch s {
            case "m": reply("\u{1B}P1$r0m\u{1B}\\")
            case "r": reply("\u{1B}P1$r\(scrollTop + 1);\(scrollBottom + 1)r\u{1B}\\")
            case " q":
                let n: Int
                switch cursorShape {
                case .underline: n = cursorShapeBlinks == false ? 4 : 3
                case .bar: n = cursorShapeBlinks == false ? 6 : 5
                default: n = cursorShapeBlinks == false ? 2 : 1
                }
                reply("\u{1B}P1$r\(n) q\u{1B}\\")
            default: reply("\u{1B}P0$r\u{1B}\\")
            }
        case (0x2B, 0x71): // + q  XTGETTCAP
            for hexName in s.split(separator: ";") {
                guard let name = Terminal.hexDecode(String(hexName)) else { continue }
                let value: String?
                switch name {
                case "TN", "name": value = "xterm-256color"
                case "Co", "colors": value = "256"
                case "RGB": value = "8/8/8"
                default: value = nil
                }
                if let v = value {
                    reply("\u{1B}P1+r\(hexName)=\(Terminal.hexEncode(v))\u{1B}\\")
                } else {
                    reply("\u{1B}P0+r\(hexName)\u{1B}\\")
                }
            }
        default:
            break
        }
    }

    static func hexDecode(_ s: String) -> String? {
        var bytes: [UInt8] = []
        var it = s.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let v = UInt8(String([a, b]), radix: 16) else { return nil }
            bytes.append(v)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func hexEncode(_ s: String) -> String {
        s.utf8.map { String(format: "%02X", $0) }.joined()
    }

    // MARK: APC (Kitty graphics)

    public func apcDispatch(_ data: UnsafeBufferPointer<UInt8>) {
        lastPrintValid = false
        guard data.count > 0, data[0] == 0x47 else { return } // 'G'
        kittyGraphics(UnsafeBufferPointer(rebasing: data[1...]))
    }
}
