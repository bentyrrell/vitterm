import Foundation

/// A logical line (soft-wrapped physical lines joined) as UTF-16 text with a map back to cells.
struct LogicalLine {
    var text: String = ""
    var utf16Map: [GridPoint] = []
}

extension Terminal {
    /// Build the logical line containing logical index `i` of the current grid; returns it and the
    /// logical index of the line after it.
    func logicalLine(startingAt i: Int, in g: Grid, maxLines: Int = .max) -> (LogicalLine, Int) {
        var ll = LogicalLine()
        var scalars = String.UnicodeScalarView()
        var j = i
        while j < g.count && j - i < maxLines {
            let line = g.line(at: j)
            let abs = g.dropped + j
            let len = line.wrapped ? line.wrappedContentLength(next: j + 1 < g.count ? g.line(at: j + 1) : nil) : line.trimmedLength
            for x in 0..<len {
                let c = line[x]
                if c.flags.contains(.wideSpacer) { continue }
                let p = GridPoint(line: abs, col: x)
                let cps: [UInt32] = c.flags.contains(.grapheme) ? graphemes.scalars(c.codepoint) : [c.codepoint == 0 ? 0x20 : c.codepoint]
                for cp in cps {
                    guard let u = Unicode.Scalar(cp) else { continue }
                    scalars.append(u)
                    let n = u.value > 0xFFFF ? 2 : 1
                    for _ in 0..<n { ll.utf16Map.append(p) }
                }
            }
            j += 1
            if !line.wrapped { break }
        }
        ll.text = String(scalars)
        return (ll, j)
    }

    /// Logical index of the first physical line of the logical line containing absolute line `abs`.
    func logicalStart(ofAbsolute abs: Int, in g: Grid, maxBack: Int = .max) -> Int? {
        var l = abs - g.dropped
        guard l >= 0 && l < g.count else { return nil }
        let limit = abs - g.dropped - min(maxBack, abs - g.dropped)
        while l > limit && g.line(at: l - 1).wrapped { l -= 1 }
        return l
    }

    /// Rows above and below the pointer considered when detecting a URL.
    static let linkSearchRows = 32

