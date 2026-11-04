import Foundation
import VitCore
import VitPTY
import VitRender

// vitterm benchmark suite.
//
//   vitbench [all|parse|pty|render|reflow|search]... [--mb N] [--check]
//
// --check compares results against conservative minimums (release builds) and exits 1 on a
// regression, so it can be used as a performance test.

// MARK: - Deterministic input

/// SplitMix64: deterministic, so every run measures identical data.
struct Rng {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
}

let words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "terminal", "render", "metal",
             "swift", "buffer", "cursor", "scroll", "parser", "glyph", "atlas", "frame", "window"]
let codeTokens = ["let", "var", "func", "return", "if", "else", "for", "in", "x", "y", "count", "self", "->", "=>",
                  "!=", "==", "===", "<=", ">=", "&&", "||", "//", "/*", "*/", "::", "{", "}", "(", ")", "[", "]",
                  "0x1F", "42", "+=", "...", "<-", "|>", "www", "\"str\"", "'c'", ";", ",", "."]
let unicodeTokens = ["héllo", "wörld", "日本語", "中文字符", "😀", "👩‍💻", "Ελληνικά", "русский", "e\u{301}", "│─┼", "한국어"]

func lines(_ n: Int, seed: UInt64, _ make: (inout Rng) -> String) -> [String] {
    var rng = Rng(seed)
    return (0..<n).map { _ in make(&rng) }
}

func asciiLine(_ r: inout Rng) -> String {
    var s = ""
    let target = r.int(20...140)
    while s.count < target { s += r.pick(words) + " " }
    return s
}

func codeLine(_ r: inout Rng) -> String {
    var s = String(repeating: " ", count: r.int(0...4) * 2)
    for _ in 0..<r.int(3...14) { s += r.pick(codeTokens) + " " }
    return s
}

func colorCodeLine(_ r: inout Rng) -> String {
    var s = String(repeating: " ", count: r.int(0...4) * 2)
    for _ in 0..<r.int(3...12) {
        s += "\u{1B}[\(r.int(31...36))m" + r.pick(codeTokens) + "\u{1B}[0m "
    }
    return s
}

func unicodeLine(_ r: inout Rng) -> String {
    (0..<r.int(4...12)).map { _ in r.pick(unicodeTokens) }.joined(separator: " ")
}

func stream(_ targetMB: Int, _ chunk: String) -> [UInt8] {
    let c = Array(chunk.utf8)
    var buf: [UInt8] = []
    buf.reserveCapacity(targetMB << 20 + c.count)
    while buf.count < targetMB << 20 { buf.append(contentsOf: c) }
    return buf
}

// MARK: - Results

struct Result {
    var group: String
    var name: String
    var value: Double
    var unit: String
    var higherIsBetter: Bool
    var minimum: Double? = nil   // for --check (higherIsBetter) or maximum when lower is better
}

var results: [Result] = []

func report(_ r: Result) {
    results.append(r)
    let v = r.value >= 100 ? String(format: "%9.0f", r.value) : String(format: "%9.2f", r.value)
    print("  \(r.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(v) \(r.unit)")
}

/// CPU time of this thread (not wall time): unaffected by other processes taking the CPU.
func time(_ body: () -> Void) -> Double {
    let t0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    return Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - t0) / 1e9
}

/// Wall time, for benchmarks that involve other processes (PTY).
func wallTime(_ body: () -> Void) -> Double {
    let t0 = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9
}

func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }

// MARK: - Parse throughput

