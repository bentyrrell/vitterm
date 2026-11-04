import Foundation

/// One row of cells. Lines are reference types so scrolling just moves pointers, and lines evicted
/// from scrollback are recycled to avoid allocation in steady state.
public final class Line {
    /// Cell storage. Only `cells[0..<used]` is meaningful: anything at or beyond `used` is logically
    /// empty, whatever bytes it holds. Read through the subscript (which honors `used`) or clamp to
    /// `used` when reading the pointer directly.
    public private(set) var cells: UnsafeMutablePointer<Cell>
    public private(set) var count: Int
    /// Allocated cells. Equal to `count` for normal lines; scrollback lines are compacted to their
    /// content (`compact()`), and any write first restores full capacity.
    public private(set) var capacity: Int
    /// Number of leading cells that hold content; everything after is empty. Clearing a line just
    /// resets this to 0 (no memory writes), which makes scrolling cost independent of line width.
    public private(set) var used = 0
    /// True when this line soft-wraps into the next one (autowrap happened at its end).
    public var wrapped = false
    /// Bumped whenever the content changes; the renderer uses it to cache shaping.
    public var generation: UInt64 = 0
    /// Shell integration (OSC 133) prompt mark on this line.
    public var promptMark = false
    /// Process-unique identity, so renderers can cache per-line work keyed by (uid, generation).
    public let uid: UInt64

    private static let uidLock = UnfairLock()
    private static var nextUID: UInt64 = 1

    /// Test aid: overwrite released cells with a garbage pattern, so any code that wrongly reads
    /// past `used` sees obviously invalid cells (caught by the invariant tests).
    nonisolated(unsafe) public static var poisonReleasedCells = false

    /// `buffer`, if given, is a reusable allocation of at least `cols` cells (its contents are ignored).
    public init(cols: Int, bg: TermColor = .default, buffer: UnsafeMutablePointer<Cell>? = nil) {
        uid = Line.uidLock.withLock { defer { Line.nextUID &+= 1 }; return Line.nextUID }
        capacity = max(cols, 1)
        count = cols
        if let buffer {
            cells = buffer
        } else {
            cells = .allocate(capacity: capacity)
            cells.initialize(repeating: .empty, count: capacity)
        }
        if bg.isDefault {
            used = 0
        } else {
            cells.update(repeating: Cell.blank(bg: bg), count: cols)
            used = cols
        }
    }

    /// Restore full-width storage (from `buffer`, or a new allocation), keeping the content.
    public func regrow(using buffer: UnsafeMutablePointer<Cell>? = nil) {
        guard capacity < count else { return }
        let n = buffer ?? {
            let b = UnsafeMutablePointer<Cell>.allocate(capacity: count)
            b.initialize(repeating: .empty, count: count)
            return b
        }()
        n.update(from: cells, count: used)
        cells.deallocate()
        cells = n
        capacity = count
    }

    @inline(__always) private func ensureFullCapacity() {
        if capacity < count { regrow() }
    }

    /// Shrink storage to the content, for lines that have scrolled into scrollback (which are not
    /// written again until recycled). Returns the released full-width buffer for reuse, or nil if
    /// compacting isn't worthwhile.
    public func compact() -> UnsafeMutablePointer<Cell>? {
        guard capacity == count, used <= count * 3 / 4 else { return nil }
        let n = max(used, 1)
        let small = UnsafeMutablePointer<Cell>.allocate(capacity: n)
        small.initialize(from: cells, count: used)
        if used == 0 { small.initialize(to: .empty) }
        let old = cells
        cells = small
        capacity = n
        return old
    }

