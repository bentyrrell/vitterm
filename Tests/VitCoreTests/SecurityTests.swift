import XCTest
import Compression
@testable import VitCore

/// Regression tests for the security review: untrusted terminal output and pasted/dropped text.
final class SecurityTests: XCTestCase {
    func base64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    // MARK: Image placement (memory safety)

    /// Huge Kitty placement values used to overflow `cursorX + cols` (a negative cursor column in
    /// -Ounchecked release builds, then out-of-bounds writes) and loop `index()` ~forever.
    func testHugeKittyPlacementIsClamped() {
        let t = Terminal(cols: 20, rows: 5)
        t.feed("abcde\u{1B}_Ga=T,f=24,s=1,v=1,c=9223372036854775807,r=9223372036854775807,X=-9223372036854775807,Y=9223372036854775807;AAAA\u{1B}\\")
        XCTAssertEqual(t.images.placements.count, 1)
        let p = t.images.placements[0]
        XCTAssertLessThanOrEqual(p.cols, ImageStore.maxCells)
        XCTAssertLessThanOrEqual(p.rows, ImageStore.maxCells)
        XCTAssert((0..<t.cellPixelWidth).contains(p.offsetX) && (0..<t.cellPixelHeight).contains(p.offsetY))
        XCTAssert((0..<20).contains(t.cursorX), "cursorX \(t.cursorX)")
        t.feed("X")
        XCTAssert((0..<20).contains(t.cursorX))
    }

    func testHugeITerm2SizesAreClamped() {
        let t = Terminal(cols: 20, rows: 5)
        let png = SecurityTests.png1x1()
        for spec in ["width=9223372036854775807;height=9223372036854775807",
                     "width=9223372036854775807px", "width=9223372036854775807%", "height=-5", "width=1;height=9223372036854775807"] {
            t.feed("abc\u{1B}]1337;File=inline=1;\(spec):\(png.base64EncodedString())\u{07}")
            XCTAssert((0..<20).contains(t.cursorX), "\(spec): cursorX \(t.cursorX)")
            for p in t.images.placements {
                XCTAssertLessThanOrEqual(p.cols, ImageStore.maxCells, spec)
                XCTAssertLessThanOrEqual(p.rows, ImageStore.maxCells, spec)
            }
        }
    }

    // MARK: Image resource limits

    func testChunkedTransferIsCapped() {
        let saved = ImageStore.maxTransferBytes
        ImageStore.maxTransferBytes = 1000
        defer { ImageStore.maxTransferBytes = saved }
        let t = Terminal(cols: 20, rows: 5)
        let chunk = String(repeating: "A", count: 600)
        t.feed("\u{1B}_Ga=t,f=24,s=1,v=1,i=7,m=1;\(chunk)\u{1B}\\")
        t.feed("\u{1B}_Gm=1;\(chunk)\u{1B}\\")   // exceeds the cap: transfer abandoned
        XCTAssertFalse(t.images.pendingActive)
        XCTAssertTrue(t.images.pendingData.isEmpty)
    }

    /// A tiny zlib stream that inflates to far more than a 1x1 image needs is rejected.
    func testDecompressionBombIsRejected() throws {
        let zeros = Data(count: 8 << 20)
        let bomb = try XCTUnwrap(SecurityTests.zlib(zeros))
        XCTAssertLessThan(bomb.count, 64 * 1024)
        let t = Terminal(cols: 20, rows: 5)
        t.feed("\u{1B}_Ga=t,f=24,s=1,v=1,o=z,i=3;\(bomb.base64EncodedString())\u{1B}\\")
        XCTAssertTrue(t.images.images.isEmpty)
        XCTAssertNil(ImageStore.inflate(bomb, maxOutput: 1 << 20))
        XCTAssertEqual(ImageStore.inflate(bomb, maxOutput: 16 << 20)?.count, zeros.count)
    }

    func testImageSizeLimits() {
        XCTAssertTrue(ImageStore.validSize(1, 1))
        XCTAssertTrue(ImageStore.validSize(4000, 4000))
        XCTAssertFalse(ImageStore.validSize(10_000, 10_000), "400 MB decoded is over the pixel cap")
        XCTAssertFalse(ImageStore.validSize(20_000, 1))
        XCTAssertFalse(ImageStore.validSize(0, 5))
    }

    // MARK: Kitty file transmission

    func kittyFile(_ t: Terminal, _ path: String, medium: String = "f", extra: String = "") {
        t.feed("\u{1B}_Ga=t,t=\(medium),f=100,i=9\(extra);\(base64(path))\u{1B}\\")
    }