    /// Find all matches in scrollback and screen. Caller must hold `lock`.
    /// Smart case: case-insensitive unless the query contains an uppercase letter.
    public func search(_ query: String, regex: Bool = false, limit: Int = 50_000) -> [SearchMatch] {
        guard !query.isEmpty else { return [] }
        let caseSensitive = query.contains { $0.isUppercase }
        let index = currentSearchIndex()
        if !regex, let q = SearchIndex.foldableASCII(query) {
            return index.findLiteralASCII(q, caseSensitive: caseSensitive, limit: limit)
        }
        let pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { options.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return index.findRegex(re, limit: limit)
    }

    /// The search index for the current content, rebuilt only when the content changed.
    func currentSearchIndex() -> SearchIndex {
        if let idx = searchIndexCache, idx.version == contentVersion, idx.alternate == usingAlternate, idx.dropped == grid.dropped {
            return idx
        }
        let idx = SearchIndex(terminal: self)
        searchIndexCache = idx
        return idx
    }

    // MARK: Links

    static let urlRegex = try! NSRegularExpression(
        pattern: #"(?:https?|ftp|file|ssh|git)://[^\s<>"'`\x{2502}]+|mailto:[^\s<>"'`]+|www\.[a-zA-Z0-9-]+\.[^\s<>"'`]+"#)

    /// The hyperlink (OSC 8) or detected URL at a point. Caller must hold `lock`.
    public func link(at p: GridPoint) -> (url: String, ranges: [(line: Int, cols: ClosedRange<Int>)])? {
        let g = grid
        guard let line = g.line(absolute: p.line), p.col < line.count else { return nil }
        let cell = line[p.col]
        if cell.extra != 0, let uri = hyperlinks.uri(extras[cell.extra].hyperlink) {
            let id = extras[cell.extra].hyperlink
            var a = p.col, b = p.col
            while a > 0 && extras[line[a - 1].extra].hyperlink == id { a -= 1 }
            while b < line.count - 1 && extras[line[b + 1].extra].hyperlink == id { b += 1 }
            return (uri, [(p.line, a...b)])
        }
        // Only rows near the pointer: a soft-wrapped "line" can span the whole scrollback (output
        // without newlines), and this runs on every mouse move while ⌘ is held.
        guard let logical = logicalStart(ofAbsolute: p.line, in: g, maxBack: Terminal.linkSearchRows) else { return nil }
        let start = max(logical, p.line - g.dropped - Terminal.linkSearchRows)
        let (ll, _) = logicalLine(startingAt: start, in: g, maxLines: 2 * Terminal.linkSearchRows + 1)
        guard let idx = ll.utf16Map.firstIndex(where: { $0.line == p.line && $0.col >= p.col }), ll.utf16Map[idx] == p || ll.utf16Map[idx].col == p.col else { return nil }
        let ns = ll.text as NSString
        for m in Terminal.urlRegex.matches(in: ll.text, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            guard r.location <= idx && idx < r.location + r.length else { continue }
            // Trim trailing punctuation that is usually not part of a URL.
            var url = ns.substring(with: r)
            while let last = url.last, ".,;:!?".contains(last) || (last == ")" && !url.contains("(")) {
                url.removeLast(); r.length -= 1
            }
            guard r.length > 0 else { return nil }
            if url.hasPrefix("www.") { url = "https://" + url }
            let s = ll.utf16Map[r.location], e = ll.utf16Map[r.location + r.length - 1]
            var ranges: [(line: Int, cols: ClosedRange<Int>)] = []
            for l in s.line...e.line {
                let a = l == s.line ? s.col : 0
                let b = l == e.line ? e.col : cols - 1
                if a <= b { ranges.append((l, a...b)) }
            }
            return (url, ranges)
        }
        return nil
    }

    // MARK: Selection helpers

    /// Expand a point to the word around it (crossing soft wraps). Caller must hold `lock`.
    public func wordBounds(at p: GridPoint, separators: String) -> (GridPoint, GridPoint) {
        let g = grid
        let seps = Set(separators.unicodeScalars.map(\.value))
        func cp(_ q: GridPoint) -> UInt32? {
            guard let l = g.line(absolute: q.line), q.col >= 0, q.col < l.count else { return nil }
            var c = l[q.col]
            if c.flags.contains(.wideSpacer) && q.col > 0 { c = l[q.col - 1] }
            if c.flags.contains(.grapheme) { return graphemes.scalars(c.codepoint).first }
            return c.codepoint == 0 ? 0x20 : c.codepoint
        }
        guard let here = cp(p) else { return (p, p) }
        let isSpace = here == 0x20
        func sameClass(_ c: UInt32) -> Bool {
            if isSpace { return c == 0x20 }
            return c != 0x20 && !seps.contains(c)
        }
        if !isSpace && seps.contains(here) { return (p, p) }
        var a = p
        while true {
            var prev = GridPoint(line: a.line, col: a.col - 1)
            if prev.col < 0 {
                guard let pl = g.line(absolute: a.line - 1), pl.wrapped else { break }
                prev = GridPoint(line: a.line - 1, col: pl.count - 1)
            }
            guard let c = cp(prev), sameClass(c) else { break }
            a = prev
        }
        var b = p
        while true {
            var next = GridPoint(line: b.line, col: b.col + 1)
            if let l = g.line(absolute: b.line), next.col >= l.count {
                guard l.wrapped else { break }
                next = GridPoint(line: b.line + 1, col: 0)
            }
            guard let c = cp(next), sameClass(c) else { break }
            b = next
        }
        return (a, b)
    }

    /// The logical-line bounds around an absolute line (for triple-click). Caller must hold `lock`.
    public func lineBounds(at line: Int) -> (GridPoint, GridPoint) {
        let g = grid
        var a = line, b = line
        while let l = g.line(absolute: a - 1), l.wrapped { a -= 1 }
        while let l = g.line(absolute: b), l.wrapped, g.line(absolute: b + 1) != nil { b += 1 }
        return (GridPoint(line: a, col: 0), GridPoint(line: b, col: cols - 1))
    }

    /// Text covered by a selection. Caller must hold `lock`.
    public func text(of sel: Selection) -> String {
        let g = grid
        let (s, e) = sel.range
        var out = String.UnicodeScalarView()
        for abs in s.line...e.line {
            guard let line = g.line(absolute: abs), let cr = sel.columns(onLine: abs, cols: line.count) else { continue }
            let last = abs == e.line
            if sel.mode == .block {
                var t = String.UnicodeScalarView()
                appendText(of: line, from: cr.lowerBound, to: cr.upperBound + 1, into: &t)
                out.append(contentsOf: String(t).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).unicodeScalars)
                if !last { out.append("\n") }
                continue
            }
            let end = line.wrapped ? min(cr.upperBound + 1, line.wrappedContentLength(next: g.line(absolute: abs + 1)))
                                   : min(cr.upperBound + 1, line.trimmedLength)
            if end > cr.lowerBound { appendText(of: line, from: cr.lowerBound, to: end, into: &out) }
            if !last && !(line.wrapped && cr.upperBound == line.count - 1) { out.append("\n") }
        }
        return String(out)
    }

    /// Absolute lines carrying OSC 133 prompt marks. Caller must hold `lock`.
    public func promptLines() -> [Int] {
        let g = grid
        var out: [Int] = []
        for i in 0..<g.count where g.line(at: i).promptMark { out.append(g.dropped + i) }
        return out
    }
}

/// All text in a grid as one UTF-16 buffer (logical lines joined, separated by "\n"), with a map
/// from each code unit back to its cell. Built once per content version so that refining a query
/// only costs the match itself.
final class SearchIndex {
    let version: UInt64
    let alternate: Bool
    let dropped: Int
    private(set) var units: [UInt16] = []
    /// Absolute line for each unit; -1 for line separators.
    private(set) var lineOf: [Int32] = []
    private(set) var colOf: [UInt16] = []