    /// Like `compact()`, but copies the content into `buffer` (holding `bufferCapacity` cells) when
    /// it fits, instead of allocating; then even a nearly full line is worth compacting, since it
    /// costs nothing. Returns the released full-width buffer (nil if compacting isn't worthwhile,
    /// in which case nothing changes) and whether `buffer` was taken.
    public func compact(reusing buffer: UnsafeMutablePointer<Cell>, capacity bufferCapacity: Int)
        -> (released: UnsafeMutablePointer<Cell>, tookBuffer: Bool)? {
        guard capacity == count else { return nil }
        let n = max(used, 1)
        guard bufferCapacity >= n, bufferCapacity < count else {
            guard let old = compact() else { return nil }
            return (old, false)
        }
        buffer.update(from: cells, count: used)
        if used == 0 { buffer.initialize(to: .empty) }
        let old = cells
        cells = buffer
        capacity = bufferCapacity
        return (old, true)
    }

    /// Recycling: switch to the full-width `buffer` (its contents are ignored) and leave the line
    /// empty, without copying the old content. The old storage is freed unless `keepOld` (the
    /// caller took it over).
    public func adoptEmpty(_ buffer: UnsafeMutablePointer<Cell>, keepOld: Bool) {
        if !keepOld { cells.deallocate() }
        cells = buffer
        capacity = count
        if Line.poisonReleasedCells { memset(buffer, 0xA5, count * MemoryLayout<Cell>.stride) }
        used = 0
    }

    deinit { cells.deallocate() }

    public subscript(i: Int) -> Cell {
        @inline(__always) get { i < used ? cells[i] : .empty }
        @inline(__always) set {
            if i >= used {
                if i >= capacity { ensureFullCapacity() }
                if i > used { memset(cells + used, 0, (i - used) * MemoryLayout<Cell>.stride) }
                used = i + 1
            }
            cells[i] = newValue
        }
    }

    /// Prepare to write `n` cells at `x` through the raw pointer: zero any gap between the current
    /// content and `x`, and extend `used` to cover the written range.
    @inline(__always) public func beginWrite(at x: Int, count n: Int) -> UnsafeMutablePointer<Cell> {
        if x + n > capacity { ensureFullCapacity() }
        if x > used { memset(cells + used, 0, (x - used) * MemoryLayout<Cell>.stride) }
        if x + n > used { used = min(x + n, count) }
        return cells + x
    }

    /// Record that cells below `n` were written through the raw pointer (after `beginWrite`).
    @inline(__always) public func commitWrite(upTo n: Int) {
        if n > used { used = min(n, count) }
    }

    /// Make every cell valid (zero the tail), for operations that move cells around.
    public func materialize() {
        ensureFullCapacity()
        if used < count {
            memset(cells + used, 0, (count - used) * MemoryLayout<Cell>.stride)
            used = count
        }
    }

    @inline(__always) private func release(from newUsed: Int) {
        if Line.poisonReleasedCells && newUsed < used {
            memset(cells + newUsed, 0xA5, (used - newUsed) * MemoryLayout<Cell>.stride)
        }
        used = newUsed
    }

    public func clear(bg: TermColor = .default) {
        if bg.isDefault {
            release(from: 0)
        } else {
            ensureFullCapacity()
            cells.update(repeating: Cell.blank(bg: bg), count: count)
            used = count
        }
        wrapped = false
        promptMark = false
        generation &+= 1
    }

    public func fill(_ cell: Cell, from: Int, to: Int) {
        let lo = max(0, from), hi = min(count, to)
        if hi > lo {
            if cell == .empty {
                if hi >= used {
                    // Everything from `lo` on becomes empty.
                    if lo < used { release(from: lo) }
                } else {
                    memset(cells + lo, 0, (hi - lo) * MemoryLayout<Cell>.stride)
                }
            } else {
                if hi > capacity { ensureFullCapacity() }
                if lo > used { memset(cells + used, 0, (lo - used) * MemoryLayout<Cell>.stride) }
                (cells + lo).update(repeating: cell, count: hi - lo)
                if hi > used { used = hi }
            }
        }
        generation &+= 1
    }

