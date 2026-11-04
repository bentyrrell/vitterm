/// A platform-neutral key event.
public struct KeyInput: Sendable {
    public enum Key: Equatable, Sendable {
        /// A key that produces a character; the scalar is the unshifted base key (e.g. "a", "1", "[").
        case char(UInt32)
        case enter, tab, backspace, escape, space
        case up, down, left, right, home, end, pageUp, pageDown, insert, delete
        case f(Int)
        /// Keypad keys (scalar of the key's character).
        case keypad(UInt32)
    }

    public struct Mods: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Mods(rawValue: 1)
        public static let alt = Mods(rawValue: 2)
        public static let ctrl = Mods(rawValue: 4)
        public static let `super` = Mods(rawValue: 8)
        public static let capsLock = Mods(rawValue: 64)
    }

    public enum Event: Sendable { case press, `repeat`, release }

    public var key: Key
    public var mods: Mods
    /// Text the key produces with the current modifiers (after Option composition when Option is not Alt).
    public var text: String
    /// Text with only Shift applied (used for Alt-as-Meta).
    public var unmodifiedText: String
    public var event: Event

    public init(key: Key, mods: Mods, text: String, unmodifiedText: String? = nil, event: Event = .press) {
        self.key = key; self.mods = mods; self.text = text; self.unmodifiedText = unmodifiedText ?? text; self.event = event
    }
}

/// Encodes key events into the byte sequences applications expect.
public enum KeyEncoder {
    public struct Context: Sendable {
        public var cursorKeysApp = false
        public var keypadApp = false
        public var kittyFlags: UInt8 = 0
        public var newlineMode = false
        public init(cursorKeysApp: Bool = false, keypadApp: Bool = false, kittyFlags: UInt8 = 0, newlineMode: Bool = false) {
            self.cursorKeysApp = cursorKeysApp; self.keypadApp = keypadApp; self.kittyFlags = kittyFlags; self.newlineMode = newlineMode
        }
    }

    /// Returns the bytes to send, or an empty array if the event should produce nothing.
    public static func encode(_ k: KeyInput, _ ctx: Context) -> [UInt8] {
        if ctx.kittyFlags != 0 { return kitty(k, ctx) }
        if k.event == .release { return [] }
        return legacy(k, ctx)
    }

    // MARK: Legacy (xterm) encoding

    static func modParam(_ m: KeyInput.Mods) -> Int {
        var v = 1
        if m.contains(.shift) { v += 1 }
        if m.contains(.alt) { v += 2 }
        if m.contains(.ctrl) { v += 4 }
        return v
    }

    static func csi(_ s: String) -> [UInt8] { Array(("\u{1B}[" + s).utf8) }

    static func legacy(_ k: KeyInput, _ ctx: Context) -> [UInt8] {
        let m = k.mods.subtracting([.super, .capsLock])
        let mp = modParam(m)
        func letterKey(_ c: Character) -> [UInt8] {
            if mp == 1 { return Array(((ctx.cursorKeysApp ? "\u{1B}O" : "\u{1B}[") + String(c)).utf8) }
            return csi("1;\(mp)\(c)")
        }
        func tildeKey(_ n: Int) -> [UInt8] { mp == 1 ? csi("\(n)~") : csi("\(n);\(mp)~") }
        let altPrefix: [UInt8] = m.contains(.alt) ? [0x1B] : []

        switch k.key {
        case .enter: return altPrefix + (ctx.newlineMode ? [0x0D, 0x0A] : [0x0D])
        case .tab:
            if m.contains(.shift) { return csi("Z") }
            return altPrefix + [0x09]
        case .backspace: return altPrefix + [m.contains(.ctrl) ? 0x08 : 0x7F]
        case .escape: return altPrefix + [0x1B]
        case .space:
            if m.contains(.ctrl) { return altPrefix + [0x00] }
            return altPrefix + [0x20]
        case .up: return letterKey("A")
        case .down: return letterKey("B")
        case .right: return letterKey("C")
        case .left: return letterKey("D")
        case .home: return letterKey("H")
        case .end: return letterKey("F")
        case .insert: return tildeKey(2)
        case .delete: return tildeKey(3)
        case .pageUp: return tildeKey(5)
        case .pageDown: return tildeKey(6)
        case .f(let n):
            switch n {
            case 1...4:
                let c = Character(UnicodeScalar(UInt8(0x50 + n - 1)))
                return mp == 1 ? Array(("\u{1B}O" + String(c)).utf8) : csi("1;\(mp)\(c)")
            case 5...12:
                let codes = [15, 17, 18, 19, 20, 21, 23, 24]
                return tildeKey(codes[n - 5])
            case 13...20:
                // F13-F20 as shifted F1-F8 style codes (xterm uses these numbers).
                let codes = [25, 26, 28, 29, 31, 32, 33, 34]
                return tildeKey(codes[n - 13])
            default: return []
            }
        case .keypad(let c):
            if ctx.keypadApp && m.isEmpty {
                let map: [UInt32: Character] = [0x30: "p", 0x31: "q", 0x32: "r", 0x33: "s", 0x34: "t", 0x35: "u", 0x36: "v",
                                                0x37: "w", 0x38: "x", 0x39: "y", 0x2E: "n", 0x2B: "k", 0x2D: "m", 0x2A: "j",
                                                0x2F: "o", 0x3D: "X", 0x0D: "M"]
                if let ch = map[c] { return Array(("\u{1B}O" + String(ch)).utf8) }
            }
            return Array(k.text.utf8)
        case .char(let base):
            if m.contains(.ctrl) {
                if let b = controlByte(base, shifted: m.contains(.shift)) {
                    return altPrefix + [b]
                }
            }
            if m.contains(.alt) {
                return [0x1B] + Array(k.unmodifiedText.utf8)
            }
            return Array(k.text.utf8)
        }
    }

