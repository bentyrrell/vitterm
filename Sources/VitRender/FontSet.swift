import AppKit
import CoreText

/// Font configuration (in points); `FontSet` turns it into pixel-size fonts.
public struct FontSpec: Hashable, Sendable {
    public var family: String
    public var boldFamily: String
    public var italicFamily: String
    public var size: CGFloat
    public var features: [String]
    public var ligatures: Bool
    public var thicken: Bool
    public var adjustWidth: Int
    public var adjustHeight: Int

    public init(family: String = "", boldFamily: String = "", italicFamily: String = "", size: CGFloat = 13,
                features: [String] = [], ligatures: Bool = true, thicken: Bool = false, adjustWidth: Int = 0, adjustHeight: Int = 0) {
        self.family = family; self.boldFamily = boldFamily; self.italicFamily = italicFamily; self.size = size
        self.features = features; self.ligatures = ligatures; self.thicken = thicken
        self.adjustWidth = adjustWidth; self.adjustHeight = adjustHeight
    }

    var cacheKey: String {
        "\(family)|\(boldFamily)|\(italicFamily)|\(size)|\(features.joined(separator: ","))|\(ligatures)|\(thicken)|\(adjustWidth)|\(adjustHeight)"
    }
}

/// A set of pixel-sized fonts (regular, bold, italic, bold italic, plus discovered fallbacks)
/// and the derived cell metrics.
public final class FontSet {
    public let spec: FontSpec
    public let scale: CGFloat
    /// 0 regular, 1 bold, 2 italic, 3 bold italic, 4+ fallbacks.
    public private(set) var fonts: [CTFont] = [] {
        didSet { colorFlags = fonts.map { CTFontGetSymbolicTraits($0).contains(.traitColorGlyphs) } }
    }
    /// Whether each font draws color (emoji) glyphs; cached because it's queried per glyph.
    private var colorFlags: [Bool] = []
    private var fallbackIndex: [String: Int] = [:]
    private var fallbackForScalar: [UInt64: (Int, CGGlyph)] = [:]
    /// Direct glyph lookup for ASCII per style.
    private(set) var asciiGlyphs: [[CGGlyph]] = []

    public let cellWidth: Int
    public let cellHeight: Int
    /// Distance from the top of the cell to the baseline.
    public let baseline: Int
    public let underlinePosition: Int   // from top of cell
    public let underlineThickness: Int
    public let strikePosition: Int      // from top of cell
    public let ligatures: Bool
    public private(set) var familyName: String = ""
    public var fontWasFound = true

