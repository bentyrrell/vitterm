/// A parsed CSI (or DCS header) sequence. Parameter storage is owned by the parser and is only
/// valid for the duration of the dispatch call.
public struct CSISequence {
    public let params: UnsafeBufferPointer<Int32>
    /// Bit i is set when params[i] was introduced by ':' (a sub-parameter of the previous one).
    public let subMask: UInt64
    /// Private marker: 0, '?', '>', '<' or '='.
    public let leader: UInt8
    /// Up to two intermediate bytes packed little-endian (first in the low byte).
    public let intermediates: UInt16
    public let final: UInt8

    public static let missing: Int32 = -1

    @inlinable public var count: Int { params.count }

    /// Parameter i, substituting `def` when missing or zero (the usual VT semantics).
    @inlinable public func param(_ i: Int, _ def: Int) -> Int {
        guard i < params.count else { return def }
        let v = params[i]
        return v <= 0 ? def : Int(v)
    }

    /// Parameter i, substituting `def` only when missing (zero is preserved).
    @inlinable public func rawParam(_ i: Int, _ def: Int) -> Int {
        guard i < params.count else { return def }
        let v = params[i]
        return v < 0 ? def : Int(v)
    }

    @inlinable public func isSub(_ i: Int) -> Bool { i < 64 && (subMask >> UInt64(i)) & 1 == 1 }
    @inlinable public var intermediate: UInt8 { UInt8(truncatingIfNeeded: intermediates) }
}

public protocol ParserHandler: AnyObject {
    /// A run of printable ASCII bytes (0x20...0x7E) in the ground state.
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>)
    /// A single printable non-ASCII scalar.
    func printScalar(_ cp: UInt32)
    /// A run of printable scalars (non-ASCII mixed with ASCII), decoded in bulk.
    func printScalars(_ scalars: UnsafeBufferPointer<UInt32>)
    /// A C0 control.
    func execute(_ byte: UInt8)
    func csiDispatch(_ csi: CSISequence)
    func escDispatch(intermediates: UInt16, final: UInt8)
    /// OSC payload without the introducer and terminator.
    func oscDispatch(_ data: UnsafeBufferPointer<UInt8>)
    /// Complete DCS: header plus payload.
    func dcsDispatch(_ header: CSISequence, data: UnsafeBufferPointer<UInt8>)
    /// APC payload (used by the Kitty graphics protocol).
    func apcDispatch(_ data: UnsafeBufferPointer<UInt8>)
}

extension ParserHandler {
    public func printScalars(_ scalars: UnsafeBufferPointer<UInt32>) {
        for cp in scalars { printScalar(cp) }
    }
}

/// A VT500-series compatible escape sequence parser (after Paul Williams' DEC ANSI state machine),
/// with UTF-8 decoding and a bulk fast path for printable ASCII.
public final class Parser {
    enum State: UInt8 {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case oscString, apcString, sosPmString
    }

    static let maxParams = 32
    /// Upper bound for OSC/DCS/APC payloads (large enough for inline images).
    public static var maxStringLength = 64 * 1024 * 1024

    var state: State = .ground
    let params = UnsafeMutablePointer<Int32>.allocate(capacity: Parser.maxParams)
    var paramCount = 0
    var subMask: UInt64 = 0
    var currentParam: Int32 = CSISequence.missing
    var leader: UInt8 = 0
    var intermediates: UInt16 = 0
    var intermediateCount = 0
    var stringBuf: [UInt8] = []
    var stringOverflow = false
    /// ESC seen while inside a string state (possible ST).
    var stringEsc = false
    var dcsHeader: (params: [Int32], subMask: UInt64, leader: UInt8, intermediates: UInt16, final: UInt8)?

    // UTF-8 decoder state.
    var utf8Codepoint: UInt32 = 0
    var utf8Remaining = 0
    var utf8Min: UInt32 = 0

    static let scalarCapacity = 1024
    let scalarBuf = UnsafeMutablePointer<UInt32>.allocate(capacity: Parser.scalarCapacity)

    public init() {
        stringBuf.reserveCapacity(4096)
    }

    deinit {
        params.deallocate()
        scalarBuf.deallocate()
    }

    public func reset() {
        state = .ground
        utf8Remaining = 0
        clearSequence()
    }

    @inline(__always) func clearSequence() {
        paramCount = 0
        subMask = 0
        currentParam = CSISequence.missing
        leader = 0
        intermediates = 0
        intermediateCount = 0
        currentIsSub = false
    }