func benchParse(mb: Int) {
    print("parse — Terminal.feed throughput (200x60, 10k scrollback), \(mb) MB per stream")
    var rng = Rng(1)
    let cursorChunk: String = {
        var s = ""
        for _ in 0..<5000 {
            s += "\u{1B}[\(rng.int(1...60));\(rng.int(1...200))H" + rng.pick(words)
            if rng.int(0...9) == 0 { s += "\u{1B}[K" }
            if rng.int(0...49) == 0 { s += "\u{1B}[5;50r\u{1B}[50;1H\n\n\u{1B}[r" }
        }
        return s
    }()
    let sgrChunk: String = {
        var s = ""
        for _ in 0..<2000 {
            for _ in 0..<12 {
                s += "\u{1B}[\(rng.int(30...37));\(rng.int(0...1))m" + rng.pick(words) + "\u{1B}[38;2;\(rng.int(0...255));10;200m "
            }
            s += "\u{1B}[0m\r\n"
        }
        return s
    }()
    let streams: [(String, String, Double)] = [
        ("ascii", lines(2000, seed: 2, asciiLine).joined(separator: "\r\n") + "\r\n", 250),
        ("code", lines(2000, seed: 3, codeLine).joined(separator: "\r\n") + "\r\n", 160),
        ("sgr", sgrChunk, 200),
        ("unicode", lines(2000, seed: 4, unicodeLine).joined(separator: "\r\n") + "\r\n", 140),
        ("cursor", cursorChunk, 150),
    ]
    for (name, chunk, minimum) in streams {
        let bytes = stream(mb, chunk)
        var best = Double.infinity
        for _ in 0..<3 {
            let t = Terminal(cols: 200, rows: 60, scrollback: 10_000)
            best = min(best, time {
                bytes.withUnsafeBufferPointer { all in
                    var off = 0
                    while off < all.count {
                        let n = min(1 << 17, all.count - off)
                        t.lock.withLock { t.feed(UnsafeBufferPointer(rebasing: all[off..<(off + n)])) }
                        t.pendingOutput.removeAll(keepingCapacity: true)
                        off += n
                    }
                }
            })
        }
        report(Result(group: "parse", name: name, value: Double(bytes.count) / 1_048_576 / best, unit: "MB/s", higherIsBetter: true, minimum: minimum))
    }
}

// MARK: - End-to-end PTY throughput