    func testFileTransmissionRefusesDevicesAndPipes() throws {
        let t = Terminal(cols: 20, rows: 5)
        let start = Date()
        kittyFile(t, "/dev/zero")          // used to read until memory ran out
        kittyFile(t, "/dev/urandom")
        let fifo = NSTemporaryDirectory() + "vitterm-fifo-\(UUID().uuidString)"
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        defer { unlink(fifo) }
        kittyFile(t, fifo)                 // used to block the PTY thread forever
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(t.images.images.isEmpty)
    }

    func testFileTransmissionReadsRegularFilesWithinLimits() throws {
        let path = NSTemporaryDirectory() + "vitterm-img-\(UUID().uuidString).png"
        try SecurityTests.png1x1().write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        let t = Terminal(cols: 20, rows: 5)
        kittyFile(t, path)
        XCTAssertEqual(t.images.images.count, 1)

        let saved = ImageStore.maxTransferBytes
        ImageStore.maxTransferBytes = 10
        defer { ImageStore.maxTransferBytes = saved }
        let t2 = Terminal(cols: 20, rows: 5)
        kittyFile(t2, path)
        XCTAssertTrue(t2.images.images.isEmpty, "files over the size limit are refused")
    }

    func testFileTransmissionCanBeDisabled() throws {
        let path = NSTemporaryDirectory() + "vitterm-img-\(UUID().uuidString).png"
        try SecurityTests.png1x1().write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        let t = Terminal(cols: 20, rows: 5)
        t.allowImageFiles = false
        kittyFile(t, path)
        XCTAssertTrue(t.images.images.isEmpty)
    }

