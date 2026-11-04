import Foundation

extension Terminal {
    public func csiDispatch(_ csi: CSISequence) {
        lastPrintValid = false
        let inter = csi.intermediate
        switch csi.leader {
        case 0:
            if inter == 0 { csiStandard(csi) } else { csiIntermediate(csi, inter) }
        case 0x3F: // ?
            csiPrivate(csi, inter)
        case 0x3E: // >
            switch csi.final {
            case 0x63: reply("\u{1B}[>1;100;0c") // DA2
            case 0x71 where csi.param(0, 0) == 0: // XTVERSION
                reply("\u{1B}P>|vitterm 0.1.0\u{1B}\\")
            case 0x75: // kitty keyboard push
                let flags = UInt8(truncatingIfNeeded: csi.rawParam(0, 0) & 0x1F)
                if usingAlternate {
                    if kittyStackAlternate.count >= 16 { kittyStackAlternate.removeFirst() }
                    kittyStackAlternate.append(flags)
                } else {
                    if kittyStackPrimary.count >= 16 { kittyStackPrimary.removeFirst() }
                    kittyStackPrimary.append(flags)
                }
            default: break
            }
        case 0x3C: // <
            if csi.final == 0x75 { // kitty keyboard pop
                let n = csi.param(0, 1)
                if usingAlternate { kittyStackAlternate.removeLast(min(n, kittyStackAlternate.count)) }
                else { kittyStackPrimary.removeLast(min(n, kittyStackPrimary.count)) }
            }
        case 0x3D: // =
            if csi.final == 0x75 { // kitty keyboard set
                let flags = UInt8(truncatingIfNeeded: csi.rawParam(0, 0) & 0x1F)
                let mode = csi.param(1, 1)
                func apply(_ stack: inout [UInt8]) {
                    let cur = stack.last ?? 0
                    let new: UInt8
                    switch mode {
                    case 2: new = cur | flags
                    case 3: new = cur & ~flags
                    default: new = flags
                    }
                    if stack.isEmpty { stack.append(new) } else { stack[stack.count - 1] = new }
                }
                if usingAlternate { apply(&kittyStackAlternate) } else { apply(&kittyStackPrimary) }
            }
        default:
            break
        }
    }

    func csiStandard(_ csi: CSISequence) {
        switch csi.final {
        case 0x40: insertBlankCells(csi.param(0, 1))                                   // @ ICH
        case 0x41: cursorUp(csi.param(0, 1))                                           // A CUU
        case 0x42, 0x65: cursorDown(csi.param(0, 1))                                   // B CUD, e VPR
        case 0x43, 0x61: cursorX = min(cursorX + csi.param(0, 1), cols - 1); pendingWrap = false // C CUF, a HPR
        case 0x44: cursorX = max(cursorX - csi.param(0, 1), 0); pendingWrap = false   // D CUB
        case 0x45: cursorDown(csi.param(0, 1)); cursorX = 0                            // E CNL
        case 0x46: cursorUp(csi.param(0, 1)); cursorX = 0                              // F CPL
        case 0x47, 0x60: cursorX = min(csi.param(0, 1) - 1, cols - 1); pendingWrap = false // G CHA, ` HPA
        case 0x48, 0x66: setCursor(x: csi.param(1, 1) - 1, y: csi.param(0, 1) - 1)    // H CUP, f HVP
        case 0x49: tab(forward: csi.param(0, 1))                                       // I CHT
        case 0x4A: eraseDisplay(csi.rawParam(0, 0))                                    // J ED
        case 0x4B: eraseLine(csi.rawParam(0, 0))                                       // K EL
        case 0x4C: insertLines(csi.param(0, 1))                                        // L IL
        case 0x4D: deleteLines(csi.param(0, 1))                                        // M DL
        case 0x50: deleteCells(csi.param(0, 1))                                        // P DCH
        case 0x53: scrollUp(csi.param(0, 1))                                           // S SU
        case 0x54 where csi.count <= 1: scrollDown(csi.param(0, 1))                    // T SD
        case 0x58:                                                                     // X ECH
            let n = min(csi.param(0, 1), cols - cursorX)
            let line = currentLine
            splitWide(line, cursorX, n)
            line.fill(blank(), from: cursorX, to: cursorX + n)
            pendingWrap = false
        case 0x5A: tab(backward: csi.param(0, 1))                                      // Z CBT
        case 0x62:                                                                     // b REP
            if lastPrintedScalar != 0 {
                let n = min(csi.param(0, 1), 65535)
                let cp = lastPrintedScalar
                let w = CharWidth.of(cp)
                if w > 0 { for _ in 0..<n { writeCell(cp, width: w) } }
            }
        case 0x63: if csi.param(0, 0) == 0 { reply("\u{1B}[?62;22;52c") }              // c DA1
        case 0x64: setCursor(x: cursorX, y: (csi.param(0, 1) - 1))                     // d VPA
            if modes.originMode { cursorY = min(scrollTop + csi.param(0, 1) - 1, scrollBottom) }
        case 0x67:                                                                     // g TBC
            switch csi.rawParam(0, 0) {
            case 0: tabStops[cursorX] = false
            case 3: for i in tabStops.indices { tabStops[i] = false }
            default: break
            }
        case 0x68: for i in 0..<csi.count { setANSIMode(Int(csi.params[i]), true) }   // h SM
        case 0x6C: for i in 0..<csi.count { setANSIMode(Int(csi.params[i]), false) }  // l RM
        case 0x6D: sgr(csi)                                                            // m SGR
        case 0x6E:                                                                     // n DSR
            switch csi.rawParam(0, 0) {
            case 5: reply("\u{1B}[0n")
            case 6:
                let y = modes.originMode ? cursorY - scrollTop : cursorY
                reply("\u{1B}[\(y + 1);\(cursorX + 1)R")
            default: break
            }
        case 0x72:                                                                     // r DECSTBM
            let top = csi.param(0, 1) - 1
            let bottom = min(csi.param(1, rows), rows) - 1
            if top < bottom {
                scrollTop = top
                scrollBottom = bottom
                setCursor(x: 0, y: 0)
            }
        case 0x73: saveCursor()                                                        // s SCOSC
        case 0x75: restoreCursor()                                                     // u SCORC
        case 0x74: windowOp(csi)                                                       // t XTWINOPS
        default: break
        }
    }