    /// The C0 byte for Ctrl+key, following xterm conventions.
    static func controlByte(_ base: UInt32, shifted: Bool) -> UInt8? {
        switch base {
        case 0x61...0x7A: return UInt8(base - 0x60)     // a-z
        case 0x41...0x5A: return UInt8(base - 0x40)     // A-Z
        case 0x40, 0x32, 0x20: return 0x00               // @ 2 space
        case 0x5B, 0x33: return 0x1B                     // [ 3
        case 0x5C, 0x34: return 0x1C                     // \ 4
        case 0x5D, 0x35: return 0x1D                     // ] 5
        case 0x5E, 0x36: return 0x1E                     // ^ 6
        case 0x5F, 0x37, 0x2D, 0x2F: return 0x1F         // _ 7 - /
        case 0x38, 0x3F: return 0x7F                     // 8 ?
        default: return nil
        }
    }

    // MARK: Kitty keyboard protocol

    static func kitty(_ k: KeyInput, _ ctx: Context) -> [UInt8] {
        let flags = ctx.kittyFlags
        let disambiguate = flags & 1 != 0
        let reportEvents = flags & 2 != 0
        let reportAll = flags & 8 != 0
        let reportText = flags & 16 != 0

        if k.event == .release && !reportEvents { return [] }
        if k.event == .repeat && !reportEvents { /* repeats are sent as presses */ }

        var mods = 0
        if k.mods.contains(.shift) { mods |= 1 }
        if k.mods.contains(.alt) { mods |= 2 }
        if k.mods.contains(.ctrl) { mods |= 4 }
        if k.mods.contains(.super) { mods |= 8 }
        if k.mods.contains(.capsLock) { mods |= 64 }
        let textMods = mods & ~(1 | 64) // modifiers that change meaning beyond text

        // Code and trailer for the key.
        var code: Int
        var final: Character = "u"
        var legacyText: [UInt8]? = nil
        switch k.key {
        case .char(let c): code = Int(c); legacyText = Array(k.text.utf8)
        case .space: code = 32; legacyText = [0x20]
        case .enter: code = 13; legacyText = [0x0D]
        case .tab: code = 9; legacyText = [0x09]
        case .backspace: code = 127; legacyText = [0x7F]
        case .escape: code = 27
        case .up: code = 1; final = "A"
        case .down: code = 1; final = "B"
        case .right: code = 1; final = "C"
        case .left: code = 1; final = "D"
        case .home: code = 1; final = "H"
        case .end: code = 1; final = "F"
        case .insert: code = 2; final = "~"
        case .delete: code = 3; final = "~"
        case .pageUp: code = 5; final = "~"
        case .pageDown: code = 6; final = "~"
        case .f(let n):
            switch n {
            case 1: code = 1; final = "P"
            case 2: code = 1; final = "Q"
            case 3: code = 13; final = "~"
            case 4: code = 1; final = "S"
            case 5...12: code = [15, 17, 18, 19, 20, 21, 23, 24][n - 5]; final = "~"
            default: code = 57376 + (n - 13) // F13+
            }
        case .keypad(let c):
            let map: [UInt32: Int] = [0x30: 57399, 0x31: 57400, 0x32: 57401, 0x33: 57402, 0x34: 57403, 0x35: 57404,
                                      0x36: 57405, 0x37: 57406, 0x38: 57407, 0x39: 57408, 0x2E: 57409, 0x2F: 57410,
                                      0x2A: 57411, 0x2D: 57412, 0x2B: 57413, 0x0D: 57414, 0x3D: 57415]
            code = map[c] ?? Int(c)
            legacyText = Array(k.text.utf8)
        }

        let eventSuffix: String
        switch k.event {
        case .press: eventSuffix = ""
        case .repeat: eventSuffix = reportEvents ? ":2" : ""
        case .release: eventSuffix = ":3"
        }

        // Plain text keys keep legacy behavior unless "report all keys" is on.
        if !reportAll, let text = legacyText, textMods == 0 {
            if k.event == .release { return [] }
            switch k.key {
            case .enter, .tab, .backspace:
                if mods == 0 { return text }
            default:
                if !text.isEmpty && !(disambiguate && k.mods.contains(.alt)) { return text }
            }
        }
        if !reportAll && !disambiguate && k.event != .release {
            return legacy(k, Context(cursorKeysApp: ctx.cursorKeysApp, keypadApp: ctx.keypadApp))
        }
        if k.event == .release && !reportAll, case .char = k.key, textMods == 0 { return [] }

        var s = "\u{1B}["
        if final == "u" || final == "~" {
            s += "\(code)"
        } else if mods != 0 || !eventSuffix.isEmpty {
            s += "1"
        }
        if mods != 0 || !eventSuffix.isEmpty {
            s += ";\(mods + 1)\(eventSuffix)"
        }
        if reportText && final == "u", k.event != .release, !k.text.isEmpty, let first = k.text.unicodeScalars.first, first.value >= 0x20 {
            if mods == 0 && eventSuffix.isEmpty { s += ";" }
            s += ";" + k.text.unicodeScalars.map { String($0.value) }.joined(separator: ":")
        }
        s.append(final)
        return Array(s.utf8)
    }
}
