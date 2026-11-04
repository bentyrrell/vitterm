import XCTest
@testable import VitCore

/// Grammar-based fuzzing: random but well-formed CSI / OSC / DCS / APC / ESC sequences with
/// extreme parameters (0, 65535, 20-digit numbers, negatives), random final bytes and payloads,
/// Kitty graphics keys and iTerm2 image arguments. Runs in debug builds, where integer overflow and
/// out-of-bounds indexing trap, to find input that release builds (`-Ounchecked`) would turn into
/// memory corruption. Complements InvariantTests, which mutates a fixed list of fragments.
final class GrammarFuzzTests: XCTestCase {
    override func setUp() { Line.poisonReleasedCells = true }
    override func tearDown() { Line.poisonReleasedCells = false }

    struct Gen {
        var rng: SeededRNG

        mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
        mutating func pick<T>(_ a: [T]) -> T { a.randomElement(using: &rng)! }
        mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }

        mutating func number() -> String {
            switch int(0...9) {
            case 0: return ""
            case 1: return "0"
            case 2: return "1"
            case 3: return "65535"
            case 4: return "99999999999999999999"
            case 5: return "9223372036854775807"
            case 6: return "-\(int(1...100000))"
            case 7: return String(int(0...5000))
            default: return String(int(0...40))
            }
        }

        mutating func params() -> String {
            var s = ""
            for i in 0..<int(0...7) {
                if i > 0 { s += chance(20) ? ":" : ";" }
                s += number()
            }
            return s
        }

        mutating func text() -> String {
            pick(["a", "hello", "中文", "😀", "e\u{301}\u{302}\u{303}", "👩\u{200D}💻", "\u{FE0F}", "\u{1F1EF}\u{1F1F5}",
                  "\t", "\r", "\n", "\u{08}", "\u{7F}", "\u{0E}", "\u{0F}", String(repeating: "x", count: int(1...80)),
                  String(repeating: "\u{301}", count: int(1...60))])
        }

        mutating func payload() -> String {
            pick(["", "?", "rgb:ff/00/00", "#123456", "rgb:fffff/0/0", "c;?", "c;aGVsbG8=", "c;!!notbase64",
                  "file://h/tmp", "file:///tmp/x%20y", "/tmp", "https://e.x", ";https://e.x", "id=1;https://e.x",
                  "4;1;50", "notify;title;body", String(repeating: "A", count: int(0...300)), number(), params(),
                  "\u{1B}", "\u{07}", "\u{9C}", "日本語"])
        }

        mutating func kittyKeys() -> String {
            let keys = ["a", "t", "f", "s", "v", "i", "I", "p", "c", "r", "x", "y", "w", "h", "X", "Y", "z", "C", "m", "o", "q", "d", "O", "S", "U"]
            var parts: [String] = []
            for _ in 0..<int(0...8) {
                let k = pick(keys)
                let v: String
                switch k {
                case "a": v = pick(["t", "T", "p", "d", "q", "f", "x"])
                case "t": v = pick(["d", "f", "t", "s"])
                case "f": v = pick(["24", "32", "100", "0", number()])
                case "o": v = pick(["z", "y"])
                case "d": v = pick(["a", "A", "i", "I", "p", "P", "c", "C", "x", "X", "y", "Y", "z", "Z", "n", "N"])
                case "m": v = pick(["0", "1"])
                default: v = number()
                }
                parts.append("\(k)=\(v)")
            }
            return parts.joined(separator: ",")
        }

        mutating func kittyPayload() -> String {
            pick(["", "AAAA", "AAAAAAAA", "/////w==", Data(count: int(0...64)).base64EncodedString(),
                  Data("/dev/zero".utf8).base64EncodedString(), Data("/nonexistent".utf8).base64EncodedString(),
                  "eJxjYGBgAAAABAAB", "!!!!"])
        }

        mutating func st() -> String { pick(["\u{1B}\\", "\u{07}", "\u{9C}", ""]) }