    /// Change the column count, truncating or padding with blanks.
    public func resize(cols: Int, bg: TermColor = .default) {
        if cols > capacity {
            let n = UnsafeMutablePointer<Cell>.allocate(capacity: cols)
            n.moveInitialize(from: cells, count: capacity)
            (n + capacity).initialize(repeating: .empty, count: cols - capacity)
            cells.deallocate()
            cells = n
            capacity = cols
        }
        let oldCount = count
        count = cols
        if used > count { release(from: count) }
        if cols > oldCount && !bg.isDefault {
            _ = beginWrite(at: oldCount, count: 0)
            (cells + oldCount).update(repeating: Cell.blank(bg: bg), count: cols - oldCount)
            used = cols
        }
        // A wide char cut in half at the new right edge becomes a blank.
        if count > 0 && self[count - 1].flags.contains(.wide) {
            self[count - 1] = Cell.blank(bg: self[count - 1].bg)
        }
        generation &+= 1
    }

    /// Index one past the last cell with visible content (text, background, or line decorations).
    public var trimmedLength: Int {
        var n = used
        while n > 0 {
            let c = cells[n - 1]
            // A wide spacer belongs to the character before it, so it counts as content.
            if !c.isEmpty || !c.bg.isDefault || c.flags.contains(.inverse) || c.flags.contains(.wideSpacer)
                || c.flags.underline != .none { break }
            n -= 1
        }
        return n
    }

    /// When a wide character doesn't fit in the last column, it wraps and leaves an empty filler
    /// cell behind. That cell is not part of the text: reflow, copy and search skip it.
    @inline(__always) public func endsWithWideWrapFiller(next: Line?) -> Bool {
        guard wrapped, count > 0, let next, next.count > 0 else { return false }
        let last = self[count - 1]
        return last.isEmpty && last.bg.isDefault && !last.flags.contains(.wideSpacer) && next[0].flags.contains(.wide)
    }

    /// Number of cells that carry this line's text when it continues onto `next` (soft wrap).
    @inline(__always) public func wrappedContentLength(next: Line?) -> Int {
        endsWithWideWrapFiller(next: next) ? count - 1 : count
    }

    public func copy(from other: Line) {
        if other.count != count { resize(cols: other.count) }
        ensureFullCapacity()
        cells.update(from: other.cells, count: other.used)
        used = other.used
        wrapped = other.wrapped
        promptMark = other.promptMark
        generation &+= 1
    }
}

/// A screen buffer: the visible rows plus (for the primary screen) scrollback, stored in a ring.
public final class Grid {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public var maxScrollback: Int

    /// Ring storage. Logical index 0 is the oldest scrollback line; the last `rows` are the screen.
    private var ring: [Line]
    private var head = 0
    public private(set) var count: Int
    /// Number of lines that have been evicted from the top of scrollback over the grid's lifetime.
    /// `absoluteIndex = dropped + logicalIndex` gives line numbers that are stable across scrolling.
    public private(set) var dropped: Int = 0

    /// Full-width cell buffers released by compacting lines that scrolled into scrollback, reused
    /// for new and recycled lines (so steady-state scrolling doesn't allocate full rows).
    private var pool: [UnsafeMutablePointer<Cell>] = []
    private static let poolLimit = 16

    public init(cols: Int, rows: Int, maxScrollback: Int) {
        self.cols = cols
        self.rows = rows
        self.maxScrollback = maxScrollback
        ring = (0..<rows).map { _ in Line(cols: cols) }
        count = rows
    }

    deinit { drainPool() }

    private func drainPool() {
        for b in pool { b.deallocate() }
        pool.removeAll()
    }

    @inline(__always) private func recycle(_ buffer: UnsafeMutablePointer<Cell>) {
        if pool.count < Grid.poolLimit { pool.append(buffer) } else { buffer.deallocate() }
    }

    @inlinable public var scrollbackCount: Int { count - rows }

    @inline(__always) func physical(_ logical: Int) -> Int {
        let i = head + logical
        return i >= ring.count ? i - ring.count : i
    }

    /// Line by logical index (0 = oldest scrollback line).
    @inline(__always) public func line(at logical: Int) -> Line {
        assert(logical >= 0 && logical < count, "logical line \(logical) out of 0..<\(count)")
        return ring[physical(logical)]
    }

    /// Visible screen row y (0 = top).
    @inline(__always) public func screenLine(_ y: Int) -> Line {
        assert(y >= 0 && y < rows, "screen row \(y) out of 0..<\(rows)")
        return ring[physical(count - rows + y)]
    }

