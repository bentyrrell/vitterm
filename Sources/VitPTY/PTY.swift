import Foundation
import Darwin

public struct PTYError: Error, CustomStringConvertible {
    public let description: String
}

/// A child process attached to a pseudo-terminal. Output is read on a dedicated thread.
public final class PTYProcess: @unchecked Sendable {
    public let fd: Int32
    public let pid: pid_t
    private let writeQueue = DispatchQueue(label: "vitterm.pty.write")
    /// Bytes of terminal replies queued but not yet written.
    private var pendingReplyBytes = 0
    private let replyLock = NSLock()
    /// Most reply bytes allowed in flight. A program that floods queries (say `cat` of a file full of
    /// `ESC [ c`) without reading its input would otherwise queue replies without limit, since the
    /// write blocks once the terminal's input buffer is full.
    public static let maxPendingReplyBytes = 64 * 1024
    private var readThread: Thread?
    private let exitLock = NSLock()
    private var exited = false

    /// Called on the read thread with each chunk of output.
    public var onOutput: ((UnsafeBufferPointer<UInt8>) -> Void)?
    /// Called once on the read thread when the child exits, with its wait status.
    public var onExit: ((Int32) -> Void)?

    /// Spawn `executable` with `args` (args[0] is argv[0]) in a new session on a fresh PTY.
    public init(executable: String, args: [String], environment: [String: String], cwd: String?,
                cols: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) throws {
        var ws = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
                         ws_xpixel: UInt16(clamping: pixelWidth), ws_ypixel: UInt16(clamping: pixelHeight))

        // Everything the child needs is prepared before fork: only async-signal-safe calls after.
        let argv = args.map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let exe = strdup(executable)
        let dir = cwd.map { strdup($0) }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
            free(exe)
            dir.map { free($0) }
        }

        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &ws)
        if pid < 0 { throw PTYError(description: "forkpty failed: \(String(cString: strerror(errno)))") }
        if pid == 0 {
            // Child.
            if let dir { _ = chdir(dir) }
            // Reset signal dispositions the parent may have changed.
            signal(SIGCHLD, SIG_DFL); signal(SIGPIPE, SIG_DFL); signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL); signal(SIGTERM, SIG_DFL); signal(SIGHUP, SIG_DFL)
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)
            argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in
                    _ = execve(exe, a.baseAddress, e.baseAddress)
                }
            }
            _exit(127)
        }
        self.pid = pid
        self.fd = master
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        close(fd)
    }

    /// Start reading. The read thread keeps this object alive until the child exits (so dropping the
    /// last reference early can't leave an unreaped child or a missed exit callback).
    public func start() {
        let t = Thread { self.readLoop() }
        t.name = "vitterm.pty.read"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        readThread = t
        t.start()
    }

    private func readLoop() {
        let cap = 1 << 17
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { buf.deallocate() }
        let fd = self.fd
        while true {
            let n = read(fd, buf, cap)
            if n > 0 {
                onOutput?(UnsafeBufferPointer(start: buf, count: n))
            } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                break // EOF or EIO: child side closed.
            }
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        exitLock.lock()
        let first = !exited
        exited = true
        exitLock.unlock()
        if first { onExit?(status) }
    }

    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [fd] in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var off = 0
                while off < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if n > 0 { off += n }
                    else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                        if errno == EAGAIN { usleep(1000) }
                        continue
                    } else { break }
                }
            }
        }
    }

    public func write(_ bytes: [UInt8]) { write(Data(bytes)) }

    /// Write a terminal reply (answer to a query). Dropped if too many replies are already waiting:
    /// replies are generated by program output, so they must not grow memory without bound.
    /// Returns false if dropped.
    @discardableResult
    public func writeReply(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return true }
        replyLock.lock()
        // A single large reply (an allowed OSC 52 clipboard read) still goes out when nothing is waiting.
        guard pendingReplyBytes == 0 || pendingReplyBytes + bytes.count <= PTYProcess.maxPendingReplyBytes else { replyLock.unlock(); return false }
        pendingReplyBytes += bytes.count
        replyLock.unlock()
        let n = bytes.count
        write(Data(bytes))
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.replyLock.lock(); self.pendingReplyBytes -= n; self.replyLock.unlock()
        }
        return true
    }
    public func write(_ s: String) { write(Data(s.utf8)) }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        var ws = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols),
                         ws_xpixel: UInt16(clamping: pixelWidth), ws_ypixel: UInt16(clamping: pixelHeight))
        _ = ioctl(fd, TIOCSWINSZ, &ws)
    }

    /// Send SIGHUP to the session (like closing a terminal window).
    public func hangup() {
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    /// The foreground process group's leader PID.
    public var foregroundPID: pid_t? {
        let pg = tcgetpgrp(fd)
        return pg > 0 ? pg : nil
    }

    /// True when something other than the shell itself is running in the foreground.
    public var hasRunningChild: Bool {
        guard let fg = foregroundPID else { return false }
        return fg != pid
    }

    /// Name of the foreground process, e.g. "vim".
    /// True when the terminal is in canonical mode with echo off: a password prompt (full-screen
    /// programs turn off canonical mode too).
    public var isPasswordPrompt: Bool {
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        return t.c_lflag & tcflag_t(ECHO) == 0 && t.c_lflag & tcflag_t(ICANON) != 0
    }

    public var foregroundProcessName: String? {
        guard let p = foregroundPID else { return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        let n = proc_name(p, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Current working directory of the foreground process (fallback when OSC 7 isn't available).
    public var foregroundCWD: String? {
        guard let p = foregroundPID ?? Optional(pid) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(p, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}

/// Helpers for launching the user's shell.
public enum Shell {
    /// The user's login shell from the password database (falls back to $SHELL, then zsh).
    public static var userShell: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let s = String(cString: sh)
            if !s.isEmpty { return s }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Environment for child processes.
    public static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for k in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "TERMINFO", "VTE_VERSION",
                  "KITTY_WINDOW_ID", "KITTY_PID", "ALACRITTY_SOCKET", "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR",
                  "XPC_SERVICE_NAME", "__CFBundleIdentifier"] {
            env[k] = nil
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "vitterm"
        env["TERM_PROGRAM_VERSION"] = "0.1.0"
        if env["LANG"] == nil && env["LC_ALL"] == nil && env["LC_CTYPE"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        if let pw = getpwuid(getuid()) {
            if env["USER"] == nil { env["USER"] = String(cString: pw.pointee.pw_name) }
            if env["HOME"] == nil { env["HOME"] = String(cString: pw.pointee.pw_dir) }
        }
        env["SHELL"] = env["SHELL"] ?? userShell
        for (k, v) in extra { env[k] = v }
        return env
    }
}
