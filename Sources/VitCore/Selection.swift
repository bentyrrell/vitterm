/// A position in the terminal's absolute line space (see `Grid.absolute(screenRow:)`).
public struct GridPoint: Comparable, Hashable, Sendable {
    public var line: Int
    public var col: Int
    public init(line: Int, col: Int) { self.line = line; self.col = col }
    public static func < (a: GridPoint, b: GridPoint) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

public struct Selection: Equatable, Sendable {
    public enum Mode: Sendable { case character, word, line, block }
    public var anchor: GridPoint
    public var head: GridPoint
    public var mode: Mode
    /// True when the selection was made on the alternate screen.
    public var onAlternate: Bool

    public init(anchor: GridPoint, head: GridPoint, mode: Mode, onAlternate: Bool) {
        self.anchor = anchor; self.head = head; self.mode = mode; self.onAlternate = onAlternate
    }

    /// Ordered (start, end), both inclusive.
    public var range: (GridPoint, GridPoint) { anchor <= head ? (anchor, head) : (head, anchor) }

    public var isEmpty: Bool { anchor == head && mode == .character }

    @inlinable public func contains(line: Int, col: Int) -> Bool {
        let (s, e) = range
        if mode == .block {
            let c0 = min(anchor.col, head.col), c1 = max(anchor.col, head.col)
            return line >= s.line && line <= e.line && col >= c0 && col <= c1
        }
        if line < s.line || line > e.line { return false }
        if line == s.line && col < s.col { return false }
        if line == e.line && col > e.col { return false }
        return true
    }

    /// Column range selected on `line` (inclusive), or nil.
    public func columns(onLine line: Int, cols: Int) -> ClosedRange<Int>? {
        let (s, e) = range
        guard line >= s.line && line <= e.line else { return nil }
        if mode == .block { return min(anchor.col, head.col)...min(max(anchor.col, head.col), cols - 1) }
        let a = line == s.line ? s.col : 0
        let b = line == e.line ? e.col : cols - 1
        return a <= b ? a...min(b, cols - 1) : nil
    }
}

/// A search hit spanning possibly several lines (for soft-wrapped text).
public struct SearchMatch: Equatable, Sendable {
    public var start: GridPoint
    public var end: GridPoint   // inclusive
    public init(start: GridPoint, end: GridPoint) { self.start = start; self.end = end }
}