    /// Index of the first byte at or after `start` that is not printable ASCII (0x20...0x7E).
    @inline(__always) static func scanPrintable(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Int {
        var i = start
        let lo = SIMD16<UInt8>(repeating: 0x20), span = SIMD16<UInt8>(repeating: 0x5F)
        while i + 16 <= end {
            let v = UnsafeRawPointer(p + i).loadUnaligned(as: SIMD16<UInt8>.self)
            // (v - 0x20) wraps for v < 0x20, so a single unsigned compare checks both bounds.
            if any((v &- lo) .>= span) { break }
            i += 16
        }
        while i < end {
            let b = p[i]
            if b < 0x20 || b > 0x7E { break }
            i += 1
        }
        return i
    }

    public func parse<H: ParserHandler>(_ data: UnsafeBufferPointer<UInt8>, handler: H) {
        guard let base = data.baseAddress else { return }
        let end = data.count
        var i = 0
        while i < end {
            switch state {
            case .ground where utf8Remaining == 0:
                // Fast path: a run of printable ASCII.
                let start = i
                i = Parser.scanPrintable(base, i, end)
                if i > start {
                    handler.printASCII(UnsafeBufferPointer(start: base + start, count: i - start))
                    if i >= end { return }
                }
                // Fast path: a run of printable text containing non-ASCII. Decode it in bulk (ASCII
                // included) up to the next control, escape or invalid sequence.
                let b = base[i]
                if b >= 0xC2, Parser.decodeUTF8(base, i, end) != nil {
                    var count = 0
                    while i < end && count < Parser.scalarCapacity {
                        let c = base[i]
                        if c >= 0x20 && c <= 0x7E {
                            scalarBuf[count] = UInt32(c); count += 1; i += 1
                        } else if c >= 0xC2, let (cp, n) = Parser.decodeUTF8(base, i, end) {
                            if cp < 0x80 || cp > 0x9F { scalarBuf[count] = cp; count += 1 } // drop C1 controls
                            i += n
                        } else {
                            break
                        }
                    }
                    handler.printScalars(UnsafeBufferPointer(start: scalarBuf, count: count))
                    continue
                }
            case .csiEntry, .csiParam:
                // Fast path: parameter bytes.
                while i < end {
                    let b = base[i]
                    if b >= 0x30 && b <= 0x39 {
                        let d = Int32(b - 0x30)
                        currentParam = currentParam < 0 ? d : min(currentParam &* 10 &+ d, 0xFFFF)
                        state = .csiParam
                    } else if b == 0x3B {
                        pushParam(sub: currentIsSub); currentIsSub = false; state = .csiParam
                    } else if b == 0x3A {
                        pushParam(sub: currentIsSub); currentIsSub = true; state = .csiParam
                    } else {
                        break
                    }
                    i += 1
                }
                if i >= end { return }
                let b = base[i]
                if b >= 0x40 && b <= 0x7E {
                    dispatchCSI(b, handler)
                    i += 1
                    continue
                }
            default:
                break
            }
            step(base[i], handler)
            i += 1
        }
    }

    /// Decode one complete, valid UTF-8 sequence at `i`. Returns nil if it's invalid or truncated
    /// (the byte-wise decoder then handles it).
    @inline(__always) static func decodeUTF8(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> (UInt32, Int)? {
        let b0 = UInt32(p[i])
        if b0 <= 0xDF {
            guard i + 1 < end else { return nil }
            let b1 = UInt32(p[i + 1])
            guard b1 & 0xC0 == 0x80 else { return nil }
            return ((b0 & 0x1F) << 6 | (b1 & 0x3F), 2)
        }
        if b0 <= 0xEF {
            guard i + 2 < end else { return nil }
            let b1 = UInt32(p[i + 1]), b2 = UInt32(p[i + 2])
            guard b1 & 0xC0 == 0x80, b2 & 0xC0 == 0x80 else { return nil }
            let cp = (b0 & 0x0F) << 12 | (b1 & 0x3F) << 6 | (b2 & 0x3F)
            guard cp >= 0x800, cp < 0xD800 || cp > 0xDFFF else { return nil }
            return (cp, 3)
        }
        if b0 <= 0xF4 {
            guard i + 3 < end else { return nil }
            let b1 = UInt32(p[i + 1]), b2 = UInt32(p[i + 2]), b3 = UInt32(p[i + 3])
            guard b1 & 0xC0 == 0x80, b2 & 0xC0 == 0x80, b3 & 0xC0 == 0x80 else { return nil }
            let cp = (b0 & 0x07) << 18 | (b1 & 0x3F) << 12 | (b2 & 0x3F) << 6 | (b3 & 0x3F)
            guard cp >= 0x10000, cp <= 0x10FFFF else { return nil }
            return (cp, 4)
        }
        return nil
    }

    public func parse<H: ParserHandler>(_ bytes: [UInt8], handler: H) {
        bytes.withUnsafeBufferPointer { parse($0, handler: handler) }
    }

    @inline(__always) func step<H: ParserHandler>(_ b: UInt8, _ h: H) {
        // String states consume everything until a terminator.
        switch state {
        case .oscString, .apcString, .sosPmString, .dcsPassthrough, .dcsIgnore:
            stringByte(b, h)
            return
        default: break
        }

        if state == .ground {
            if utf8Remaining > 0 || b >= 0x80 {
                utf8Byte(b, h)
                return
            }
        } else if b >= 0x80 {
            // Non-ASCII inside a control sequence: ignore.
            return
        }

        // "Anywhere" transitions.
        switch b {
        case 0x18, 0x1A: // CAN, SUB
            if b == 0x1A { h.printScalar(0xFFFD) }
            state = .ground
            return
        case 0x1B:
            clearSequence()
            state = .escape
            return
        default: break
        }

        switch state {
        case .ground:
            if b < 0x20 {
                h.execute(b)
            } else if b < 0x7F {
                h.printScalar(UInt32(b))
            }
        case .escape:
            escape(b, h)
        case .escapeIntermediate:
            if b < 0x20 { h.execute(b) }
            else if b <= 0x2F { collect(b) }
            else if b <= 0x7E { h.escDispatch(intermediates: intermediates, final: b); state = .ground }
        case .csiEntry, .csiParam:
            csiParamByte(b, h)
        case .csiIntermediate:
            if b < 0x20 { h.execute(b) }
            else if b <= 0x2F { collect(b) }
            else if b <= 0x3F { state = .csiIgnore }
            else if b <= 0x7E { dispatchCSI(b, h) }
        case .csiIgnore:
            if b < 0x20 { h.execute(b) }
            else if b >= 0x40 && b <= 0x7E { state = .ground }
        case .dcsEntry, .dcsParam:
            dcsParamByte(b)
        case .dcsIntermediate:
            if b < 0x20 { return }
            else if b <= 0x2F { collect(b) }
            else if b <= 0x3F { state = .dcsIgnore }
            else if b <= 0x7E { hookDCS(b) }
        default:
            break
        }
    }

    @inline(__always) func escape<H: ParserHandler>(_ b: UInt8, _ h: H) {
        switch b {
        case 0x00...0x1F: h.execute(b)
        case 0x20...0x2F: collect(b); state = .escapeIntermediate
        case 0x5B: clearSequence(); state = .csiEntry          // [
        case 0x5D: beginString(.oscString)                      // ]
        case 0x50: clearSequence(); state = .dcsEntry           // P
        case 0x5F: beginString(.apcString)                      // _
        case 0x58, 0x5E: beginString(.sosPmString)              // X ^
        case 0x30...0x7E:
            h.escDispatch(intermediates: intermediates, final: b)
            state = .ground
        default: state = .ground
        }
    }

    @inline(__always) func collect(_ b: UInt8) {
        if intermediateCount < 2 {
            intermediates |= UInt16(b) << UInt16(8 * intermediateCount)
        }
        intermediateCount += 1
    }

    @inline(__always) func pushParam(sub: Bool) {
        if paramCount < Parser.maxParams {
            params[paramCount] = currentParam
            if sub && paramCount < 64 { subMask |= 1 << UInt64(paramCount) }
            paramCount += 1
        }
        currentParam = CSISequence.missing
    }

    /// Whether the param currently being accumulated was introduced by ':'.
    var currentIsSub = false

    @inline(__always) func paramByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39:
            let d = Int32(b - 0x30)
            currentParam = currentParam < 0 ? d : min(currentParam &* 10 &+ d, 0xFFFF)
            return true
        case 0x3B: // ;
            pushParam(sub: currentIsSub); currentIsSub = false
            return true
        case 0x3A: // :
            pushParam(sub: currentIsSub); currentIsSub = true
            return true
        default:
            return false
        }
    }

