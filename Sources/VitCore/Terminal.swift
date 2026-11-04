import Foundation

public enum Charset: Sendable { case ascii, decSpecial, uk }

public struct TerminalModes: Sendable {
    public var cursorKeysApp = false          // DECCKM
    public var keypadApp = false              // DECKPAM
    public var originMode = false             // DECOM
    public var autowrap = true                // DECAWM
    public var cursorVisible = true           // DECTCEM
    public var insertMode = false             // IRM
    public var newlineMode = false            // LNM
    public var reverseVideo = false           // DECSCNM
    public var cursorBlink: Bool? = nil       // mode 12 (nil = user default)
    public var bracketedPaste = false         // 2004
    public var focusEvents = false            // 1004
    public var alternateScroll = true         // 1007
    public var synchronizedOutput = false     // 2026
    public var graphemeClustering = false     // 2027
    public var colorSchemeUpdates = false     // 2031
    public var mouseTracking: MouseTracking = .none
    public var mouseEncoding: MouseEncoding = .x10
    public init() {}
}

public struct SavedCursor {
    var x = 0, y = 0
    var pen = Pen()
    var pendingWrap = false
    var originMode = false
    var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    var gl = 0
}

public final class Terminal: ParserHandler {
    // MARK: Public state (read under `lock`)

    public let lock = UnfairLock()
    public private(set) var cols: Int
    public private(set) var rows: Int
    public let primary: Grid
    public let alternate: Grid
    public private(set) var usingAlternate = false
    @inlinable public var grid: Grid { usingAlternate ? alternate : primary }

    public var cursorX = 0
    public var cursorY = 0
    public var pen = Pen()
    public var pendingWrap = false
    public var modes = TerminalModes()

    public internal(set) var scrollTop = 0
    public internal(set) var scrollBottom: Int

    public var title = ""
    public var workingDirectory: String?
    public var cursorShape: CursorShape? = nil   // nil = user default
    public var cursorShapeBlinks: Bool? = nil

    /// Lines scrolled up from the bottom of the primary screen (viewport position).
    public var scrollOffset = 0

    /// Set whenever visible content may have changed; cleared by the renderer.
    public var dirty = true
    /// Monotonic counter of content mutations (for caches like search results).
    public private(set) var contentVersion: UInt64 = 0