func benchPTY(mb: Int) {
    print("pty — `cat` through a real PTY, \(mb) MB")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitbench-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("data.txt")
    let chunk = lines(4000, seed: 5, codeLine).joined(separator: "\n") + "\n"
    FileManager.default.createFile(atPath: file.path, contents: Data(stream(mb, chunk)))
    let size = Double((try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0)

    func run(parse: Bool) -> Double {
        let t = Terminal(cols: 200, rows: 60, scrollback: 10_000)
        let done = DispatchSemaphore(value: 0)
        let p = try! PTYProcess(executable: "/bin/cat", args: ["cat", file.path], environment: ["PATH": "/bin:/usr/bin"],
                                cwd: nil, cols: 200, rows: 60)
        p.onOutput = { data in
            guard parse else { return }
            t.lock.lock()
            t.feed(data)
            t.pendingOutput.removeAll(keepingCapacity: true)
            t.lock.unlock()
        }
        p.onExit = { _ in done.signal() }
        let secs = wallTime {
            p.start()
            done.wait()
        }
        return size / 1_048_576 / secs
    }
    _ = run(parse: false) // warm the page cache
    report(Result(group: "pty", name: "read only (kernel ceiling)", value: max(run(parse: false), run(parse: false)), unit: "MB/s", higherIsBetter: true))
    report(Result(group: "pty", name: "read + parse", value: max(run(parse: true), run(parse: true)), unit: "MB/s", higherIsBetter: true, minimum: 80))
}

// MARK: - Rendering (CPU side of a frame)

func benchRender() {
    let fira = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Fonts/FiraCode-Regular.ttf")
    let family = fira ? "Fira Code" : ""
    print("render — CPU time to build a frame, 200x60 cells @2x (font: \(fira ? "Fira Code" : "system mono"))")
    let size = CGSize(width: 200 * 18, height: 60 * 36)

    func scenario(_ name: String, ligatures: Bool, maxMicros: Double?, frames: Int = 120,
                  setup: (Terminal) -> Void, perFrame: ((Terminal, Int) -> Void)?) {
        let r = TerminalRenderer(spec: FontSpec(family: family, size: 13, ligatures: ligatures), scale: 2)
        let t = Terminal(cols: 200, rows: 60, scrollback: 10_000)
        t.lock.withLock { setup(t) }
        var o = RenderOptions()
        o.paddingX = 20; o.paddingY = 12
        let overlay = RenderOverlay()
        // Warm up: populate the glyph atlas and caches.
        for i in 0..<5 {
            if let pf = perFrame { t.lock.withLock { pf(t, i) } }
            r.prepareFrame(terminal: t, overlay: overlay, options: o, size: size)
        }
        var samples: [Double] = []
        for i in 0..<frames {
            if let pf = perFrame { t.lock.withLock { pf(t, i + 5) } }
            o.cursorBlinkVisible = i % 2 == 0
            samples.append(time { r.prepareFrame(terminal: t, overlay: overlay, options: o, size: size) } * 1e6)
        }
        report(Result(group: "render", name: name, value: median(samples), unit: "µs/frame", higherIsBetter: false, minimum: maxMicros))
    }

    let code = lines(4000, seed: 6, colorCodeLine)
    let plain = lines(4000, seed: 7, asciiLine)
    let uni = lines(4000, seed: 8, unicodeLine)
    func fill(_ src: [String]) -> (Terminal) -> Void {
        { t in for l in src.prefix(60) { t.feed(l + "\r\n") } }
    }
    func scroll(_ src: [String], _ n: Int) -> (Terminal, Int) -> Void {
        { t, i in for k in 0..<n { t.feed(src[(i * n + k) % src.count] + "\r\n") } }
    }
    // Budgets are well under one 120 Hz frame (8.3 ms) and several times the current cost.
    scenario("static screen (cursor blink)", ligatures: true, maxMicros: 800, setup: fill(code), perFrame: nil)
    scenario("scrolling plain text, 60 lines/frame", ligatures: true, maxMicros: 1500, setup: fill(plain), perFrame: scroll(plain, 60))
    scenario("scrolling code, ligatures on", ligatures: true, maxMicros: 1500, setup: fill(code), perFrame: scroll(code, 60))
    scenario("scrolling code, ligatures off", ligatures: false, maxMicros: 1200, setup: fill(code), perFrame: scroll(code, 60))
    scenario("scrolling unicode", ligatures: true, maxMicros: 2000, setup: fill(uni), perFrame: scroll(uni, 60))
    scenario("typing (1 line changes per frame)", ligatures: true, maxMicros: 800, setup: fill(code), perFrame: { t, i in
        t.feed("\u{1B}[60;1H\u{1B}[2K$ " + String(repeating: "x", count: i % 150))
    })
}

// MARK: - Reflow

func benchReflow() {
    print("reflow — resize with a full 10k-line scrollback (200 cols)")
    let t = Terminal(cols: 200, rows: 50, scrollback: 10_000)
    var rng = Rng(9)
    t.lock.withLock {
        for _ in 0..<10_050 {
            // Mostly short lines, some long enough to wrap.
            let n = rng.int(0...9) == 0 ? rng.int(200...500) : rng.int(0...120)
            t.feed(String(repeating: "x", count: n) + "\r\n")
        }
    }
    var samples: [Double] = []
    for i in 0..<20 {
        let cols = i % 2 == 0 ? 160 : 200
        samples.append(time { t.lock.withLock { t.resize(cols: cols, rows: 50) } } * 1000)
    }
    report(Result(group: "reflow", name: "resize 200<->160 cols", value: median(samples), unit: "ms", higherIsBetter: false, minimum: 20))
    samples = []
    for i in 0..<20 {
        let rows = i % 2 == 0 ? 40 : 50
        samples.append(time { t.lock.withLock { t.resize(cols: 200, rows: rows) } } * 1000)
    }
    report(Result(group: "reflow", name: "resize rows only (50<->40)", value: median(samples), unit: "ms", higherIsBetter: false, minimum: 20))
}

// MARK: - Search

func benchSearch() {
    print("search — whole scrollback, 10k lines of code")
    let t = Terminal(cols: 200, rows: 50, scrollback: 10_000)
    t.lock.withLock {
        for (i, l) in lines(10_050, seed: 10, codeLine).enumerated() {
            t.feed(l + (i % 997 == 0 ? " needle" : "") + "\r\n")
        }
    }
    for (name, q, regex, limit) in [("literal, rare (\"needle\")", "needle", false, 3.0),
                                    ("literal, common (\"return\")", "return", false, 3.0),
                                    ("regex (\"0x[0-9A-F]+\")", "0x[0-9A-F]+", true, 5.0)] {
        var samples: [Double] = []
        var count = 0
        for _ in 0..<7 {
            samples.append(time { count = t.lock.withLock { t.search(q, regex: regex).count } } * 1000)
        }
        report(Result(group: "search", name: "\(name) [\(count) hits]", value: median(samples), unit: "ms", higherIsBetter: false, minimum: limit))
    }
    // Cold: content changed since the last search, so the index is rebuilt first.
    var cold: [Double] = []
    for _ in 0..<7 {
        t.lock.withLock { t.feed([UInt8]()) }
        cold.append(time { _ = t.lock.withLock { t.search("return").count } } * 1000)
    }
    report(Result(group: "search", name: "cold (index rebuild + literal)", value: median(cold), unit: "ms", higherIsBetter: false, minimum: 10))
}

// MARK: - Memory

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func benchMemory() {
    print("memory — physical footprint of a full scrollback (200 columns)")
    for lines in [10_000, 100_000] {
        let before = footprintMB()
        let t = Terminal(cols: 200, rows: 50, scrollback: lines)
        let src = lines < 50_000 ? codeLineSamples : codeLineSamples
        t.lock.withLock {
            for i in 0..<(lines + 60) { t.feed(src[i % src.count] + "\r\n") }
        }
        let after = footprintMB()
        // Deterministic accounting of cell storage (plus per-line object overhead) for the check;
        // the process footprint is informative but depends on allocator reuse.
        let storage = t.lock.withLock { () -> Double in
            var bytes = 0
            for i in 0..<t.primary.count { bytes += t.primary.line(at: i).capacity * MemoryLayout<Cell>.stride + 96 }
            return Double(bytes) / 1_048_576
        }
        report(Result(group: "memory", name: "\(lines / 1000)k lines: line storage", value: storage, unit: "MB",
                      higherIsBetter: false, minimum: Double(lines) / 1000 * 1.5))  // budget: 1.5 KB per line
        report(Result(group: "memory", name: "\(lines / 1000)k lines: process footprint", value: after - before, unit: "MB",
                      higherIsBetter: false))
        withExtendedLifetime(t) {}
    }
}

let codeLineSamples = lines(4000, seed: 11, codeLine)

// MARK: - Profiling helper

/// `vitbench profile <unicode|code|ascii> <seconds>`: feed one stream repeatedly so a sampler can attach.
func profileLoop(_ kind: String, seconds: Double) {
    let src: [String]
    switch kind {
    case "unicode": src = lines(2000, seed: 4, unicodeLine)
    case "code": src = lines(2000, seed: 3, codeLine)
    default: src = lines(2000, seed: 2, asciiLine)
    }
    let bytes = Array((src.joined(separator: "\r\n") + "\r\n").utf8)
    let t = Terminal(cols: 200, rows: 60, scrollback: 10_000)
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        bytes.withUnsafeBufferPointer { t.feed($0) }
        t.pendingOutput.removeAll(keepingCapacity: true)
    }
}

