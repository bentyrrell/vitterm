import XCTest
@testable import VitCore

/// Byte sequences sent for keys, per xterm conventions and the Kitty keyboard protocol.
final class KeyEncoderTests: XCTestCase {
    func enc(_ key: KeyInput.Key, _ mods: KeyInput.Mods = [], text: String = "", unmodified: String? = nil,
             event: KeyInput.Event = .press, _ ctx: KeyEncoder.Context = .init()) -> String {
        String(decoding: KeyEncoder.encode(KeyInput(key: key, mods: mods, text: text, unmodifiedText: unmodified, event: event), ctx), as: UTF8.self)
    }

    func enc(_ key: KeyInput.Key, _ ctx: KeyEncoder.Context) -> String { enc(key, [], text: "", ctx) }

    func testPrintableText() {
        XCTAssertEqual(enc(.char(0x61), text: "a"), "a")
        XCTAssertEqual(enc(.char(0x61), .shift, text: "A"), "A")
        XCTAssertEqual(enc(.char(0x65), text: "é"), "é", "composed text (Option as compose) is sent as-is")
        XCTAssertEqual(enc(.space, text: " "), " ")
    }

    func testControlCharacters() {
        let table: [(UInt32, UInt8)] = [(0x61, 1), (0x7A, 26), (0x40, 0), (0x32, 0), (0x5B, 27), (0x33, 27), (0x5C, 28),
                                        (0x5D, 29), (0x5E, 30), (0x36, 30), (0x5F, 31), (0x2F, 31), (0x2D, 31), (0x3F, 127)]
        for (key, byte) in table {
            XCTAssertEqual(KeyEncoder.encode(KeyInput(key: .char(key), mods: .ctrl, text: ""), .init()), [byte],
                           "ctrl+\(Character(UnicodeScalar(key)!))")
        }
        XCTAssertEqual(enc(.space, .ctrl), "\u{0}")
        XCTAssertEqual(enc(.char(0x31), .ctrl, text: "1"), "1", "ctrl+1 has no control code: send the digit")
        XCTAssertEqual(enc(.char(0x63), [.ctrl, .alt], text: "c"), "\u{1B}\u{03}", "ctrl+alt adds ESC")
    }

    func testAltAsMeta() {
        XCTAssertEqual(enc(.char(0x62), .alt, text: "∫", unmodified: "b"), "\u{1B}b")
        XCTAssertEqual(enc(.char(0x62), [.alt, .shift], text: "ı", unmodified: "B"), "\u{1B}B")
        XCTAssertEqual(enc(.backspace, .alt), "\u{1B}\u{7F}")
        XCTAssertEqual(enc(.enter, .alt), "\u{1B}\r")
    }

    func testEditingKeys() {
        XCTAssertEqual(enc(.enter), "\r")
        XCTAssertEqual(enc(.enter, .init(), KeyEncoder.Context(newlineMode: true)), "\r\n")
        XCTAssertEqual(enc(.tab), "\t")
        XCTAssertEqual(enc(.tab, .shift), "\u{1B}[Z")
        XCTAssertEqual(enc(.backspace), "\u{7F}")
        XCTAssertEqual(enc(.backspace, .ctrl), "\u{08}")
        XCTAssertEqual(enc(.escape), "\u{1B}")
        XCTAssertEqual(enc(.insert), "\u{1B}[2~")
        XCTAssertEqual(enc(.delete), "\u{1B}[3~")
        XCTAssertEqual(enc(.pageUp), "\u{1B}[5~")
        XCTAssertEqual(enc(.pageDown, .shift), "\u{1B}[6;2~")
    }

    func testCursorKeysAllModifierCombinations() {
        let letters: [(KeyInput.Key, String)] = [(.up, "A"), (.down, "B"), (.right, "C"), (.left, "D"), (.home, "H"), (.end, "F")]
        let mods: [(KeyInput.Mods, Int)] = [(.shift, 2), (.alt, 3), ([.shift, .alt], 4), (.ctrl, 5), ([.ctrl, .shift], 6),
                                            ([.ctrl, .alt], 7), ([.ctrl, .alt, .shift], 8)]
        for (key, final) in letters {
            XCTAssertEqual(enc(key), "\u{1B}[\(final)")
            XCTAssertEqual(enc(key, .init(), KeyEncoder.Context(cursorKeysApp: true)), "\u{1B}O\(final)", "DECCKM")
            for (m, p) in mods {
                XCTAssertEqual(enc(key, m), "\u{1B}[1;\(p)\(final)")
                XCTAssertEqual(enc(key, m, KeyEncoder.Context(cursorKeysApp: true)), "\u{1B}[1;\(p)\(final)",
                               "modifiers always use the CSI form")
            }
        }
        XCTAssertEqual(enc(.up, .super), "\u{1B}[A", "Cmd is not sent in legacy mode")
    }