    @inline(__always) func csiParamByte<H: ParserHandler>(_ b: UInt8, _ h: H) {
        if b < 0x20 { h.execute(b); return }
        if paramByte(b) { state = .csiParam; return }
        switch b {
        case 0x3C...0x3F:
            if state == .csiEntry { leader = b; state = .csiParam } else { state = .csiIgnore }
        case 0x20...0x2F:
            collect(b); state = .csiIntermediate
        case 0x40...0x7E:
            dispatchCSI(b, h)
        default:
            break
        }
    }

    @inline(__always) func finishParams() {
        if currentParam != CSISequence.missing || paramCount > 0 || currentIsSub {
            pushParam(sub: currentIsSub)
        }
        currentIsSub = false
    }

    @inline(__always) func dispatchCSI<H: ParserHandler>(_ final: UInt8, _ h: H) {
        finishParams()
        if intermediateCount <= 2 {
            let seq = CSISequence(params: UnsafeBufferPointer(start: params, count: paramCount), subMask: subMask,
                                  leader: leader, intermediates: intermediates, final: final)
            h.csiDispatch(seq)
        }
        state = .ground
    }

    func dcsParamByte(_ b: UInt8) {
        if b < 0x20 { return }
        if paramByte(b) { state = .dcsParam; return }
        switch b {
        case 0x3C...0x3F:
            if state == .dcsEntry { leader = b; state = .dcsParam } else { state = .dcsIgnore }
        case 0x20...0x2F:
            collect(b); state = .dcsIntermediate
        case 0x40...0x7E:
            hookDCS(b)
        default: break
        }
    }