    public init(spec: FontSpec, scale: CGFloat) {
        self.spec = spec
        self.scale = scale
        self.ligatures = spec.ligatures
        let px = spec.size * scale

        var settings: [[CFString: Any]] = []
        func feature(_ tag: String, _ value: Int) {
            settings.append([kCTFontOpenTypeFeatureTag: tag as CFString, kCTFontOpenTypeFeatureValue: value])
        }
        if !spec.ligatures { feature("liga", 0); feature("calt", 0); feature("dlig", 0) }
        for f in spec.features {
            var tag = f, value = 1
            if f.hasPrefix("-") { tag = String(f.dropFirst()); value = 0 }
            else if f.hasPrefix("+") { tag = String(f.dropFirst()) }
            else if let eq = f.firstIndex(of: "=") { tag = String(f[..<eq]); value = Int(f[f.index(after: eq)...]) ?? 1 }
            if tag.count == 4 { feature(tag, value) }
        }

        func withFeatures(_ f: CTFont) -> CTFont {
            guard !settings.isEmpty else { return f }
            let d = CTFontDescriptorCreateWithAttributes([kCTFontFeatureSettingsAttribute: settings] as CFDictionary)
            return CTFontCreateCopyWithAttributes(f, px, nil, d)
        }

        func named(_ family: String) -> CTFont? {
            guard !family.isEmpty else { return nil }
            let f = CTFontCreateWithName(family as CFString, px, nil)
            let got = CTFontCopyFamilyName(f) as String
            let ps = CTFontCopyPostScriptName(f) as String
            if got.caseInsensitiveCompare(family) == .orderedSame || ps.caseInsensitiveCompare(family) == .orderedSame { return f }
            // CoreText silently substitutes; also accept full-name matches.
            let full = CTFontCopyFullName(f) as String
            return full.caseInsensitiveCompare(family) == .orderedSame ? f : nil
        }

        let base: CTFont
        if let f = named(spec.family) {
            base = f
        } else {
            fontWasFound = spec.family.isEmpty
            base = NSFont.monospacedSystemFont(ofSize: px, weight: .regular) as CTFont
        }
        familyName = CTFontCopyFamilyName(base) as String

        func variant(_ traits: CTFontSymbolicTraits, family: String) -> CTFont {
            if let f = named(family) {
                return CTFontCreateCopyWithSymbolicTraits(f, px, nil, traits, traits) ?? f
            }
            if spec.family.isEmpty {
                // System monospace: use weights for bold.
                let weight: NSFont.Weight = traits.contains(.traitBold) ? .bold : .regular
                var f = NSFont.monospacedSystemFont(ofSize: px, weight: weight) as CTFont
                if traits.contains(.traitItalic) {
                    f = CTFontCreateCopyWithSymbolicTraits(f, px, nil, .traitItalic, .traitItalic) ?? f
                }
                return f
            }
            return CTFontCreateCopyWithSymbolicTraits(base, px, nil, traits, traits) ?? base
        }

        let regular = withFeatures(base)
        let bold = withFeatures(variant(.traitBold, family: spec.boldFamily))
        let italic = withFeatures(variant(.traitItalic, family: spec.italicFamily))
        let boldItalic = withFeatures(variant([.traitBold, .traitItalic], family: spec.italicFamily))
        fonts = [regular, bold, italic, boldItalic]

        // Metrics from the regular face.
        var chars: [UniChar] = Array("M".utf16)
        var g = CGGlyph(0)
        CTFontGetGlyphsForCharacters(regular, &chars, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(regular, .horizontal, &g, &adv, 1)
        let ascent = CTFontGetAscent(regular), descent = CTFontGetDescent(regular), leading = CTFontGetLeading(regular)
        let adjW = Int((CGFloat(spec.adjustWidth) * scale).rounded())
        let adjH = Int((CGFloat(spec.adjustHeight) * scale).rounded())
        cellWidth = max(1, Int(adv.width.rounded()) + adjW)
        let naturalHeight = Int((ascent + descent + max(leading, 0)).rounded(.up))
        cellHeight = max(1, naturalHeight + adjH)
        // Center the font's box vertically in the cell.
        let extra = cellHeight - Int((ascent + descent).rounded(.up))
        baseline = Int(ascent.rounded(.up)) + extra / 2
        let ulPos = CTFontGetUnderlinePosition(regular)          // negative: below baseline
        underlineThickness = max(1, Int(CTFontGetUnderlineThickness(regular).rounded()))
        underlinePosition = min(cellHeight - underlineThickness, baseline + max(1, Int((-ulPos).rounded())))
        let xh = CTFontGetXHeight(regular)
        strikePosition = baseline - Int((xh / 2).rounded()) - underlineThickness / 2

        asciiGlyphs = fonts.map { f in
            var cs = (0..<128).map { UniChar($0) }
            var gs = [CGGlyph](repeating: 0, count: 128)
            CTFontGetGlyphsForCharacters(f, &cs, &gs, 128)
            return gs
        }
    }

    @inline(__always) public func style(bold: Bool, italic: Bool) -> Int { (bold ? 1 : 0) | (italic ? 2 : 0) }

    /// Index for a font returned by CoreText shaping (possibly a fallback).
    func index(of font: CTFont, style: Int) -> Int {
        if CFEqual(font, fonts[style]) { return style }
        let name = CTFontCopyPostScriptName(font) as String
        let key = "\(name)|\(CTFontGetSize(font))"
        if let i = fallbackIndex[key] { return i }
        fonts.append(font)
        fallbackIndex[key] = fonts.count - 1
        return fonts.count - 1
    }

    /// Glyph for a single scalar in a style, using fallback fonts as needed. Returns nil if no font has it.
    func glyph(for scalar: UInt32, style: Int) -> (font: Int, glyph: CGGlyph)? {
        if scalar < 128 {
            let g = asciiGlyphs[style][Int(scalar)]
            if g != 0 { return (style, g) }
        }
        let key = UInt64(scalar) << 8 | UInt64(style)
        if let r = fallbackForScalar[key] { return r.1 == 0 ? nil : (r.0, r.1) }
        var utf16 = Array(String(Character(Unicode.Scalar(scalar) ?? "?")).utf16)
        var gs = [CGGlyph](repeating: 0, count: utf16.count)
        let base = fonts[style]
        if CTFontGetGlyphsForCharacters(base, &utf16, &gs, utf16.count), gs[0] != 0 {
            fallbackForScalar[key] = (style, gs[0])
            return (style, gs[0])
        }
        let str = String(Character(Unicode.Scalar(scalar) ?? "?")) as CFString
        let fb = CTFontCreateForString(base, str, CFRange(location: 0, length: CFStringGetLength(str)))
        if CTFontGetGlyphsForCharacters(fb, &utf16, &gs, utf16.count), gs[0] != 0 {
            let i = index(of: fb, style: style)
            fallbackForScalar[key] = (i, gs[0])
            return (i, gs[0])
        }
        fallbackForScalar[key] = (0, 0)
        return nil
    }

    @inline(__always) func isColorFont(_ i: Int) -> Bool {
        i < colorFlags.count && colorFlags[i]
    }
}