    func testFunctionKeys() {
        let expected = ["\u{1B}OP", "\u{1B}OQ", "\u{1B}OR", "\u{1B}OS", "\u{1B}[15~", "\u{1B}[17~", "\u{1B}[18~",
                        "\u{1B}[19~", "\u{1B}[20~", "\u{1B}[21~", "\u{1B}[23~", "\u{1B}[24~"]
        for (i, e) in expected.enumerated() { XCTAssertEqual(enc(.f(i + 1)), e, "F\(i + 1)") }
        XCTAssertEqual(enc(.f(1), .shift), "\u{1B}[1;2P")
        XCTAssertEqual(enc(.f(5), .ctrl), "\u{1B}[15;5~")
    }

    func testKeypad() {
        XCTAssertEqual(enc(.keypad(0x35), text: "5"), "5")
        XCTAssertEqual(enc(.keypad(0x35), text: "5", KeyEncoder.Context(keypadApp: true)), "\u{1B}Ou")
        XCTAssertEqual(enc(.keypad(0x0D), text: "\r", KeyEncoder.Context(keypadApp: true)), "\u{1B}OM")
    }

    // MARK: Kitty keyboard protocol

    func testKittyDisambiguate() {
        let k = KeyEncoder.Context(kittyFlags: 1)
        XCTAssertEqual(enc(.char(0x61), text: "a", k), "a", "plain text stays text")
        XCTAssertEqual(enc(.char(0x61), .shift, text: "A", k), "A")
        XCTAssertEqual(enc(.escape, k), "\u{1B}[27u")
        XCTAssertEqual(enc(.char(0x63), .ctrl, text: "c", k), "\u{1B}[99;5u")
        XCTAssertEqual(enc(.char(0x63), [.ctrl, .shift], text: "C", k), "\u{1B}[99;6u")
        XCTAssertEqual(enc(.char(0x78), .alt, text: "x", k), "\u{1B}[120;3u")
        XCTAssertEqual(enc(.enter, k), "\r")
        XCTAssertEqual(enc(.enter, .ctrl, k), "\u{1B}[13;5u")
        XCTAssertEqual(enc(.backspace, k), "\u{7F}")
        XCTAssertEqual(enc(.tab, .shift, k), "\u{1B}[9;2u")
        XCTAssertEqual(enc(.up, k), "\u{1B}[A")
        XCTAssertEqual(enc(.up, .ctrl, k), "\u{1B}[1;5A")
        XCTAssertEqual(enc(.f(3), k), "\u{1B}[13~", "F3 uses 13~ (CSI R would clash with cursor reports)")
        XCTAssertEqual(enc(.char(0x73), .super, text: "s", k), "\u{1B}[115;9u", "Cmd is reported as super")
    }

    func testKittyEventTypes() {
        let k = KeyEncoder.Context(kittyFlags: 1 | 2)
        XCTAssertEqual(enc(.char(0x61), text: "a", event: .release, k), "", "text key releases need report-all")
        XCTAssertEqual(enc(.escape, event: .release, k), "\u{1B}[27;1:3u")
        XCTAssertEqual(enc(.escape, event: .repeat, k), "\u{1B}[27;1:2u")
        XCTAssertEqual(enc(.up, event: .release, k), "\u{1B}[1;1:3A")
        let noEvents = KeyEncoder.Context(kittyFlags: 1)
        XCTAssertEqual(enc(.escape, event: .release, noEvents), "", "releases need flag 2")
    }

    func testKittyReportAllKeys() {
        let k = KeyEncoder.Context(kittyFlags: 8)
        XCTAssertEqual(enc(.char(0x61), text: "a", k), "\u{1B}[97u")
        XCTAssertEqual(enc(.char(0x61), .shift, text: "A", k), "\u{1B}[97;2u")
        XCTAssertEqual(enc(.enter, k), "\u{1B}[13u")
        XCTAssertEqual(enc(.space, k), "\u{1B}[32u")
        let withText = KeyEncoder.Context(kittyFlags: 8 | 16)
        XCTAssertEqual(enc(.char(0x61), .shift, text: "A", withText), "\u{1B}[97;2;65u")
        XCTAssertEqual(enc(.char(0x61), text: "a", withText), "\u{1B}[97;;97u")
    }

    func testKittyKeypadCodes() {
        let k = KeyEncoder.Context(kittyFlags: 1 | 8)
        XCTAssertEqual(enc(.keypad(0x31), text: "1", k), "\u{1B}[57400u")
        XCTAssertEqual(enc(.keypad(0x0D), text: "\r", k), "\u{1B}[57414u")
    }
}
