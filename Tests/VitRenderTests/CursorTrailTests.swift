import XCTest
@testable import VitRender


final class CursorTrailTests: XCTestCase {
    let opts = CursorTrailOptions(color: 0xD33682, opacity: 0.6, fastDecay: 0.1, slowDecay: 0.4, threshold: 2)
    let cell = SIMD2<Float>(10, 20)
    let settle = CursorTrail.settleTime

    func testJumpAnimatesAndConverges() {
        var t = CursorTrail()
        _ = t.update(cursor: CursorTrail.box(0, 0, 10, 20), cell: cell, options: opts, now: 0)
        // Jump 20 cells to the right. The first frame only notes the jump; once the cursor has
        // stayed there for the settle time, the trail starts.
        XCTAssertTrue(t.update(cursor: CursorTrail.box(200, 0, 10, 20), cell: cell, options: opts, now: 0.016).isEmpty)
        XCTAssertFalse(t.animating)
        XCTAssertTrue(t.needsFrames, "must keep rendering until the jump settles")
        let poly = t.update(cursor: CursorTrail.box(200, 0, 10, 20), cell: cell, options: opts, now: 0.016 + settle)
        XCTAssertTrue(t.animating)
        XCTAssertFalse(poly.isEmpty)
        // The smear spans from (near) the old position to the new cursor.
        XCTAssertLessThan(poly.map(\.x).min()!, 50)
        XCTAssertEqual(poly.map(\.x).max()!, 210, accuracy: 0.01)
        var now = 0.016 + settle
        while t.animating && now < 2 {
            now += 0.016
            _ = t.update(cursor: CursorTrail.box(200, 0, 10, 20), cell: cell, options: opts, now: now)
        }
        XCTAssertFalse(t.animating)
        XCTAssertLessThan(now, 0.6, "trail should settle within ~the slow decay time")
    }

    func testLeadingEdgeMovesFasterThanTrailingEdge() {
        var t = CursorTrail()
        _ = t.update(cursor: CursorTrail.box(0, 0, 10, 20), cell: cell, options: opts, now: 0)
        _ = t.update(cursor: CursorTrail.box(200, 0, 10, 20), cell: cell, options: opts, now: 0.016)
        let poly = t.update(cursor: CursorTrail.box(200, 0, 10, 20), cell: cell, options: opts, now: 0.05 + settle)
        // Moving right: the left (trailing) edge lags far behind the right (leading) edge's progress.
        let minX = poly.map(\.x).min()!
        XCTAssertLessThan(minX, 100)
    }

    func testSmallMovesDoNotAnimate() {
        var t = CursorTrail()
        _ = t.update(cursor: CursorTrail.box(0, 0, 10, 20), cell: cell, options: opts, now: 0)
        let poly = t.update(cursor: CursorTrail.box(10, 0, 10, 20), cell: cell, options: opts, now: 0.016)
        XCTAssertTrue(poly.isEmpty)
        XCTAssertFalse(t.animating)
    }

    /// zsh's Tab completion moves the cursor to column 0 of the next row and then back to the end
    /// of the line in one burst. A frame that catches the intermediate position must not start a
    /// trail out to it and back, which would smear across the command line.
    func testTransientJumpDuringRedrawDoesNotAnimate() {
        var t = CursorTrail()
        let home = CursorTrail.box(110, 220, 10, 20)        // end of "$ ls /usr/l", row 11
        _ = t.update(cursor: home, cell: cell, options: opts, now: 0)
        var now = 0.0
        // Fast-path frame mid-redraw: cursor at column 0 of the row below.
        now += 0.001
        XCTAssertTrue(t.update(cursor: CursorTrail.box(0, 240, 10, 20), cell: cell, options: opts, now: now).isEmpty)
        // Next frames: the redraw finished one row up (the screen scrolled), same column.
        for _ in 0..<30 {
            now += 0.016
            XCTAssertTrue(t.update(cursor: CursorTrail.box(110, 200, 10, 20), cell: cell, options: opts, now: now).isEmpty)
            XCTAssertFalse(t.animating)
        }
        XCTAssertFalse(t.needsFrames)
    }

    /// A far position seen in a frame and then replaced by another far one only animates to the
    /// one that stays.
    func testOnlySettledPositionAnimates() {
        var t = CursorTrail()
        _ = t.update(cursor: CursorTrail.box(0, 0, 10, 20), cell: cell, options: opts, now: 0)
        _ = t.update(cursor: CursorTrail.box(0, 200, 10, 20), cell: cell, options: opts, now: 0.016)
        _ = t.update(cursor: CursorTrail.box(300, 0, 10, 20), cell: cell, options: opts, now: 0.032)
        XCTAssertFalse(t.animating)
        let poly = t.update(cursor: CursorTrail.box(300, 0, 10, 20), cell: cell, options: opts, now: 0.032 + settle)
        XCTAssertTrue(t.animating)
        XCTAssertEqual(poly.map(\.y).max()!, 20, accuracy: 0.01, "never heads toward the transient row")
    }