    /// `t=t` deletes the file after reading: only real temp files carrying the protocol's marker
    /// in their own name, after resolving `..` and symlinks.
    func testTempFileDeletionIsConfined() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let outside = home + "/.vitterm-test-tty-graphics-protocol-\(UUID().uuidString).png"
        try SecurityTests.png1x1().write(to: URL(fileURLWithPath: outside))
        defer { unlink(outside) }
        let t = Terminal(cols: 20, rows: 5)
        // A temp-dir prefix that escapes with "..".
        kittyFile(t, "/tmp/../" + String(outside.dropFirst()), medium: "t")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside), "file outside temp dirs was deleted")

        // A symlink in /tmp pointing outside.
        let link = "/tmp/vitterm-link-tty-graphics-protocol-\(UUID().uuidString).png"
        XCTAssertEqual(symlink(outside, link), 0)
        defer { unlink(link) }
        kittyFile(t, link, medium: "t")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside), "symlink target outside temp dirs was deleted")
        XCTAssertTrue(t.images.images.isEmpty)

        // The legitimate case still works and deletes the file.
        let tmp = NSTemporaryDirectory() + "tty-graphics-protocol-\(UUID().uuidString).png"
        try SecurityTests.png1x1().write(to: URL(fileURLWithPath: tmp))
        kittyFile(t, tmp, medium: "t")
        XCTAssertEqual(t.images.images.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp))
    }

    // MARK: Hyperlinks, clipboard, titles

    func testHyperlinkLimits() {
        let table = HyperlinkTable()
        XCTAssertEqual(table.intern(id: "", uri: "https://" + String(repeating: "a", count: 3000)), 0, "over-long URI ignored")
        XCTAssertNotEqual(table.intern(id: "", uri: "https://example.com"), 0)
        for i in 0..<(HyperlinkTable.maxLinks + 10) { _ = table.intern(id: "", uri: "https://e.com/\(i)") }
        XCTAssertLessThanOrEqual(table.links.count, HyperlinkTable.maxLinks)
        XCTAssertEqual(table.intern(id: "", uri: "https://new.example"), 0, "full table drops new links instead of reusing ids")
        XCTAssertEqual(table.uri(table.intern(id: "", uri: "https://example.com")), "https://example.com", "existing links still resolve")
    }

    func testOversizedClipboardWriteIgnored() {
        let t = Terminal(cols: 20, rows: 5)
        let big = Data(count: Terminal.maxClipboardWrite + 1024).base64EncodedString()
        t.feed("\u{1B}]52;c;\(big)\u{07}")
        XCTAssertFalse(t.pendingEvents.contains { if case .clipboardWrite = $0 { return true }; return false })
        t.feed("\u{1B}]52;c;\(base64("hello"))\u{07}")
        XCTAssertTrue(t.pendingEvents.contains { if case .clipboardWrite("hello") = $0 { return true }; return false })
    }

    func testTitleIsSanitized() {
        let t = Terminal(cols: 20, rows: 5)
        t.feed("\u{1B}]2;safe\u{202E}txt.exe\u{08}\u{7F}\u{9B}31m!\u{07}")
        XCTAssertEqual(t.title, "safetxt.exe31m!")
        t.feed("\u{1B}]2;\(String(repeating: "x", count: 5000))\u{07}")
        XCTAssertEqual(t.title.count, Terminal.maxTitleLength)
    }

    // MARK: Paste and drag-and-drop

    /// Single-pass removal of ESC[201~ could be defeated: "ESC[20" + "ESC[201~" + "1~" re-forms
    /// the end marker. Sanitizing removes every ESC, so nothing can end the paste early.
    func testPasteCannotEndBracketedPaste() {
        let evil = "echo hi\u{1B}[20\u{1B}[201~1~\nrm -rf ~\n"
        let clean = InputSafety.sanitizePaste(evil)
        XCTAssertFalse(clean.unicodeScalars.contains("\u{1B}"))
        XCTAssertFalse(clean.contains("[201~") && clean.contains("\u{1B}"))
        XCTAssertEqual(InputSafety.sanitizePaste("a\tb\r\nc\u{03}\u{9B}d"), "a\tb\r\ncd")
    }

    /// Quoted names must reach the shell as exactly one literal word, whatever they contain.
    func testShellQuoteRoundTripsInRealShells() throws {
        let names = [
            "/tmp/plain.txt", "/tmp/with space", "/tmp/it's", "/tmp/$(touch /tmp/pwned)", "/tmp/`id`",
            "/tmp/a;b&c|d", "/tmp/new\nline; touch /tmp/pwned\n", "/tmp/cr\rx", "/tmp/esc\u{1B}[201~x",
            "/tmp/back\\slash", "/tmp/tab\there", "/tmp/ünïcödé 日本", "/tmp/!bang", "/tmp/*glob?", "/tmp/~tilde", "-n",
        ]
        let marker = "/tmp/pwned"
        unlink(marker)
        for shell in ["/bin/zsh", "/bin/bash"] {
            for name in names {
                let q = InputSafety.shellQuote(name)
                XCTAssertFalse(q.unicodeScalars.contains { $0.value < 0x20 }, "control character survives quoting: \(q.debugDescription)")
                let out = try SecurityTests.run(shell, ["-c", "printf '%s' \(q)"])
                XCTAssertEqual(out, name, "\(shell) round trip of \(name.debugDescription) via \(q.debugDescription)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "a quoted name executed a command")
        XCTAssertEqual(InputSafety.shellQuote("/Users/me/file.txt"), "/Users/me/file.txt", "plain paths stay readable")
    }

    // MARK: Second review

    /// Found by the grammar fuzzer: with scrollback present, `a=d,d=y` computed `top + y` with an
    /// unclamped y and overflowed. Every Kitty key is now clamped when parsed.
    func testKittyDeleteWithHugeCoordinates() {
        let t = Terminal(cols: 10, rows: 3, scrollback: 50)
        t.feed(String(repeating: "line\r\n", count: 20))   // scrollback, so the screen top is > 0
        t.feed("\u{1B}_Ga=T,f=24,s=1,v=1;AAAA\u{1B}\\")
        for d in ["y", "Y", "x", "X", "p", "P"] {
            for v in ["9223372036854775807", "-9223372036854775808"] {
                t.feed("\u{1B}_Ga=d,d=\(d),x=\(v),y=\(v);\u{1B}\\")
            }
        }
        XCTAssertEqual(ImageStore.key([UInt8(ascii: "y"): "9223372036854775807"], "y", 0), 1 << 40)
        XCTAssertEqual(ImageStore.key([UInt8(ascii: "y"): "-9223372036854775808"], "y", 0), -(1 << 40))
        XCTAssertEqual(ImageStore.key([UInt8(ascii: "i"): "4294967295"], "i", 0), 4294967295, "32-bit ids survive")
    }

    /// Placements are capped (each costs work every frame) and inserted in z order without a full
    /// re-sort per placement (which made many placements quadratic).
    func testPlacementsAreBoundedAndOrdered() {
        let t = Terminal(cols: 20, rows: 5)
        t.feed("\u{1B}_Ga=t,f=24,s=1,v=1,i=1;AAAA\u{1B}\\")
        let start = Date()
        var s = ""
        for i in 0..<(ImageStore.maxPlacements + 500) { s += "\u{1B}_Ga=p,i=1,p=\(i + 1),z=\(i % 7 - 3),q=2\u{1B}\\" }
        t.feed(s)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(t.images.placements.count, ImageStore.maxPlacements)
        let zs = t.images.placements.map(\.z)
        XCTAssertEqual(zs, zs.sorted(), "placements stay sorted by z")
        XCTAssertNotNil(t.images.images[1], "an explicitly numbered image survives losing placements")
    }

    /// Once the grapheme table is full, new clusters aren't formed, and existing ids keep meaning
    /// what they meant (a reset used to make on-screen text change).
    func testGraphemeTableStopsGrowingWithoutReset() {
        let table = GraphemeTable()
        let first = table.intern([0x65, 0x301])
        for i in 0..<(GraphemeTable.maxClusters + 10) { _ = table.intern([0x61, UInt32(0x300 + i % 0x70), UInt32(i)]) }
        XCTAssertEqual(table.clusters.count, GraphemeTable.maxClusters)
        XCTAssertNil(table.intern([0x62, 0x302, 0x303]))
        XCTAssertEqual(first.map { table.scalars($0) }, [0x65, 0x301], "existing clusters unchanged")
    }

    func testRemoteWorkingDirectoryIsIgnored() {
        let t = Terminal(cols: 20, rows: 5)
        t.feed("\u{1B}]7;file://some-remote-server.example/etc\u{07}")
        XCTAssertNil(t.workingDirectory, "a remote host's directory must not become the local cwd")
        t.feed("\u{1B}]7;file://localhost/tmp\u{07}")
        XCTAssertEqual(t.workingDirectory, "/tmp")
        t.feed("\u{1B}]7;file:///private/tmp\u{07}")
        XCTAssertEqual(t.workingDirectory, "/private/tmp")
        let host = ProcessInfo.processInfo.hostName
        t.feed("\u{1B}]7;file://\(host)/usr\u{07}")
        XCTAssertEqual(t.workingDirectory, "/usr")
        t.feed("\u{1B}]7;file://localhost/tmp/a%1B%5D2%3Bx\u{07}")
        XCTAssertEqual(t.workingDirectory, "/usr", "paths with control characters are rejected")
        t.feed("\u{1B}]1337;CurrentDir=/tmp/\u{202E}gpj.exe\u{07}")
        XCTAssertEqual(t.workingDirectory, "/usr", "bidi overrides are rejected")
        t.feed("\u{1B}]1337;CurrentDir=relative/path\u{07}")
        XCTAssertEqual(t.workingDirectory, "/usr")
    }

    /// URL detection under the pointer only looks at nearby rows, however long the soft-wrapped line.
    func testLinkDetectionIsBoundedOnHugeWrappedLines() {
        let t = Terminal(cols: 50, rows: 10, scrollback: 10_000)
        t.feed(String(repeating: "x", count: 50 * 9_000) + " see https://example.com/page here")
        let g = t.grid
        let urlRow = g.dropped + g.count - 1
        let start = Date()
        var found: String?
        for col in 0..<50 { if let l = t.link(at: GridPoint(line: urlRow, col: col)) { found = l.url; break } }
        XCTAssertEqual(found, "https://example.com/page")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "link lookups scanned the whole wrapped line")
    }

    /// The bash integration used to print $PWD raw in OSC 7, so a directory named with BEL/ESC
    /// injected terminal commands on every prompt.
    func testBashIntegrationEscapesDirectoryNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Sources/vitterm/ShellIntegration/bash/vitterm.bash").path
        let dir = NSTemporaryDirectory() + "evil\u{07}\u{1B}]52;c;aGk=\u{07}x \u{1B}"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["--norc", "--noprofile", "-c", "source \"$1\"; __vitterm_prompt", "bash", script]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // The local host name, so the path is decoded and then rejected for its control characters.
        p.environment = ["PATH": "/usr/bin:/bin", "HOSTNAME": ProcessInfo.processInfo.hostName]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // Exactly three sequences (133;D, 7, 133;A), each ESC ] ... BEL, and nothing else.
        XCTAssertEqual(out.filter { $0 == "\u{1B}" }.count, 3, out.debugDescription)
        XCTAssertEqual(out.filter { $0 == "\u{07}" }.count, 3, out.debugDescription)
        let t = Terminal(cols: 40, rows: 3)
        t.feed(out)
        XCTAssertFalse(t.pendingEvents.contains { if case .clipboardWrite = $0 { return true }; return false })
        XCTAssertEqual(t.workingDirectory.map { URL(fileURLWithPath: $0).standardized.path }, nil,
                       "the decoded path has control characters, so it is rejected rather than used")
    }

    // MARK: Helpers

    static func run(_ exe: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// zlib (RFC 1950) stream: header, raw deflate, and a placeholder checksum (not verified).
    static func zlib(_ data: Data) -> Data? {
        let cap = data.count + 1024
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return nil }
        return Data([0x78, 0x9C]) + out.prefix(n) + Data([0, 0, 0, 0])
    }

    static func png1x1() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg==")!
    }
}