    func cursorUp(_ n: Int) {
        let limit = cursorY >= scrollTop ? scrollTop : 0
        cursorY = max(cursorY - n, limit)
        pendingWrap = false
    }

    func cursorDown(_ n: Int) {
        let limit = cursorY <= scrollBottom ? scrollBottom : rows - 1
        cursorY = min(cursorY + n, limit)
        pendingWrap = false
    }

    func csiIntermediate(_ csi: CSISequence, _ inter: UInt8) {
        switch (inter, csi.final) {
        case (0x20, 0x71): // SP q  DECSCUSR
            switch csi.rawParam(0, 0) {
            case 0: cursorShape = nil; cursorShapeBlinks = nil
            case 1: cursorShape = .block; cursorShapeBlinks = true
            case 2: cursorShape = .block; cursorShapeBlinks = false
            case 3: cursorShape = .underline; cursorShapeBlinks = true
            case 4: cursorShape = .underline; cursorShapeBlinks = false
            case 5: cursorShape = .bar; cursorShapeBlinks = true
            case 6: cursorShape = .bar; cursorShapeBlinks = false
            default: break
            }
            pendingEvents.append(.cursorShapeChanged)
        case (0x21, 0x70): // ! p  DECSTR
            softReset()
        case (0x24, 0x70): // $ p  DECRQM (ANSI)
            let mode = csi.rawParam(0, 0)
            let v: Int
            switch mode {
            case 4: v = modes.insertMode ? 1 : 2
            case 20: v = modes.newlineMode ? 1 : 2
            default: v = 0
            }
            reply("\u{1B}[\(mode);\(v)$y")
        case (0x22, 0x71): // " q  DECSCA
            if csi.rawParam(0, 0) == 1 { pen.flags.insert(.protected) } else { pen.flags.remove(.protected) }
        default:
            break
        }
    }

    func csiPrivate(_ csi: CSISequence, _ inter: UInt8) {
        if inter == 0x24 && csi.final == 0x70 { // ? $ p  DECRQM
            let mode = csi.rawParam(0, 0)
            let v: Int
            if let set = privateMode(mode) { v = set ? 1 : 2 } else { v = 0 }
            reply("\u{1B}[?\(mode);\(v)$y")
            return
        }
        guard inter == 0 else { return }
        switch csi.final {
        case 0x68: for i in 0..<csi.count { setPrivateMode(Int(csi.params[i]), true) }
        case 0x6C: for i in 0..<csi.count { setPrivateMode(Int(csi.params[i]), false) }
        case 0x4A: eraseDisplay(csi.rawParam(0, 0))   // DECSED
        case 0x4B: eraseLine(csi.rawParam(0, 0))      // DECSEL
        case 0x6E:
            switch csi.rawParam(0, 0) {
            case 6:
                let y = modes.originMode ? cursorY - scrollTop : cursorY
                reply("\u{1B}[?\(y + 1);\(cursorX + 1)R")
            case 996:
                reply("\u{1B}[?997;\(isDarkBackground ? 1 : 2)n")
            default: break
            }
        case 0x73: // save private modes
            for i in 0..<csi.count {
                let m = Int(csi.params[i])
                if let v = privateMode(m) { savedPrivateModes[m] = v }
            }
        case 0x72: // restore private modes
            for i in 0..<csi.count {
                let m = Int(csi.params[i])
                if let v = savedPrivateModes[m] { setPrivateMode(m, v) }
            }
        case 0x75: // kitty keyboard query
            reply("\u{1B}[?\(kittyKeyboardFlags)u")
        default: break
        }
    }