        mutating func sequence() -> String {
            switch int(0...99) {
            case 0..<20: return text()
            case 20..<45:
                let priv = pick(["", "", "?", ">", "<", "=", "!"])
                let inter = chance(15) ? pick([" ", "!", "\"", "$", "'", "*", "+", "#"]) : ""
                let final = Character(UnicodeScalar(UInt8(int(0x40...0x7E))))
                return "\u{1B}[\(priv)\(params())\(inter)\(final)"
            case 45..<60:
                let cmd = pick(["0", "1", "2", "4", "7", "8", "9", "10", "11", "12", "22", "52", "104", "110", "111", "112",
                                "133", "777", "1337", number()])
                return "\u{1B}]\(cmd);\(payload())\(st())"
            case 60..<72:
                return "\u{1B}_G\(kittyKeys());\(kittyPayload())\(st())"
            case 72..<78:
                let args = (0..<int(0...4)).map { _ in
                    "\(pick(["inline", "width", "height", "preserveAspectRatio", "name", "size"]))=\(pick(["1", "0", "auto", number(), number() + "px", number() + "%"]))"
                }.joined(separator: ";")
                return "\u{1B}]1337;File=\(args):\(chance(50) ? GrammarFuzzTests.png1x1 : kittyPayload())\u{07}"
            case 78..<86:
                let inter = pick(["$", "+", "", "|"])
                let final = pick(["q", "p", "t", "x"])
                return "\u{1B}P\(params())\(inter)\(final)\(pick(["m", "r", " q", "544e", "436f;524742", "zz", payload()]))\(st())"
            case 86..<93:
                return "\u{1B}" + String(Character(UnicodeScalar(UInt8(int(0x20...0x7E)))))
            default:
                return String(Character(UnicodeScalar(UInt8(int(0x00...0x1F)))))
            }
        }
    }

    static let png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="

    func run(seed: UInt64, steps: Int) {
        var g = Gen(rng: SeededRNG(seed))
        let t = Terminal(cols: g.int(1...40), rows: g.int(1...15), scrollback: g.pick([0, 50, 500]))
        var recent: [String] = []
        for step in 0..<steps {
            if g.chance(2) {
                let c = g.int(1...45), r = g.int(1...16)
                recent.append("<resize \(c)x\(r)>")
                InvariantTests.trace.map { tr in try? tr.truncate(atOffset: 0); tr.write(Data("grammar seed \(seed) step \(step)\n\(recent.suffix(16).map(\.debugDescription).joined(separator: "\n"))\n".utf8)) }
                t.resize(cols: c, rows: r)
            } else {
                var s = ""
                for _ in 0..<g.int(1...5) { s += g.sequence() }
                recent.append(s)
                InvariantTests.trace.map { tr in try? tr.truncate(atOffset: 0); tr.write(Data("grammar seed \(seed) step \(step)\n\(recent.suffix(16).map(\.debugDescription).joined(separator: "\n"))\n".utf8)) }
                let bytes = Array(s.utf8)
                let split = g.int(0...bytes.count)
                t.feed(Array(bytes[..<split]))
                t.feed(Array(bytes[split...]))
            }
            if recent.count > 64 { recent.removeFirst(32) }
            t.pendingOutput.removeAll()
            t.pendingEvents.removeAll()
            if step % 8 == 0, let v = invariantViolation(t) {
                XCTFail("grammar seed \(seed) step \(step): \(v)\nlast inputs: \(recent.suffix(6).map(\.debugDescription).joined(separator: " "))")
                return
            }
            if !(0..<t.cols).contains(t.cursorX) || !(0..<t.rows).contains(t.cursorY) {
                XCTFail("grammar seed \(seed) step \(step): cursor (\(t.cursorX),\(t.cursorY)) outside \(t.cols)x\(t.rows)\nlast inputs: \(recent.suffix(6).map(\.debugDescription).joined(separator: " "))")
                return
            }
        }
    }

    func testGrammarFuzzManySeeds() {
        for seed in UInt64(1)...UInt64(60 * InvariantTests.scale) { run(seed: seed, steps: 600) }
    }

    func testGrammarFuzzLongRun() {
        run(seed: 0xBAD5EED, steps: 15_000 * Int(InvariantTests.scale))
    }
}