// MARK: - Main

// Ask for the performance cores; default QoS can land on efficiency cores and skew results.
pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "profile" {
    profileLoop(args.count > 1 ? args[1] : "unicode", seconds: args.count > 2 ? Double(args[2]) ?? 5 : 5)
    exit(0)
}
var mb = 64
if let i = args.firstIndex(of: "--mb"), i + 1 < args.count { mb = Int(args[i + 1]) ?? 64; args.removeSubrange(i...(i + 1)) }
let check = args.contains("--check")
args.removeAll { $0.hasPrefix("--") }
let which = Set(args.isEmpty ? ["all"] : args)
func want(_ s: String) -> Bool { which.contains("all") || which.contains(s) }

#if DEBUG
print("warning: debug build; use `swift run -c release vitbench` for meaningful numbers\n")
#endif
if want("memory") { benchMemory(); print() }   // first, before other benchmarks churn the heap
if want("parse") { benchParse(mb: mb); print() }
if want("pty") { benchPTY(mb: mb); print() }
if want("render") { benchRender(); print() }
if want("reflow") { benchReflow(); print() }
if want("search") { benchSearch(); print() }

if check {
    let failures = results.filter { r in
        guard let m = r.minimum else { return false }
        return r.higherIsBetter ? r.value < m : r.value > m
    }
    for f in failures {
        print("FAIL \(f.group)/\(f.name): \(String(format: "%.2f", f.value)) \(f.unit) (limit \(f.minimum!))")
    }
    print(failures.isEmpty ? "performance check passed (\(results.count) measurements)" : "performance check FAILED")
    exit(failures.isEmpty ? 0 : 1)
}