    func setANSIMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 4: modes.insertMode = on
        case 20: modes.newlineMode = on
        default: break
        }
    }

    func privateMode(_ mode: Int) -> Bool? {
        switch mode {
        case 1: return modes.cursorKeysApp
        case 5: return modes.reverseVideo
        case 6: return modes.originMode
        case 7: return modes.autowrap
        case 12: return modes.cursorBlink ?? false
        case 25: return modes.cursorVisible
        case 9: return modes.mouseTracking == .x10
        case 1000: return modes.mouseTracking == .normal
        case 1002: return modes.mouseTracking == .button
        case 1003: return modes.mouseTracking == .any
        case 1004: return modes.focusEvents
        case 1005: return modes.mouseEncoding == .utf8
        case 1006: return modes.mouseEncoding == .sgr
        case 1016: return modes.mouseEncoding == .sgrPixels
        case 1007: return modes.alternateScroll
        case 47, 1047, 1049: return usingAlternate
        case 2004: return modes.bracketedPaste
        case 2026: return modes.synchronizedOutput
        case 2027: return modes.graphemeClustering
        case 2031: return modes.colorSchemeUpdates
        default: return nil
        }
    }

    func setPrivateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: modes.cursorKeysApp = on
        case 3: // DECCOLM: we don't change width, but do clear the screen like xterm.
            eraseDisplay(2); setCursor(x: 0, y: 0)
            scrollTop = 0; scrollBottom = rows - 1
        case 5:
            if modes.reverseVideo != on { modes.reverseVideo = on; grid.touchAll() }
        case 6: modes.originMode = on; setCursor(x: 0, y: 0)
        case 7: modes.autowrap = on; if !on { pendingWrap = false }
        case 12: modes.cursorBlink = on
        case 25: modes.cursorVisible = on
        case 9: modes.mouseTracking = on ? .x10 : .none
        case 1000: modes.mouseTracking = on ? .normal : .none
        case 1002: modes.mouseTracking = on ? .button : .none
        case 1003: modes.mouseTracking = on ? .any : .none
        case 1004: modes.focusEvents = on
        case 1005: modes.mouseEncoding = on ? .utf8 : .x10
        case 1006: modes.mouseEncoding = on ? .sgr : .x10
        case 1016: modes.mouseEncoding = on ? .sgrPixels : .x10
        case 1007: modes.alternateScroll = on
        case 47:
            if on { enterAlternate(clear: false) } else { exitAlternate() }
        case 1047:
            if on { enterAlternate(clear: true) } else {
                if usingAlternate { for y in 0..<rows { alternate.screenLine(y).clear() } }
                exitAlternate()
            }
        case 1048:
            if on { saveCursor() } else { restoreCursor() }
        case 1049:
            if on {
                if !usingAlternate {
                    saveCursor()
                    enterAlternate(clear: true)
                }
            } else if usingAlternate {
                exitAlternate()
                restoreCursor()
            }
        case 2004: modes.bracketedPaste = on
        case 2026: modes.synchronizedOutput = on
        case 2027: modes.graphemeClustering = on
        case 2031: modes.colorSchemeUpdates = on
        default: break
        }
    }

    func windowOp(_ csi: CSISequence) {
        switch csi.param(0, 0) {
        case 14: reply("\u{1B}[4;\(rows * cellPixelHeight);\(cols * cellPixelWidth)t")
        case 16: reply("\u{1B}[6;\(cellPixelHeight);\(cellPixelWidth)t")
        case 18: reply("\u{1B}[8;\(rows);\(cols)t")
        case 22: // push title
            if titleStack.count < 32 { titleStack.append(title) }
        case 23: // pop title
            if let t = titleStack.popLast() { title = t; pendingEvents.append(.title(t)) }
        default: break
        }
    }

    // MARK: SGR

    func sgr(_ csi: CSISequence) {
        if csi.count == 0 { pen.fg = .default; pen.bg = .default; pen.flags = pen.flags.intersection(.protected); pen.underlineColor = .default; updatePenExtra(); return }
        var i = 0
        let n = csi.count
        let p = csi.params
        var extraChanged = false
        while i < n {
            let v = p[i] < 0 ? 0 : Int(p[i])
            switch v {
            case 0:
                let prot = pen.flags.intersection(.protected)
                pen.fg = .default; pen.bg = .default; pen.flags = prot
                if !pen.underlineColor.isDefault { pen.underlineColor = .default; extraChanged = true }
            case 1: pen.flags.insert(.bold)
            case 2: pen.flags.insert(.faint)
            case 3: pen.flags.insert(.italic)
            case 4:
                if i + 1 < n && csi.isSub(i + 1) {
                    i += 1
                    switch p[i] {
                    case 0: pen.flags.underline = .none
                    case 2: pen.flags.underline = .double
                    case 3: pen.flags.underline = .curly
                    case 4: pen.flags.underline = .dotted
                    case 5: pen.flags.underline = .dashed
                    default: pen.flags.underline = .single
                    }
                    while i + 1 < n && csi.isSub(i + 1) { i += 1 }
                } else {
                    pen.flags.underline = .single
                }
            case 5, 6: pen.flags.insert(.blink)
            case 7: pen.flags.insert(.inverse)
            case 8: pen.flags.insert(.invisible)
            case 9: pen.flags.insert(.strikethrough)
            case 21: pen.flags.underline = .double
            case 22: pen.flags.remove([.bold, .faint])
            case 23: pen.flags.remove(.italic)
            case 24: pen.flags.underline = .none
            case 25: pen.flags.remove(.blink)
            case 27: pen.flags.remove(.inverse)
            case 28: pen.flags.remove(.invisible)
            case 29: pen.flags.remove(.strikethrough)
            case 30...37: pen.fg = .palette(UInt8(v - 30))
            case 38:
                if let (c, next) = parseExtendedColor(csi, i) { pen.fg = c; i = next } else { i = skipColor(csi, i) }
            case 39: pen.fg = .default
            case 40...47: pen.bg = .palette(UInt8(v - 40))
            case 48:
                if let (c, next) = parseExtendedColor(csi, i) { pen.bg = c; i = next } else { i = skipColor(csi, i) }
            case 49: pen.bg = .default
            case 53: pen.flags.insert(.overline)
            case 55: pen.flags.remove(.overline)
            case 58:
                if let (c, next) = parseExtendedColor(csi, i) { pen.underlineColor = c; i = next; extraChanged = true }
                else { i = skipColor(csi, i) }
            case 59: pen.underlineColor = .default; extraChanged = true
            case 90...97: pen.fg = .palette(UInt8(v - 90 + 8))
            case 100...107: pen.bg = .palette(UInt8(v - 100 + 8))
            default: break
            }
            i += 1
        }
        if extraChanged { updatePenExtra() }
    }

    func skipColor(_ csi: CSISequence, _ i: Int) -> Int {
        var j = i
        while j + 1 < csi.count && csi.isSub(j + 1) { j += 1 }
        return j
    }

    /// Parse `38;5;n`, `38;2;r;g;b`, `38:5:n`, `38:2::r:g:b` and `38:2:r:g:b`. Returns the color and
    /// the index of the last consumed parameter.
    func parseExtendedColor(_ csi: CSISequence, _ i: Int) -> (TermColor, Int)? {
        let p = csi.params
        let n = csi.count
        guard i + 1 < n else { return nil }
        let colon = csi.isSub(i + 1)
        let kind = p[i + 1]
        if colon {
            // Gather all sub-parameters.
            var subs: [Int32] = []
            var j = i + 1
            while j < n && csi.isSub(j) { subs.append(p[j]); j += 1 }
            let last = j - 1
            switch subs.first {
            case 5:
                guard subs.count >= 2 else { return nil }
                return (.palette(UInt8(clamping: max(0, subs[1]))), last)
            case 2:
                let rgb = subs.count >= 5 ? Array(subs[2...4]) : Array(subs.dropFirst().prefix(3))
                guard rgb.count == 3 else { return nil }
                return (.rgb(UInt8(clamping: max(0, rgb[0])), UInt8(clamping: max(0, rgb[1])), UInt8(clamping: max(0, rgb[2]))), last)
            default:
                return nil
            }
        }
        switch kind {
        case 5:
            guard i + 2 < n else { return nil }
            return (.palette(UInt8(clamping: max(0, p[i + 2]))), i + 2)
        case 2:
            guard i + 4 < n else { return nil }
            return (.rgb(UInt8(clamping: max(0, p[i + 2])), UInt8(clamping: max(0, p[i + 3])), UInt8(clamping: max(0, p[i + 4]))), i + 4)
        default:
            return nil
        }
    }
}
