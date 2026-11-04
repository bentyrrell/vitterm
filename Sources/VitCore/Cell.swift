/// A terminal color, packed into 32 bits.
///
/// The top byte is a tag: 0 = default, 1 = palette index (low byte), 2 = 24-bit RGB (low 3 bytes).
public struct TermColor: Equatable, Hashable, Sendable {
    public var raw: UInt32

    @inlinable public init(raw: UInt32) { self.raw = raw }

    public static let `default` = TermColor(raw: 0)
    @inlinable public static func palette(_ i: UInt8) -> TermColor { TermColor(raw: 0x0100_0000 | UInt32(i)) }
    @inlinable public static func rgb(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> TermColor {
        TermColor(raw: 0x0200_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b))
    }

    @inlinable public var isDefault: Bool { raw == 0 }
    @inlinable public var tag: UInt32 { raw >> 24 }
    @inlinable public var paletteIndex: UInt8 { UInt8(truncatingIfNeeded: raw) }
    /// RGB packed as 0x00RRGGBB (only meaningful when tag == 2).
    @inlinable public var rgb: UInt32 { raw & 0x00FF_FFFF }
}

public enum UnderlineStyle: UInt16, Sendable {
    case none = 0, single, double, curly, dotted, dashed
}

/// Cell attribute bit flags.
public struct CellFlags: OptionSet, Hashable, Sendable {
    public var rawValue: UInt16
    @inlinable public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = CellFlags(rawValue: 1 << 0)
    public static let italic        = CellFlags(rawValue: 1 << 1)
    public static let faint         = CellFlags(rawValue: 1 << 2)
    public static let inverse       = CellFlags(rawValue: 1 << 3)
    public static let invisible     = CellFlags(rawValue: 1 << 4)
    public static let strikethrough = CellFlags(rawValue: 1 << 5)
    public static let blink         = CellFlags(rawValue: 1 << 6)
    /// First half of a double-width character.
    public static let wide          = CellFlags(rawValue: 1 << 7)
    /// Second (placeholder) half of a double-width character.
    public static let wideSpacer    = CellFlags(rawValue: 1 << 8)
    public static let overline      = CellFlags(rawValue: 1 << 9)
    /// `codepoint` is an index into the terminal's grapheme table rather than a scalar.
    public static let grapheme      = CellFlags(rawValue: 1 << 10)
    /// Protected from selective erase (DECSCA).
    public static let protected     = CellFlags(rawValue: 1 << 11)
    // Bits 13-15: underline style.
    static let underlineShift: UInt16 = 13
    static let underlineMask: UInt16 = 0b111 << 13

    /// Flags that affect how a cell is drawn (everything except layout bookkeeping).
    public static let styleMask = CellFlags(rawValue: ~(CellFlags.wide.rawValue | CellFlags.wideSpacer.rawValue | CellFlags.grapheme.rawValue))

    @inlinable public var underline: UnderlineStyle {
        get { UnderlineStyle(rawValue: (rawValue & 0xE000) >> 13) ?? .none }
        set { rawValue = (rawValue & ~0xE000) | (newValue.rawValue << 13) }
    }
}

/// One grid cell: 16 bytes, trivially copyable.
public struct Cell: Equatable, Sendable {
    /// Unicode scalar, 0 for an empty cell, or a grapheme-table index when `.grapheme` is set.
    public var codepoint: UInt32
    public var fg: TermColor
    public var bg: TermColor
    public var flags: CellFlags
    /// Index into the terminal's extras table (hyperlink / underline color); 0 = none.
    public var extra: UInt16

    @inlinable public init(codepoint: UInt32 = 0, fg: TermColor = .default, bg: TermColor = .default,
                           flags: CellFlags = [], extra: UInt16 = 0) {
        self.codepoint = codepoint
        self.fg = fg
        self.bg = bg
        self.flags = flags
        self.extra = extra
    }

    public static let empty = Cell()

    @inlinable public var isEmpty: Bool { codepoint == 0 && !flags.contains(.grapheme) }

    /// A blank cell that keeps the given background (used by erase operations, per ECMA-48 BCE).
    @inlinable public static func blank(bg: TermColor) -> Cell { Cell(bg: bg) }
}

/// The pen used for newly written cells.
public struct Pen: Equatable, Sendable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var flags: CellFlags = []
    public var underlineColor: TermColor = .default
    public var hyperlink: UInt32 = 0
    public var extra: UInt16 = 0
    public init() {}
}