    /// Line by absolute line number, or nil if it has been evicted.
    public func line(absolute: Int) -> Line? {
        let l = absolute - dropped
        guard l >= 0 && l < count else { return nil }
        return line(at: l)
    }

    /// Absolute line number of screen row y.
    @inlinable public func absolute(screenRow y: Int) -> Int { dropped + scrollbackCount + y }

    /// Scroll the region [top, bottom] up by one line. Lines scrolled off the very top of the screen
    /// go to scrollback when the region starts at row 0 and scrollback is enabled.
    public func scrollUp(top: Int, bottom: Int, bg: TermColor, toScrollback: Bool) {
        if top == 0 && bottom == rows - 1 && toScrollback && maxScrollback > 0 {
            // The top screen line becomes scrollback and won't be written again: compact it and keep
            // its full-width buffer for the new bottom line.
            unowned(unsafe) let leaving = screenLine(0)
            if scrollbackCount >= maxScrollback && scrollbackCount > 0 && leaving.count == cols {
                // Steady state with full scrollback: the oldest line is recycled as the new bottom
                // line. Swap storage instead of allocating: the leaving line is compacted into the
                // oldest line's small buffer (when it fits) and the oldest line takes the leaving
                // line's full-width buffer, with nothing copied that is about to be cleared.
                unowned(unsafe) let old = ring[head]
                if old.count == cols && old.capacity < old.count,
                   let r = leaving.compact(reusing: old.cells, capacity: old.capacity) {
                    old.adoptEmpty(r.released, keepOld: r.tookBuffer)
                } else if let b = leaving.compact() {
                    recycle(b)
                }
            } else if leaving.count == cols, let b = leaving.compact() {
                recycle(b)
            }
            if scrollbackCount < maxScrollback {
                normalize()
                ring.append(Line(cols: cols, bg: bg, buffer: pool.popLast()))
                count += 1
            } else {
                // Recycle the oldest scrollback line as the new bottom line. When the ring is exactly
                // full (the normal case) the oldest slot *is* the new bottom slot, so advancing
                // `head` is enough: no array write, no retain/release.
                let oldSlot = head
                unowned(unsafe) let old = ring[oldSlot]
                if old.count != cols { old.resize(cols: cols) }
                if old.capacity < old.count {
                    // About to be cleared: take a full-width buffer without copying the old content.
                    let b = pool.popLast() ?? {
                        let b = UnsafeMutablePointer<Cell>.allocate(capacity: cols)
                        b.initialize(repeating: .empty, count: cols)
                        return b
                    }()
                    old.adoptEmpty(b, keepOld: false)
                }
                old.clear(bg: bg)
                head += 1
                if head == ring.count { head = 0 }
                let newSlot = physical(count - 1)
                if newSlot != oldSlot { ring[newSlot] = ring[oldSlot] }
                dropped += 1
            }
            return
        }
        // Rotate within the region: the top line is cleared and moved to the bottom.
        let base = count - rows
        let topLine = line(at: base + top)
        var y = top
        while y < bottom {
            ring[physical(base + y)] = ring[physical(base + y + 1)]
            y += 1
        }
        topLine.clear(bg: bg)
        ring[physical(base + bottom)] = topLine
    }

    /// Rotate storage so logical order equals physical order.
    private func normalize() {
        if head != 0 {
            ring = Array(ring[head...] + ring[..<head])
            head = 0
        }
        if ring.count > count { ring.removeLast(ring.count - count) }
    }

    /// Scroll the region [top, bottom] down by one line (a blank line appears at top).
    public func scrollDown(top: Int, bottom: Int, bg: TermColor) {
        let base = count - rows
        let bottomLine = line(at: base + bottom)
        var y = bottom
        while y > top {
            ring[physical(base + y)] = ring[physical(base + y - 1)]
            y -= 1
        }
        bottomLine.clear(bg: bg)
        ring[physical(base + top)] = bottomLine
    }