    func hookDCS(_ final: UInt8) {
        finishParams()
        dcsHeader = (Array(UnsafeBufferPointer(start: params, count: paramCount)), subMask, leader, intermediates, final)
        stringBuf.removeAll(keepingCapacity: true)
        stringOverflow = false
        stringEsc = false
        state = .dcsPassthrough
    }

    func beginString(_ s: State) {
        stringBuf.removeAll(keepingCapacity: true)
        stringOverflow = false
        stringEsc = false
        state = s
    }

    @inline(__always) func stringByte<H: ParserHandler>(_ b: UInt8, _ h: H) {
        if stringEsc {
            stringEsc = false
            if b == 0x5C { // ST
                finishString(h)
                state = .ground
                return
            }
            // Any other byte after ESC aborts the string and starts a new escape sequence.
            finishString(h)
            clearSequence()
            state = .escape
            step(b, h)
            return
        }
        switch b {
        case 0x1B:
            stringEsc = true
        case 0x07 where state == .oscString:
            finishString(h)
            state = .ground
        case 0x18, 0x1A:
            state = .ground
        default:
            if state == .sosPmString || state == .dcsIgnore { return }
            if stringBuf.count < Parser.maxStringLength { stringBuf.append(b) } else { stringOverflow = true }
        }
    }

    func finishString<H: ParserHandler>(_ h: H) {
        if stringOverflow { return }
        switch state {
        case .oscString:
            stringBuf.withUnsafeBufferPointer { h.oscDispatch($0) }
        case .apcString:
            stringBuf.withUnsafeBufferPointer { h.apcDispatch($0) }
        case .dcsPassthrough:
            if let hdr = dcsHeader {
                hdr.params.withUnsafeBufferPointer { p in
                    let seq = CSISequence(params: p, subMask: hdr.subMask, leader: hdr.leader,
                                          intermediates: hdr.intermediates, final: hdr.final)
                    stringBuf.withUnsafeBufferPointer { h.dcsDispatch(seq, data: $0) }
                }
            }
        default: break
        }
        if stringBuf.capacity > 1 << 20 { stringBuf = []; stringBuf.reserveCapacity(4096) }
    }

    @inline(__always) func utf8Byte<H: ParserHandler>(_ b: UInt8, _ h: H) {
        if utf8Remaining == 0 {
            switch b {
            case 0xC2...0xDF: utf8Codepoint = UInt32(b & 0x1F); utf8Remaining = 1; utf8Min = 0x80
            case 0xE0...0xEF: utf8Codepoint = UInt32(b & 0x0F); utf8Remaining = 2; utf8Min = 0x800
            case 0xF0...0xF4: utf8Codepoint = UInt32(b & 0x07); utf8Remaining = 3; utf8Min = 0x10000
            default: h.printScalar(0xFFFD)
            }
            return
        }
        if b & 0xC0 != 0x80 {
            // Truncated sequence: emit replacement, then reprocess this byte from scratch.
            utf8Remaining = 0
            h.printScalar(0xFFFD)
            step(b, h)
            return
        }
        utf8Codepoint = utf8Codepoint << 6 | UInt32(b & 0x3F)
        utf8Remaining -= 1
        if utf8Remaining == 0 {
            let cp = utf8Codepoint
            if cp < utf8Min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                h.printScalar(0xFFFD)
            } else if cp >= 0x80 && cp <= 0x9F {
                // C1 controls encoded as UTF-8 are ignored.
            } else {
                h.printScalar(cp)
            }
        }
    }
}
