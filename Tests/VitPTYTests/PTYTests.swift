import XCTest
@testable import VitPTY
import VitCore

/// Runs real child processes on real pseudo-terminals.
final class PTYTests: XCTestCase {
    /// Collects output from a PTY process until it exits.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [UInt8] = []
        let exited = XCTestExpectation(description: "process exited")
        var status: Int32 = -1

        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        func append(_ b: UnsafeBufferPointer<UInt8>) { lock.lock(); data.append(contentsOf: b); lock.unlock() }

        /// Wait until `predicate` holds for the output so far (polling), or time out.
        func waitFor(_ predicate: (String) -> Bool, timeout: TimeInterval = 5) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if predicate(text) { return true }
                usleep(10_000)
            }
            return predicate(text)
        }
    }

    func spawn(_ args: [String], env: [String: String] = ["PATH": "/bin:/usr/bin", "LANG": "en_US.UTF-8"],
               cols: Int = 80, rows: Int = 24, cwd: String? = nil) throws -> (PTYProcess, Capture) {
        let p = try PTYProcess(executable: args[0], args: args, environment: env, cwd: cwd, cols: cols, rows: rows)
        let c = Capture()
        p.onOutput = { c.append($0) }
        p.onExit = { st in c.status = st; c.exited.fulfill() }
        p.start()
        return (p, c)
    }

    /// A program that never reads its input (here `sleep`) while the terminal answers its queries:
    /// once the tty input buffer is full, writes block, and replies used to queue without limit.
    func testReplyBacklogIsBounded() throws {
        let (p, c) = try spawn(["/bin/sleep", "10"])
        defer { p.hangup() }
        var accepted = 0, dropped = 0
        let reply = [UInt8](repeating: 0x41, count: 1024)
        for _ in 0..<4096 {   // 4 MB of replies
            if p.writeReply(reply) { accepted += 1 } else { dropped += 1 }
        }
        XCTAssertGreaterThan(dropped, 0, "replies must be dropped once the backlog is full")
        XCTAssertLessThanOrEqual(accepted * reply.count, PTYProcess.maxPendingReplyBytes + 64 * 1024,
                                 "accepted \(accepted) KB of replies")
        _ = c
    }

    /// One reply larger than the backlog limit (an allowed clipboard read) still goes out when
    /// nothing else is waiting.
    func testLargeSingleReplyIsSentWhenIdle() throws {
        let (p, c) = try spawn(["/bin/cat"])
        defer { p.hangup() }
        XCTAssertTrue(p.writeReply([UInt8](repeating: 0x41, count: PTYProcess.maxPendingReplyBytes * 2)))
        _ = c
    }

    func testOutputAndExitStatus() throws {
        let (_, c) = try spawn(["/bin/echo", "hello", "pty"])
        wait(for: [c.exited], timeout: 5)
        // The tty line discipline turns \n into \r\n.
        XCTAssertEqual(c.text, "hello pty\r\n")
        XCTAssertEqual(c.status, 0)
    }

    func testNonZeroExitStatus() throws {
        let (_, c) = try spawn(["/bin/sh", "-c", "exit 3"])
        wait(for: [c.exited], timeout: 5)
        XCTAssertTrue(c.status & 0x7F == 0, "should exit normally")
        XCTAssertEqual((c.status >> 8) & 0xFF, 3)
    }

    func testWindowSizeAndResize() throws {
        let (p, c) = try spawn(["/bin/sh", "-c", "stty size; read x; stty size"], cols: 101, rows: 33)
        XCTAssertTrue(c.waitFor { $0.contains("33 101") }, "initial size, got \(c.text.debugDescription)")
        p.resize(cols: 120, rows: 40, pixelWidth: 0, pixelHeight: 0)
        p.write("\n")
        wait(for: [c.exited], timeout: 5)
        XCTAssertTrue(c.text.contains("40 120"), "after resize, got \(c.text.debugDescription)")
    }

    func testInputIsEchoedAndReadByChild() throws {
        let (p, c) = try spawn(["/bin/cat"])
        p.write("ping\n")
        XCTAssertTrue(c.waitFor { $0.components(separatedBy: "ping").count >= 3 }, "echo + cat output, got \(c.text.debugDescription)")
        p.write([0x04]) // Ctrl-D: EOF
        wait(for: [c.exited], timeout: 5)
        XCTAssertEqual(c.status, 0)
    }

    func testLargeWriteIsDeliveredCompletely() throws {
        // More than the PTY buffer: the write queue must handle partial writes.
        let (p, c) = try spawn(["/bin/sh", "-c", "stty -echo; wc -c"])
        usleep(100_000)
        let payload = String(repeating: "x", count: 200_000) + "\n"
        // Canonical mode limits line length, so send many short lines.
        let lines = payload.chunked(500).joined(separator: "\n") + "\n"
        p.write(lines)
        p.write([0x04])
        wait(for: [c.exited], timeout: 10)
        let n = Int(c.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last?.trimmingCharacters(in: .whitespaces) ?? "")
        XCTAssertEqual(n, lines.utf8.count, "wc -c output: \(c.text.suffix(80).debugDescription)")
    }

    func testHangupTerminatesChild() throws {
        let (p, c) = try spawn(["/bin/sleep", "30"])
        usleep(100_000)
        p.hangup()
        wait(for: [c.exited], timeout: 5)
        XCTAssertEqual(c.status & 0x7F, SIGHUP, "terminated by SIGHUP")
    }

    func testWorkingDirectory() throws {
        // realpath, not URL.resolvingSymlinksInPath (which maps /private/var back to /var).
        let dir = String(cString: realpath(FileManager.default.temporaryDirectory.path, nil))
        let (_, c) = try spawn(["/bin/pwd"], cwd: dir)
        wait(for: [c.exited], timeout: 5)
        XCTAssertEqual(c.text.trimmingCharacters(in: .whitespacesAndNewlines), dir)
    }

    func testShellEnvironment() throws {
        let env = Shell.environment(extra: ["VITTERM_TEST": "1"])
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["TERM_PROGRAM"], "vitterm")
        XCTAssertEqual(env["VITTERM_TEST"], "1")
        XCTAssertNil(env["ITERM_SESSION_ID"])
        XCTAssertNotNil(env["HOME"])
        let (_, c) = try spawn(["/usr/bin/env"], env: env)
        wait(for: [c.exited], timeout: 5)
        XCTAssertTrue(c.text.contains("TERM=xterm-256color"))
        XCTAssertTrue(c.text.contains("VITTERM_TEST=1"))
    }

    func testUserShellIsExecutable() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Shell.userShell), Shell.userShell)
    }

    /// End to end: escape sequences produced by a real program end up as terminal state.
    func testProgramOutputDrivesTerminal() throws {
        let t = Terminal(cols: 40, rows: 5)
        let p = try PTYProcess(executable: "/usr/bin/printf",
                               args: ["printf", "\\033[1;31mred\\033[0m plain\\n\\033]0;my title\\007\\033[2;5Hx中"],
                               environment: ["PATH": "/bin:/usr/bin", "LANG": "en_US.UTF-8"], cwd: nil, cols: 40, rows: 5)
        let done = expectation(description: "exit")
        p.onOutput = { data in t.lock.withLock { t.feed(data) } }
        p.onExit = { _ in done.fulfill() }
        p.start()
        wait(for: [done], timeout: 5)
        t.lock.withLock {
            XCTAssertEqual(t.text(of: t.grid.screenLine(0)), "red plain")
            XCTAssertTrue(t.cell(x: 0, y: 0).flags.contains(.bold))
            XCTAssertEqual(t.cell(x: 0, y: 0).fg, .palette(1))
            XCTAssertEqual(t.cell(x: 4, y: 0).fg, .default)
            XCTAssertEqual(t.title, "my title")
            XCTAssertEqual(t.text(of: t.grid.screenLine(1)), "    x中")
            XCTAssertTrue(t.cell(x: 5, y: 1).flags.contains(.wide))
        }
    }

    /// Spawning many short-lived processes must not leak file descriptors.
    func testNoDescriptorLeak() throws {
        func openFDs() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        let before = openFDs()
        for _ in 0..<30 {
            autoreleasepool {
                let (_, c) = try! spawn(["/usr/bin/true"])
                wait(for: [c.exited], timeout: 5)
            }
        }
        usleep(200_000)
        XCTAssertLessThanOrEqual(openFDs(), before + 2, "file descriptors leaked")
    }
}

private extension String {
    func chunked(_ n: Int) -> [String] {
        var out: [String] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: n, limitedBy: endIndex) ?? endIndex
            out.append(String(self[i..<j]))
            i = j
        }
        return out
    }
}
