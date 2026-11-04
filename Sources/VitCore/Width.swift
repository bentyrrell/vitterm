/// Terminal display width of Unicode scalars (0, 1 or 2 cells).
public enum CharWidth {
    /// Flat lookup for planes 0-3 (covers all assigned wide characters). Values are 0, 1 or 2.
    private static let table: [UInt8] = {
        var t = [UInt8](repeating: 1, count: 0x40000)
        var i = 0
        while i < widthRanges.count {
            let lo = Int(widthRanges[i]), hi = Int(widthRanges[i + 1]), w = UInt8(widthRanges[i + 2])
            if lo < 0x40000 {
                let end = min(hi, 0x3FFFF)
                t.withUnsafeMutableBufferPointer { buf in
                    for cp in lo...end { buf[cp] = w }
                }
            }
            i += 3
        }
        return t
    }()

    /// Width of a printable scalar. C0/C1 controls are never passed here.
    @inlinable public static func of(_ cp: UInt32) -> Int {
        if cp < 0x300 { return 1 }
        return slow(cp)
    }

    @usableFromInline static func slow(_ cp: UInt32) -> Int {
        if cp < 0x40000 { return Int(table[Int(cp)]) }
        // Tags and variation selectors supplement are zero width; everything else is narrow.
        if cp >= 0xE0000 && cp <= 0xE0FFF { return 0 }
        return 1
    }

    /// Codepoints that extend the previous grapheme cluster even though they have non-zero width.
    @inlinable public static func isEmojiModifier(_ cp: UInt32) -> Bool { cp >= 0x1F3FB && cp <= 0x1F3FF }
    @inlinable public static func isRegionalIndicator(_ cp: UInt32) -> Bool { cp >= 0x1F1E6 && cp <= 0x1F1FF }
}
