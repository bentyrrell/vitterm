extension Terminal {
    /// Append the text of cells [from, to) of a line. Empty cells become spaces; wide spacers are skipped.
    public func appendText(of line: Line, from: Int = 0, to: Int? = nil, into s: inout String.UnicodeScalarView) {
        let end = min(to ?? line.count, line.count)
        var x = max(0, from)
        while x < end {
            let c = line[x]
            if c.flags.contains(.wideSpacer) { x += 1; continue }
            if c.flags.contains(.grapheme) {
                for cp in graphemes.scalars(c.codepoint) { if let u = Unicode.Scalar(cp) { s.append(u) } }
            } else if c.codepoint == 0 {
                s.append(" ")
            } else if let u = Unicode.Scalar(c.codepoint) {
                s.append(u)
            }
            x += 1
        }
    }

    public func text(of line: Line, from: Int = 0, to: Int? = nil, trimRight: Bool = true) -> String {
        var v = String.UnicodeScalarView()
        let end = trimRight ? min(to ?? line.count, line.trimmedLength) : (to ?? line.count)
        appendText(of: line, from: from, to: end, into: &v)
        return String(v)
    }

    /// Every logical line (soft-wrapped rows joined) in scrollback and screen, oldest first.
    /// Trailing blanks are trimmed. Caller must hold `lock`.
    public func logicalLineTexts() -> [String] {
        let g = grid
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for i in 0..<g.count {
            let l = g.line(at: i)
            if l.wrapped {
                appendText(of: l, from: 0, to: l.wrappedContentLength(next: i + 1 < g.count ? g.line(at: i + 1) : nil), into: &cur)
            } else {
                appendText(of: l, from: 0, to: l.trimmedLength, into: &cur)
                out.append(String(cur))
                cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    /// The visible screen as text, one line per row, trailing spaces trimmed. Intended for tests.
    public func screenText() -> String {
        (0..<rows).map { text(of: grid.screenLine($0)) }.joined(separator: "\n")
    }

    /// The cell at a visible screen position.
    public func cell(x: Int, y: Int) -> Cell { grid.screenLine(y)[x] }

    /// The string (possibly a multi-scalar grapheme) held in a cell.
    public func string(for cell: Cell) -> String {
        if cell.flags.contains(.grapheme) {
            var v = String.UnicodeScalarView()
            for cp in graphemes.scalars(cell.codepoint) { if let u = Unicode.Scalar(cp) { v.append(u) } }
            return String(v)
        }
        if cell.codepoint == 0 { return " " }
        return Unicode.Scalar(cell.codepoint).map { String(Character($0)) } ?? " "
    }
}