    public func clearScrollback() {
        let screen = (0..<rows).map { screenLine($0) }
        dropped += scrollbackCount
        ring = screen
        head = 0
        count = rows
    }

    /// Resize without reflow (alt screen): truncate/pad columns, add/remove rows at the bottom.
    public func resizeSimple(cols newCols: Int, rows newRows: Int) {
        if newCols != cols { drainPool() }
        var lines = (0..<count).map { line(at: $0) }
        for l in lines { l.resize(cols: newCols) }
        if newRows > rows {
            for _ in 0..<(newRows - rows) { lines.append(Line(cols: newCols)) }
        } else if newRows < rows {
            lines.removeLast(rows - newRows)
        }
        ring = lines
        head = 0
        count = lines.count
        cols = newCols
        rows = newRows
    }

    /// Resize with reflow. Soft-wrapped lines are joined and re-wrapped at the new width.
    /// `cursor` is (x, screen y); returns its new position.
    public func resizeReflow(cols newCols: Int, rows newRows: Int, cursor rawCursor: (x: Int, y: Int)) -> (x: Int, y: Int) {
        if newCols != cols { drainPool() }
        // The cursor may come from a saved position; never trust it to be inside the grid.
        let cursor = (x: min(max(rawCursor.x, 0), cols), y: min(max(rawCursor.y, 0), rows - 1))
        let cursorLogical = count - rows + cursor.y
        // Ignore blank lines below both the cursor and the last line with content, so they don't
        // get pushed into scrollback when the window shrinks.
        var lastUsed = cursorLogical
        var k = count - 1
        while k > cursorLogical {
            if line(at: k).trimmedLength > 0 { lastUsed = k; break }
            k -= 1
        }

        var out: [Line] = []
        out.reserveCapacity(lastUsed + 2)
        var newCursor = (x: 0, y: 0)
        var logical: [Cell] = []

        var i = 0
        while i <= lastUsed {
            logical.removeAll(keepingCapacity: true)
            var cursorOffset = -1
            var promptMark = false
            while true {
                let l = line(at: i)
                if l.promptMark && logical.isEmpty { promptMark = true }
                let isLast = !l.wrapped || i == lastUsed
                if i == cursorLogical { cursorOffset = logical.count + cursor.x }
                let len = isLast ? l.trimmedLength : l.wrappedContentLength(next: i + 1 < count ? line(at: i + 1) : nil)
                for c in 0..<len { logical.append(l[c]) }
                i += 1
                if isLast { break }
            }

            let firstOut = out.count
            var starts: [Int] = []
            var pos = 0
            repeat {
                let nl = Line(cols: newCols)
                starts.append(pos)
                var col = 0
                while col < newCols && pos < logical.count {
                    let c = logical[pos]
                    if c.flags.contains(.wide) && col == newCols - 1 && newCols > 1 { break }
                    if c.flags.contains(.wideSpacer) && col == 0 { pos += 1; continue }
                    nl[col] = c
                    col += 1
                    pos += 1
                }
                nl.wrapped = pos < logical.count
                out.append(nl)
            } while pos < logical.count
            out[firstOut].promptMark = promptMark

            if cursorOffset >= 0 {
                var j = starts.count - 1
                while j > 0 && starts[j] > cursorOffset { j -= 1 }
                newCursor = (min(cursorOffset - starts[j], newCols), firstOut + j)
            }
        }

        while out.count < newRows { out.append(Line(cols: newCols)) }

        let maxLines = newRows + maxScrollback
        if out.count > maxLines {
            let excess = out.count - maxLines
            out.removeFirst(excess)
            dropped += excess
            newCursor.y -= excess
        }

        let screenTop = out.count - newRows
        ring = out
        head = 0
        count = out.count
        cols = newCols
        rows = newRows
        // x may equal newCols, meaning "pending wrap at the last column".
        return (newCursor.x, max(0, min(newRows - 1, newCursor.y - screenTop)))
    }

    /// Mark every line changed (used after palette/theme changes).
    public func touchAll() {
        for i in 0..<count { line(at: i).generation &+= 1 }
    }
}
