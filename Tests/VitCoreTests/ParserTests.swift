import XCTest
@testable import VitCore

/// Records parser events for inspection.
final class Recorder: ParserHandler {
    var events: [String] = []
    func printASCII(_ bytes: UnsafeBufferPointer<UInt8>) { events.append("print:" + String(decoding: bytes, as: UTF8.self)) }
    func printScalar(_ cp: UInt32) { events.append("scalar:\(String(cp, radix: 16))") }
    func execute(_ byte: UInt8) { events.append("exec:\(byte)") }
    func csiDispatch(_ csi: CSISequence) {
        var s = "csi:"
        if csi.leader != 0 { s += String(UnicodeScalar(csi.leader)) }
        s += (0..<csi.count).map { (csi.isSub($0) ? ":" : "") + String(csi.params[$0]) }.joined(separator: ",")
        if csi.intermediates != 0 { s += "/" + String(UnicodeScalar(csi.intermediate)) }
        s += String(UnicodeScalar(csi.final))
        events.append(s)
    }
    func escDispatch(intermediates: UInt16, final: UInt8) {
        events.append("esc:" + (intermediates != 0 ? String(UnicodeScalar(UInt8(intermediates))) : "") + String(UnicodeScalar(final)))
    }
    func oscDispatch(_ data: UnsafeBufferPointer<UInt8>) { events.append("osc:" + String(decoding: data, as: UTF8.self)) }
    func dcsDispatch(_ header: CSISequence, data: UnsafeBufferPointer<UInt8>) {
        events.append("dcs:" + String(UnicodeScalar(header.final)) + String(decoding: data, as: UTF8.self))
    }
    func apcDispatch(_ data: UnsafeBufferPointer<UInt8>) { events.append("apc:" + String(decoding: data, as: UTF8.self)) }
}

final class ParserTests: XCTestCase {
    func parse(_ s: String) -> [String] {
        let r = Recorder()
        Parser().parse(Array(s.utf8), handler: r)
        return r.events
    }

    func testASCIIRun() {
        XCTAssertEqual(parse("hello"), ["print:hello"])
    }

    func testControls() {
        XCTAssertEqual(parse("a\r\nb"), ["print:a", "exec:13", "exec:10", "print:b"])
    }

    func testCSIParams() {
        XCTAssertEqual(parse("\u{1B}[1;2H"), ["csi:1,2H"])
        XCTAssertEqual(parse("\u{1B}[H"), ["csi:H"])
        XCTAssertEqual(parse("\u{1B}[;5H"), ["csi:-1,5H"])
        XCTAssertEqual(parse("\u{1B}[?1049h"), ["csi:?1049h"])
        XCTAssertEqual(parse("\u{1B}[2 q"), ["csi:2/ q"])
    }

    func testColonSubParams() {
        XCTAssertEqual(parse("\u{1B}[4:3m"), ["csi:4,:3m"])
        XCTAssertEqual(parse("\u{1B}[38:2::1:2:3m"), ["csi:38,:2,:-1,:1,:2,:3m"])
    }

    func testUTF8() {
        XCTAssertEqual(parse("é"), ["scalar:e9"])
        XCTAssertEqual(parse("😀"), ["scalar:1f600"])
        // Truncated sequence followed by ASCII.
        let r = Recorder()
        Parser().parse([0xE2, 0x82, 0x41], handler: r)
        XCTAssertEqual(r.events, ["scalar:fffd", "scalar:41"])
    }

    func testUTF8SplitAcrossChunks() {
        let r = Recorder()
        let p = Parser()
        let bytes = Array("€".utf8)
        p.parse([bytes[0]], handler: r)
        p.parse([bytes[1]], handler: r)
        p.parse([bytes[2]], handler: r)
        XCTAssertEqual(r.events, ["scalar:20ac"])
    }

    func testOSC() {
        XCTAssertEqual(parse("\u{1B}]0;title\u{07}"), ["osc:0;title"])
        XCTAssertEqual(parse("\u{1B}]2;t\u{1B}\\x"), ["osc:2;t", "print:x"])
    }

    func testDCSAndAPC() {
        XCTAssertEqual(parse("\u{1B}P$qm\u{1B}\\"), ["dcs:qm"])
        XCTAssertEqual(parse("\u{1B}_Ga=q;AAAA\u{1B}\\"), ["apc:Ga=q;AAAA"])
    }

    func testCancel() {
        XCTAssertEqual(parse("\u{1B}[12\u{18}x"), ["print:x"])
    }

    func testEscape() {
        XCTAssertEqual(parse("\u{1B}7\u{1B}(0"), ["esc:7", "esc:(0"])
    }
}