    /// Enter, then typing straight away: the keystrokes land while the trail is still animating to
    /// the new line. The trail must keep going and follow the cursor instead of vanishing mid-flight.
    func testTypingDuringTrailKeepsAnimating() {
        var t = CursorTrail()
        _ = t.update(cursor: CursorTrail.box(300, 0, 10, 20), cell: cell, options: opts, now: 0)
        var now = 0.016
        _ = t.update(cursor: CursorTrail.box(20, 20, 10, 20), cell: cell, options: opts, now: now)   // Enter
        now += settle
        XCTAssertFalse(t.update(cursor: CursorTrail.box(20, 20, 10, 20), cell: cell, options: opts, now: now).isEmpty)
        var x: Float = 20
        for i in 0..<6 {                                     // typing, sometimes two chars per frame
            now += 0.016
            x += (i % 3 == 1) ? 20 : 10
            let poly = t.update(cursor: CursorTrail.box(x, 20, 10, 20), cell: cell, options: opts, now: now)
            XCTAssertTrue(t.animating, "keystroke \(i) cut the trail off")
            XCTAssertFalse(poly.isEmpty)
            XCTAssertGreaterThan(poly.map(\.x).max() ?? 0, x + 9.99, "smear must reach the cursor")
        }
        while t.animating && now < 2 {
            now += 0.016
            _ = t.update(cursor: CursorTrail.box(x, 20, 10, 20), cell: cell, options: opts, now: now)
        }
        XCTAssertFalse(t.animating)
        XCTAssertLessThan(now, 1, "still converges onto the cursor")
    }

    /// zsh after Enter: the cursor goes to the start of the next row at once, sits there while the
    /// prompt is computed (~90 ms with vcs_info), then the two-line prompt puts it a row lower. The
    /// trail must run as one motion from the end of the command line to the prompt: once it is in
    /// flight, it follows the late move at once (no pause, no second hop).
    func testEnterThenLatePromptIsOneContinuousTrail() {
        var t = CursorTrail()
        let endOfLine = CursorTrail.box(90, 20, 10, 20), parked = CursorTrail.box(0, 60, 10, 20)
        let prompt = CursorTrail.box(20, 80, 10, 20)
        _ = t.update(cursor: endOfLine, cell: cell, options: opts, now: 0)
        var now = 0.0
        var started = false
        while now < 1.5 {
            now += 1.0 / 120
            let cursor = now < 0.09 ? parked : prompt
            let poly = t.update(cursor: cursor, cell: cell, options: opts, now: now)
            if t.animating { started = true }
            if started && now < 0.3 {
                XCTAssertTrue(t.animating, "trail paused at \(now)")
                XCTAssertFalse(poly.isEmpty)
            }
            if now >= 0.09 && t.animating {
                XCTAssertEqual(poly.map(\.y).max()!, 100, accuracy: 0.01, "smear must reach the prompt as soon as it is drawn")
            }
        }
        XCTAssertTrue(started)
        XCTAssertFalse(t.animating, "converges onto the prompt")
    }

    /// Output after Enter can arrive a row per frame before the prompt; each one-row step must not
    /// cancel the pending jump, or the trail starts from the last output row instead of the command line.
    func testEnterWithOutputRowByRowStillAnimates() {
        var t = CursorTrail()
        _ = t.update(cursor: CursorTrail.box(90, 20, 10, 20), cell: cell, options: opts, now: 0)
        var now = 0.0
        for row in 2...5 {                                   // "\r\n", then three output lines
            now += 1.0 / 120
            _ = t.update(cursor: CursorTrail.box(0, Float(row) * 20, 10, 20), cell: cell, options: opts, now: now)
        }
        let prompt = CursorTrail.box(20, 120, 10, 20)
        var topOfSmear: Float = .infinity
        for _ in 0..<20 {
            now += 1.0 / 120
            let poly = t.update(cursor: prompt, cell: cell, options: opts, now: now)
            topOfSmear = min(topOfSmear, poly.map(\.y).min() ?? .infinity)
        }
        XCTAssertLessThan(topOfSmear, 40, "the smear starts at the command line, not at the last output row")
    }

    /// Fast typing: the cursor advances a cell or two per frame. Even when two keystrokes land in
    /// one frame (a 2-cell step at threshold 2), the following small steps must not be measured
    /// from the stale resting position and pile up into a trail across the typed text.
    func testFastTypingNeverAnimates() {
        var t = CursorTrail()
        var x: Float = 0
        _ = t.update(cursor: CursorTrail.box(x, 0, 10, 20), cell: cell, options: opts, now: 0)
        var now = 0.0
        for i in 0..<40 {
            now += 0.016
            x += (i % 3 == 1) ? 20 : 10          // sometimes two characters in one frame
            XCTAssertTrue(t.update(cursor: CursorTrail.box(x, 0, 10, 20), cell: cell, options: opts, now: now).isEmpty)
            XCTAssertFalse(t.animating)
        }
        // Typing pauses after a one-cell step: nothing animates afterwards either.
        for _ in 0..<10 {
            now += 0.016
            XCTAssertTrue(t.update(cursor: CursorTrail.box(x, 0, 10, 20), cell: cell, options: opts, now: now).isEmpty)
        }
        XCTAssertFalse(t.animating)
    }
}