    init(terminal t: Terminal) {
        version = t.contentVersion
        alternate = t.usingAlternate
        let g = t.grid
        dropped = g.dropped
        var estimate = 0
        for i in 0..<g.count { estimate += g.line(at: i).used + 1 }
        units.reserveCapacity(estimate)
        lineOf.reserveCapacity(estimate)
        colOf.reserveCapacity(estimate)
        for i in 0..<g.count {
            let line = g.line(at: i)
            let abs = Int32(truncatingIfNeeded: g.dropped + i)
            let len = line.wrapped ? line.wrappedContentLength(next: i + 1 < g.count ? g.line(at: i + 1) : nil) : line.trimmedLength
            for x in 0..<len {
                let c = line[x]
                if c.flags.contains(.wideSpacer) { continue }
                let col = UInt16(truncatingIfNeeded: x)
                if c.flags.contains(.grapheme) {
                    for cp in t.graphemes.scalars(c.codepoint) { append(cp, abs, col) }
                } else {
                    append(c.codepoint == 0 ? 0x20 : c.codepoint, abs, col)
                }
            }
            if !line.wrapped {
                units.append(0x0A); lineOf.append(-1); colOf.append(0)
            }
        }
    }

    @inline(__always) private func append(_ cp: UInt32, _ line: Int32, _ col: UInt16) {
        if cp < 0x10000 {
            units.append(UInt16(cp)); lineOf.append(line); colOf.append(col)
        } else if cp <= 0x10FFFF {
            let v = cp - 0x10000
            units.append(UInt16(0xD800 + (v >> 10))); lineOf.append(line); colOf.append(col)
            units.append(UInt16(0xDC00 + (v & 0x3FF))); lineOf.append(line); colOf.append(col)
        }
    }

    @inline(__always) private func point(_ i: Int) -> GridPoint { GridPoint(line: Int(lineOf[i]), col: Int(colOf[i])) }

    /// The query as ASCII code units if it is plain ASCII without line breaks (fast path).
    static func foldableASCII(_ q: String) -> [UInt16]? {
        var out: [UInt16] = []
        for u in q.utf16 {
            guard u < 0x80, u != 0x0A, u != 0x0D else { return nil }
            out.append(u)
        }
        return out.isEmpty ? nil : out
    }

    @inline(__always) static func fold(_ u: UInt16) -> UInt16 { (u >= 0x41 && u <= 0x5A) ? u | 0x20 : u }