    // Colors (0x00RRGGBB).
    public var palette: [UInt32]
    public var basePalette: [UInt32]
    public var defaultForeground: UInt32
    public var defaultBackground: UInt32
    public var cursorColor: UInt32?
    public var baseForeground: UInt32
    public var baseBackground: UInt32
    public var baseCursorColor: UInt32?
    public var isDarkBackground: Bool {
        let r = Double(defaultBackground >> 16 & 0xFF), g = Double(defaultBackground >> 8 & 0xFF), b = Double(defaultBackground & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128
    }

    public let graphemes = GraphemeTable()
    public let extras = ExtrasTable()
    public let hyperlinks = HyperlinkTable()
    public let images = ImageStore()
    /// Cached search index (see `SearchIndex`), invalidated by content changes.
    var searchIndexCache: SearchIndex?

    /// Kitty keyboard protocol flag stacks for the primary/alternate screens.
    var kittyStackPrimary: [UInt8] = []
    var kittyStackAlternate: [UInt8] = []
    public var kittyKeyboardFlags: UInt8 { (usingAlternate ? kittyStackAlternate : kittyStackPrimary).last ?? 0 }

    /// Bytes to write back to the PTY (query responses). Drained by the IO layer.
    public var pendingOutput: [UInt8] = []
    /// Events for the UI. Drained on the main thread.
    public var pendingEvents: [TerminalEvent] = []

    /// Cell size in pixels, for XTWINOPS reports and image placement. Set by the view.
    public var cellPixelWidth = 8
    public var cellPixelHeight = 16
    /// Whether OSC 52 reads are allowed.
    public var allowClipboardRead = false
    /// Whether the Kitty graphics protocol may read image files from disk (`t=f` / `t=t`). Any
    /// program's output (including a remote host's) can ask for this.
    public var allowImageFiles = true
    /// Time spent decoding images (Kitty / iTerm2), in nanoseconds, since the caller last reset it.
    /// Decoding happens while the terminal lock is held; the PTY reader uses this to back off.
    public var imageWorkNanos: UInt64 = 0

    // MARK: Private state

    let parser = Parser()
    var tabStops: [Bool]
    var charsets: [Charset] = [.ascii, .ascii, .ascii, .ascii]
    var gl = 0
    var singleShift: Int? = nil
    var savedCursorPrimary = SavedCursor()
    var savedCursorAlternate = SavedCursor()
    var savedPrivateModes: [Int: Bool] = [:]
    var titleStack: [String] = []

    /// Position of the last printed cell, for attaching combining characters.
    var lastPrintValid = false
    var lastPrintX = 0
    var lastPrintY = 0
    var lastPrintJoiner = false        // last scalar was ZWJ (grapheme mode)
    var lastPrintRegional = false      // last cell is a lone regional indicator (grapheme mode)
    var lastPrintedScalar: UInt32 = 0  // for REP

    public init(cols: Int, rows: Int, scrollback: Int = 10_000) {
        let cols = max(cols, 2), rows = max(rows, 1)
        self.cols = cols
        self.rows = rows
        primary = Grid(cols: cols, rows: rows, maxScrollback: scrollback)
        alternate = Grid(cols: cols, rows: rows, maxScrollback: 0)
        scrollBottom = rows - 1
        tabStops = Terminal.defaultTabStops(cols)
        palette = Terminal.xtermPalette
        basePalette = Terminal.xtermPalette
        defaultForeground = 0xD0D0D0
        defaultBackground = 0x101010
        baseForeground = defaultForeground
        baseBackground = defaultBackground
    }

    static func defaultTabStops(_ cols: Int) -> [Bool] {
        (0..<cols).map { $0 % 8 == 0 && $0 != 0 }
    }

    /// The standard xterm 256-color palette.
    public static let xtermPalette: [UInt32] = {
        var p: [UInt32] = [
            0x000000, 0xCD0000, 0x00CD00, 0xCDCD00, 0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
            0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00, 0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
        ]
        let levels: [UInt32] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            p.append(levels[r] << 16 | levels[g] << 8 | levels[b])
        } } }
        for i in 0..<24 { let v = UInt32(8 + 10 * i); p.append(v << 16 | v << 8 | v) }
        return p
    }()

    /// Apply a theme's colors (16 ANSI colors plus defaults). Resets runtime overrides.
    public func applyColors(ansi: [UInt32], foreground: UInt32, background: UInt32, cursor: UInt32?) {
        var p = Terminal.xtermPalette
        for (i, c) in ansi.prefix(16).enumerated() { p[i] = c }
        basePalette = p
        palette = p
        baseForeground = foreground
        baseBackground = background
        baseCursorColor = cursor
        defaultForeground = foreground
        defaultBackground = background
        cursorColor = cursor
        dirty = true
    }

    // MARK: Feeding

    /// Parse PTY output. Caller must hold `lock`.
    public func feed(_ data: UnsafeBufferPointer<UInt8>) {
        parser.parse(data, handler: self)
        if !images.isEmpty { images.prune(primaryFirstLine: primary.dropped) }
        dirty = true
        contentVersion &+= 1
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ s: String) { feed(Array(s.utf8)) }

    // MARK: Cell helpers

    @inline(__always) var currentLine: Line { grid.screenLine(cursorY) }

    @inline(__always) func blank() -> Cell { Cell.blank(bg: pen.bg) }

    @inline(__always) func penCell(_ cp: UInt32) -> Cell {
        Cell(codepoint: cp, fg: pen.fg, bg: pen.bg, flags: pen.flags, extra: pen.extra)
    }

    func updatePenExtra() {
        pen.extra = extras.intern(CellExtra(underlineColor: pen.underlineColor, hyperlink: pen.hyperlink))
    }

    /// Before overwriting cells [x, x+n) on a line, break any wide characters straddling the edges.
    @inline(__always) func splitWide(_ line: Line, _ x: Int, _ n: Int) {
        if x > 0 && x < line.count && line[x].flags.contains(.wideSpacer) {
            line[x - 1] = Cell.blank(bg: line[x - 1].bg)
        }
        let last = x + n - 1
        if last >= 0 && last < line.count - 1 && line[last].flags.contains(.wide) {
            line[last + 1] = Cell.blank(bg: line[last + 1].bg)
        }
    }

    // MARK: Printing

    public func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) {
        let cs = singleShift.map { charsets[$0] } ?? charsets[gl]
        if cs != .ascii || modes.insertMode {
            for b in bytes { printScalar(UInt32(b)) }
            return
        }
        guard let base = bytes.baseAddress else { return }
        let n = bytes.count
        var p = 0
        let template = penCell(0)
        while p < n {
            if pendingWrap {
                if modes.autowrap { wrapToNextLine() } else { pendingWrap = false }
            }
            // Borrowed (no retain/release): the grid owns the line for the duration of this chunk.
            unowned(unsafe) let line = currentLine
            let k = min(cols - cursorX, n - p)
            splitWide(line, cursorX, k)
            let dst = line.beginWrite(at: cursorX, count: k)
            for j in 0..<k {
                var c = template
                c.codepoint = UInt32(base[p + j])
                dst[j] = c
            }
            line.generation &+= 1
            lastPrintValid = true
            lastPrintX = cursorX + k - 1
            lastPrintY = cursorY
            lastPrintJoiner = false
            lastPrintRegional = false
            lastPrintedScalar = UInt32(base[p + k - 1])
            cursorX += k
            p += k
            if cursorX >= cols {
                cursorX = cols - 1
                pendingWrap = modes.autowrap
            }
        }
    }

    /// Test hook: route printScalars through the per-scalar path (for differential testing).
    nonisolated(unsafe) public static var batchedPrintEnabled = true

    /// Print a run of scalars. Equivalent to calling `printScalar` for each, but writes runs of
    /// ordinary narrow/wide characters straight into the line, fetching it once per row.
    public func printScalars(_ scalars: UnsafeBufferPointer<UInt32>) {
        let n = scalars.count
        // Modes that need per-scalar logic for everything.
        if !Terminal.batchedPrintEnabled || modes.insertMode || singleShift != nil || charsets[gl] != .ascii {
            for cp in scalars { printScalar(cp) }
            return
        }
        let template = penCell(0)
        var spacerTemplate = template
        spacerTemplate.flags.insert(.wideSpacer)
        let grapheme = modes.graphemeClustering
        var i = 0
        while i < n {
            let cp0 = scalars[i]
            let w0 = CharWidth.of(cp0)
            // Zero-width marks, joiners and grapheme-mode clustering go through the full path.
            if w0 == 0 || (grapheme && (lastPrintJoiner || CharWidth.isEmojiModifier(cp0) || CharWidth.isRegionalIndicator(cp0))) {
                printScalar(cp0)
                i += 1
                continue
            }
            if pendingWrap {
                if modes.autowrap { wrapToNextLine() } else { pendingWrap = false }
            }
            if w0 == 2 && cursorX == cols - 1 {
                // A wide char that doesn't fit: the full path leaves the filler and wraps (or drops it).
                printScalar(cp0)
                i += 1
                continue
            }

            // Write as much as fits on this row in one go.
            unowned(unsafe) let line = currentLine
            let start = cursorX
            if start > 0 && line[start].flags.contains(.wideSpacer) {
                line[start - 1] = Cell.blank(bg: line[start - 1].bg)   // splitting a wide char
            }
            let cells = line.beginWrite(at: start, count: 0) - start
            var x = start
            var lastX = start
            var lastCP = cp0
            while i < n {
                let cp = scalars[i]
                let w = cp < 0x300 ? 1 : CharWidth.slow(cp)
                if w == 0 || x + w > cols { break }
                if grapheme && (CharWidth.isEmojiModifier(cp) || CharWidth.isRegionalIndicator(cp)) { break }
                var c = template
                c.codepoint = cp
                if w == 2 {
                    c.flags.insert(.wide)
                    cells[x] = c
                    cells[x + 1] = spacerTemplate
                } else {
                    cells[x] = c
                }
                lastX = x
                lastCP = cp
                x += w
                i += 1
                if x >= cols { break }
            }
            line.commitWrite(upTo: x)
            // The cell after the written range may be the orphaned half of a wide char we overwrote.
            if x < cols && line[x].flags.contains(.wideSpacer) {
                line[x] = Cell.blank(bg: line[x].bg)
            }
            line.generation &+= 1
            lastPrintValid = true
            lastPrintX = lastX
            lastPrintY = cursorY
            lastPrintJoiner = false
            lastPrintRegional = false
            lastPrintedScalar = lastCP
            cursorX = x
            if cursorX >= cols {
                cursorX = cols - 1
                pendingWrap = modes.autowrap
            }
        }
    }

    public func printScalar(_ scalar: UInt32) {
        var cp = scalar
        if cp < 0x80 {
            let cs = singleShift.map { charsets[$0] } ?? charsets[gl]
            singleShift = nil
            switch cs {
            case .ascii: break
            case .decSpecial:
                if cp >= 0x5F && cp <= 0x7E { cp = Terminal.decSpecial[Int(cp - 0x5F)] }
            case .uk:
                if cp == 0x23 { cp = 0xA3 }
            }
        }

        let width = CharWidth.of(cp)

        if modes.graphemeClustering && lastPrintValid {
            if lastPrintJoiner || CharWidth.isEmojiModifier(cp) || (lastPrintRegional && CharWidth.isRegionalIndicator(cp)) {
                attachToPrevious(cp)
                lastPrintJoiner = cp == 0x200D
                lastPrintRegional = false
                return
            }
        }
        if width == 0 {
            if lastPrintValid {
                attachToPrevious(cp)
                if cp == 0x200D { lastPrintJoiner = modes.graphemeClustering }
            }
            return
        }
        writeCell(cp, width: width)
        lastPrintRegional = modes.graphemeClustering && CharWidth.isRegionalIndicator(cp)
    }

    func writeCell(_ cp: UInt32, width: Int) {
        if pendingWrap {
            if modes.autowrap { wrapToNextLine() } else { pendingWrap = false }
        }
        if width == 2 && cursorX == cols - 1 {
            if modes.autowrap {
                let l = currentLine
                splitWide(l, cursorX, 1)
                l[cursorX] = blank()
                wrapToNextLine()
            } else {
                return
            }
        }
        unowned(unsafe) let line = currentLine
        if modes.insertMode { insertBlankCells(width) }
        splitWide(line, cursorX, width)
        var c = penCell(cp)
        if width == 2 {
            c.flags.insert(.wide)
            line[cursorX] = c
            var spacer = penCell(0)
            spacer.flags.insert(.wideSpacer)
            line[cursorX + 1] = spacer
        } else {
            line[cursorX] = c
        }
        line.generation &+= 1
        lastPrintValid = true
        lastPrintX = cursorX
        lastPrintY = cursorY
        lastPrintJoiner = false
        lastPrintedScalar = cp
        cursorX += width
        if cursorX >= cols {
            cursorX = cols - 1
            pendingWrap = modes.autowrap
        }
    }

    func attachToPrevious(_ cp: UInt32) {
        guard lastPrintY < rows, lastPrintX < cols else { return }
        let line = grid.screenLine(lastPrintY)
        var cell = line[lastPrintX]
        if cell.flags.contains(.wideSpacer) && lastPrintX > 0 {
            lastPrintX -= 1
            cell = line[lastPrintX]
        }
        guard let id = graphemes.extend(cell.flags.contains(.grapheme) ? cell.codepoint : nil,
                                        base: cell.codepoint == 0 ? 0x20 : cell.codepoint, with: cp) else { return }
        cell.codepoint = id
        cell.flags.insert(.grapheme)

        // In grapheme mode, VS16 turns a narrow emoji-capable base into a wide one.
        if modes.graphemeClustering && cp == 0xFE0F && !cell.flags.contains(.wide) && lastPrintX + 1 < cols {
            cell.flags.insert(.wide)
            line[lastPrintX] = cell
            var spacer = Cell(bg: cell.bg, flags: [.wideSpacer])
            spacer.fg = cell.fg
            splitWide(line, lastPrintX + 1, 1)
            line[lastPrintX + 1] = spacer
            if cursorY == lastPrintY && cursorX == lastPrintX + 1 {
                cursorX += 1
                if cursorX >= cols { cursorX = cols - 1; pendingWrap = modes.autowrap }
            }
        } else {
            line[lastPrintX] = cell
        }
        line.generation &+= 1
    }

    func wrapToNextLine() {
        currentLine.wrapped = true
        cursorX = 0
        pendingWrap = false
        index()
    }

    static let decSpecial: [UInt32] = [
        0x00A0, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, 0x00B1, 0x2424, 0x240B, 0x2518,
        0x2510, 0x250C, 0x2514, 0x253C, 0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534,
        0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7,
    ]

    // MARK: Cursor movement & scrolling primitives

    /// Move down one line, scrolling the region if at its bottom (IND).
    public func index() {
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
    }

    /// Move up one line, scrolling the region down if at its top (RI).
    func reverseIndex() {
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
    }

    func scrollUp(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        let toScrollback = !usingAlternate && scrollTop == 0
        let before = primary.scrollbackCount
        unowned(unsafe) let g = grid
        for _ in 0..<n {
            g.scrollUp(top: scrollTop, bottom: scrollBottom, bg: pen.bg, toScrollback: toScrollback)
        }
        if toScrollback && scrollOffset > 0 {
            // Keep the viewport anchored on the same content while output streams in.
            let added = primary.scrollbackCount - before
            let evicted = n - added
            scrollOffset = min(scrollOffset + added, primary.scrollbackCount)
            if evicted > 0 && scrollOffset == primary.scrollbackCount { /* pinned at top */ }
        }
        lastPrintY -= n
        if lastPrintY < 0 { lastPrintValid = false }
    }

    func scrollDown(_ n: Int) {
        let n = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<n { grid.scrollDown(top: scrollTop, bottom: scrollBottom, bg: pen.bg) }
        lastPrintValid = false
    }

    /// Cursor positioning honoring origin mode. Coordinates are 0-based.
    func setCursor(x: Int, y: Int) {
        pendingWrap = false
        if modes.originMode {
            cursorY = min(max(scrollTop + y, scrollTop), scrollBottom)
        } else {
            cursorY = min(max(y, 0), rows - 1)
        }
        cursorX = min(max(x, 0), cols - 1)
    }

    func insertBlankCells(_ n: Int) {
        let line = currentLine
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        // Inserting at the second half of a wide character splits it: blank both halves.
        if cursorX > 0 && line[cursorX].flags.contains(.wideSpacer) {
            line[cursorX - 1] = blank()
            line[cursorX] = blank()
        }
        let move = cols - cursorX - n
        if move > 0 {
            line.materialize()
            (line.cells + cursorX + n).update(from: line.cells + cursorX, count: move)
        }
        line.fill(blank(), from: cursorX, to: cursorX + n)
        // A wide char pushed to the last column loses its spacer (it fell off the edge).
        if line[cols - 1].flags.contains(.wide) { line[cols - 1] = blank() }
    }

    func deleteCells(_ n: Int) {
        let line = currentLine
        let n = min(n, cols - cursorX)
        guard n > 0 else { return }
        splitWide(line, cursorX, n)
        let move = cols - cursorX - n
        if move > 0 {
            line.materialize()
            (line.cells + cursorX).update(from: line.cells + cursorX + n, count: move)
        }
        line.fill(blank(), from: cols - n, to: cols)
        if line[cursorX].flags.contains(.wideSpacer) { line[cursorX] = blank() }
    }

    func eraseCells(from: Int, to: Int, line: Line) {
        splitWide(line, from, to - from)
        line.fill(blank(), from: from, to: to)
        line.wrapped = false
    }

    func insertLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n { grid.scrollDown(top: cursorY, bottom: scrollBottom, bg: pen.bg) }
        cursorX = 0
        pendingWrap = false
    }

    func deleteLines(_ n: Int) {
        guard cursorY >= scrollTop && cursorY <= scrollBottom else { return }
        let n = min(n, scrollBottom - cursorY + 1)
        for _ in 0..<n { grid.scrollUp(top: cursorY, bottom: scrollBottom, bg: pen.bg, toScrollback: false) }
        cursorX = 0
        pendingWrap = false
    }

    func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseCells(from: cursorX, to: cols, line: currentLine)
            for y in (cursorY + 1)..<max(rows, cursorY + 1) { grid.screenLine(y).clear(bg: pen.bg) }
        case 1:
            for y in 0..<cursorY { grid.screenLine(y).clear(bg: pen.bg) }
            eraseCells(from: 0, to: cursorX + 1, line: currentLine)
        case 2:
            // When the screen has content, xterm-like terminals (and users) prefer scrolling it into
            // scrollback over destroying it (matches `clear` behavior in most modern terminals).
            if !usingAlternate && pen.bg.isDefault {
                var last = -1
                for y in 0..<rows where grid.screenLine(y).trimmedLength > 0 { last = y }
                if last >= 0 {
                    let save = (scrollTop, scrollBottom)
                    scrollTop = 0; scrollBottom = rows - 1
                    let savedOffset = scrollOffset
                    scrollUp(last + 1)
                    scrollOffset = savedOffset
                    (scrollTop, scrollBottom) = save
                }
            }
            for y in 0..<rows { grid.screenLine(y).clear(bg: pen.bg) }
        case 3:
            if !usingAlternate {
                primary.clearScrollback()
                scrollOffset = 0
            }
        default: break
        }
        lastPrintValid = false
    }

    func eraseLine(_ mode: Int) {
        let line = currentLine
        switch mode {
        case 0: eraseCells(from: cursorX, to: cols, line: line)
        case 1: eraseCells(from: 0, to: cursorX + 1, line: line)
        case 2: eraseCells(from: 0, to: cols, line: line)
        default: break
        }
    }

    // MARK: Screen switching

    func saveCursor() {
        let s = SavedCursor(x: cursorX, y: cursorY, pen: pen, pendingWrap: pendingWrap,
                            originMode: modes.originMode, charsets: charsets, gl: gl)
        if usingAlternate { savedCursorAlternate = s } else { savedCursorPrimary = s }
    }

    func restoreCursor() {
        let s = usingAlternate ? savedCursorAlternate : savedCursorPrimary
        cursorX = min(s.x, cols - 1)
        cursorY = min(s.y, rows - 1)
        pen = s.pen
        pendingWrap = s.pendingWrap
        modes.originMode = s.originMode
        charsets = s.charsets
        gl = s.gl
    }

    func enterAlternate(clear: Bool) {
        guard !usingAlternate else {
            if clear { for y in 0..<rows { alternate.screenLine(y).clear() } }
            return
        }
        usingAlternate = true
        scrollOffset = 0
        if clear { for y in 0..<rows { alternate.screenLine(y).clear() } }
        lastPrintValid = false
    }

    func exitAlternate() {
        guard usingAlternate else { return }
        usingAlternate = false
        lastPrintValid = false
    }

    // MARK: Resize & reset

    /// Resize the terminal. Caller must hold `lock`.
    public func resize(cols newCols: Int, rows newRows: Int) {
        let newCols = max(newCols, 2), newRows = max(newRows, 1)
        guard newCols != cols || newRows != rows else { return }

        if usingAlternate {
            // Reflow the primary screen around the saved cursor; the alt screen is simply resized.
            let c = primary.resizeReflow(cols: newCols, rows: newRows, cursor: (savedCursorPrimary.x, savedCursorPrimary.y))
            savedCursorPrimary.x = min(c.x, newCols - 1)
            savedCursorPrimary.y = c.y
            alternate.resizeSimple(cols: newCols, rows: newRows)
            cursorX = min(cursorX, newCols - 1)
            cursorY = min(cursorY, newRows - 1)
        } else {
            let c = primary.resizeReflow(cols: newCols, rows: newRows, cursor: (cursorX + (pendingWrap ? 1 : 0), cursorY))
            cursorX = min(c.x, newCols - 1)
            cursorY = c.y
            alternate.resizeSimple(cols: newCols, rows: newRows)
            pendingWrap = c.x >= newCols && modes.autowrap
        }
        cols = newCols
        rows = newRows
        scrollTop = 0
        scrollBottom = newRows - 1
        if usingAlternate { pendingWrap = false }
        lastPrintValid = false
        scrollOffset = min(scrollOffset, primary.scrollbackCount)
        let oldStops = tabStops
        tabStops = Terminal.defaultTabStops(newCols)
        for i in 0..<min(oldStops.count, newCols) { tabStops[i] = oldStops[i] }
        // Saved cursors must stay inside the new grid (they're used by later reflows and restores).
        savedCursorPrimary.x = min(savedCursorPrimary.x, newCols - 1)
        savedCursorPrimary.y = min(savedCursorPrimary.y, newRows - 1)
        savedCursorAlternate.x = min(savedCursorAlternate.x, newCols - 1)
        savedCursorAlternate.y = min(savedCursorAlternate.y, newRows - 1)
        images.clampPlacements(rows: newRows)
        dirty = true
        contentVersion &+= 1
    }

    /// Full reset (RIS).
    public func reset() {
        exitAlternate()
        for y in 0..<rows { primary.screenLine(y).clear() }
        primary.clearScrollback()
        cursorX = 0; cursorY = 0
        pen = Pen()
        pendingWrap = false
        modes = TerminalModes()
        scrollTop = 0; scrollBottom = rows - 1
        tabStops = Terminal.defaultTabStops(cols)
        charsets = [.ascii, .ascii, .ascii, .ascii]
        gl = 0
        savedCursorPrimary = SavedCursor()
        savedCursorAlternate = SavedCursor()
        kittyStackPrimary = []
        kittyStackAlternate = []
        palette = basePalette
        defaultForeground = baseForeground
        defaultBackground = baseBackground
        cursorColor = baseCursorColor
        cursorShape = nil
        cursorShapeBlinks = nil
        scrollOffset = 0
        lastPrintValid = false
        images.removeAll()
        pendingEvents.append(.colorsChanged)
        pendingEvents.append(.cursorShapeChanged)
    }

    /// Soft reset (DECSTR).
    func softReset() {
        modes.cursorVisible = true
        modes.insertMode = false
        modes.originMode = false
        modes.autowrap = true
        modes.cursorKeysApp = false
        modes.keypadApp = false
        scrollTop = 0; scrollBottom = rows - 1
        pen = Pen()
        charsets = [.ascii, .ascii, .ascii, .ascii]
        gl = 0
        savedCursorPrimary = SavedCursor()
        savedCursorAlternate = SavedCursor()
        pendingWrap = false
    }

    // MARK: C0 controls

    public func execute(_ byte: UInt8) {
        switch byte {
        case 0x07:
            pendingEvents.append(.bell)
        case 0x08:
            if pendingWrap { pendingWrap = false } else if cursorX > 0 { cursorX -= 1 }
        case 0x09:
            tab(forward: 1)
        case 0x0A, 0x0B, 0x0C:
            index()
            if modes.newlineMode { cursorX = 0 }
            pendingWrap = false
        case 0x0D:
            cursorX = 0
            pendingWrap = false
        case 0x0E: gl = 1
        case 0x0F: gl = 0
        default: break
        }
        if byte != 0x07 && byte != 0x0E && byte != 0x0F { lastPrintValid = false }
    }

    func tab(forward n: Int) {
        var n = n
        while n > 0 && cursorX < cols - 1 {
            cursorX += 1
            while cursorX < cols - 1 && !tabStops[cursorX] { cursorX += 1 }
            n -= 1
        }
        pendingWrap = false
    }

    func tab(backward n: Int) {
        var n = n
        while n > 0 && cursorX > 0 {
            cursorX -= 1
            while cursorX > 0 && !tabStops[cursorX] { cursorX -= 1 }
            n -= 1
        }
        pendingWrap = false
    }

    // MARK: ESC sequences

    public func escDispatch(intermediates: UInt16, final: UInt8) {
        lastPrintValid = false
        let i0 = UInt8(truncatingIfNeeded: intermediates)
        if i0 != 0 {
            switch i0 {
            case 0x28, 0x29, 0x2A, 0x2B: // ( ) * +  designate G0-G3
                let slot = Int(i0 - 0x28)
                switch final {
                case 0x30: charsets[slot] = .decSpecial
                case 0x41: charsets[slot] = .uk
                default: charsets[slot] = .ascii
                }
            case 0x23: // #
                if final == 0x38 { // DECALN
                    var e = Cell(codepoint: 0x45)
                    e.fg = .default
                    for y in 0..<rows { grid.screenLine(y).fill(e, from: 0, to: cols) }
                    scrollTop = 0; scrollBottom = rows - 1
                    setCursor(x: 0, y: 0)
                }
            default: break
            }
            return
        }
        switch final {
        case 0x37: saveCursor()                 // 7 DECSC
        case 0x38: restoreCursor()              // 8 DECRC
        case 0x44: index(); pendingWrap = false // D IND
        case 0x45: cursorX = 0; index(); pendingWrap = false // E NEL
        case 0x48: tabStops[cursorX] = true     // H HTS
        case 0x4D: reverseIndex(); pendingWrap = false // M RI
        case 0x4E: singleShift = 2              // N SS2
        case 0x4F: singleShift = 3              // O SS3
        case 0x63: reset()                      // c RIS
        case 0x3D: modes.keypadApp = true       // = DECKPAM
        case 0x3E: modes.keypadApp = false      // > DECKPNM
        case 0x6E: gl = 2                       // n LS2
        case 0x6F: gl = 3                       // o LS3
        default: break
        }
    }

    // MARK: Responses

    @inline(__always) func reply(_ s: String) {
        pendingOutput.append(contentsOf: s.utf8)
    }
}