    /// Literal ASCII search directly over the code units (ASCII case folding when insensitive).
    func findLiteralASCII(_ q: [UInt16], caseSensitive: Bool, limit: Int) -> [SearchMatch] {
        var out: [SearchMatch] = []
        let n = units.count, m = q.count
        guard m <= n else { return out }
        let pat = caseSensitive ? q : q.map(SearchIndex.fold)
        units.withUnsafeBufferPointer { u in
            pat.withUnsafeBufferPointer { p in
                let first = p[0]
                let firstUpper: UInt16 = (!caseSensitive && first >= 0x61 && first <= 0x7A) ? first & ~0x20 : first
                var i = 0
                let last = n - m
                while i <= last {
                    let c = u[i]
                    if c == first || c == firstUpper {
                        var k = 1
                        if caseSensitive {
                            while k < m && u[i + k] == p[k] { k += 1 }
                        } else {
                            while k < m && SearchIndex.fold(u[i + k]) == p[k] { k += 1 }
                        }
                        if k == m {
                            // Literal ASCII queries never contain the separator, so matches stay within a line.
                            out.append(SearchMatch(start: point(i), end: point(i + m - 1)))
                            if out.count >= limit { return }
                            i += m
                            continue
                        }
                    }
                    i += 1
                }
            }
        }
        return out
    }

    /// Regex search with per-logical-line semantics, in (almost always) a single pass: the whole
    /// buffer is searched at once, and only when a match runs across a line separator (possible with
    /// patterns like `\s+x`) are the lines it touched re-searched individually, so a crossing match
    /// can never hide a legitimate one inside a line. Re-searches run after the main pass (the regex
    /// object isn't used re-entrantly) and results are merged in order.
    func findRegex(_ re: NSRegularExpression, limit: Int) -> [SearchMatch] {
        guard !units.isEmpty else { return [] }
        var found: [(start: Int, end: Int)] = []
        units.withUnsafeMutableBufferPointer { buf in
            let total = buf.count
            let ns = NSString(charactersNoCopy: buf.baseAddress!, length: total, freeWhenDone: false) as String

            func lineStart(_ i: Int) -> Int {
                var k = i
                while k > 0 && lineOf[k - 1] >= 0 { k -= 1 }
                return k
            }
            func lineEnd(_ i: Int) -> Int { // index of the separator ending the line containing i (or total)
                var k = i
                while k < total && lineOf[k] >= 0 { k += 1 }
                return k
            }

            // Main pass. A crossing match records the unit range [from, to) to re-search per line,
            // where `from` is the crossing match's start (earlier matches on that line were already
            // found by this pass) and `to` is the end of the last line it touched.
            var regions: [(from: Int, to: Int)] = []
            var resumeAt = 0
            re.enumerateMatches(in: ns, range: NSRange(location: 0, length: total)) { m, _, stop in
                guard let r = m?.range, r.length > 0 else { return }
                let a = r.location, b = r.location + r.length - 1
                if a < resumeAt {
                    // Inside a region that will be re-searched; if this match runs past it, the
                    // region must grow to cover the lines it reaches (the scan is misaligned there).
                    if b >= resumeAt, !regions.isEmpty {
                        let to = lineEnd(b)
                        regions[regions.count - 1].to = to
                        resumeAt = to
                    }
                    return
                }
                var crosses = false
                for k in a...b where lineOf[k] < 0 { crosses = true; break }
                if crosses {
                    let from = lineOf[a] < 0 ? a + 1 : a
                    let to = lineEnd(b)
                    regions.append((from, to))
                    resumeAt = to
                } else {
                    found.append((a, b))
                    if found.count >= limit && regions.isEmpty { stop.pointee = true }
                }
            }

            // Re-search the touched lines one at a time.
            for (from, to) in regions {
                var ls = lineStart(from)
                var first = true
                while ls < to {
                    let le = lineEnd(ls)
                    if le > ls {
                        for lm in re.matches(in: ns, options: [], range: NSRange(location: ls, length: le - ls)) where lm.range.length > 0 {
                            if first && lm.range.location < from { continue }
                            found.append((lm.range.location, lm.range.location + lm.range.length - 1))
                        }
                    }
                    first = false
                    ls = le + 1
                }
            }
        }
        if !found.isEmpty { found.sort { $0.start < $1.start } }
        return found.prefix(limit).map { SearchMatch(start: point($0.start), end: point($0.end)) }
    }
}
