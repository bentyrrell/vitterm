import AppKit
import QuartzCore
import UserNotifications
import VitCore
import VitPTY
import VitRender
import VitConfig

/// One terminal pane: owns the emulator, the PTY and the Metal renderer.
final class SurfaceView: NSView, CALayerDelegate {
    let terminal: Terminal
    private(set) var pty: PTYProcess?
    var renderer: TerminalRenderer
    weak var controller: TabController?

    var config: Config { AppDelegate.shared.config }
    var theme: Theme = Theme(name: "")
    var fontSize: Double
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var link: CADisplayLink?
    private var idleFrames = 0
    var needsRender = true

    // State shared with the PTY thread (guarded by terminal.lock).
    private var wakePending = false
    /// True while the display link is running. Its tick drains PTY output, so the PTY thread
    /// doesn't need to wake the main thread for every read.
    private var linkActive = false
    /// Output arrived since the main thread last processed it (events, activity, search).
    private var outputPending = false

    // UI state.
    var selection: Selection?
    var overlay = RenderOverlay()
    var title = "vitterm"
    var cwd: String?
    var broadcastEnabled = false { didSet { requestRender() } }
    var exited = false
    var hasFocus: Bool { window?.firstResponder === self && window?.isKeyWindow == true }
    var markedText = NSMutableAttributedString()
    var keyDownEvent: NSEvent?
    var keyTextHandled = false
    private var blinkVisible = true
    private var blinkTimer: Timer?
    private var flashUntil: CFTimeInterval = 0
    var scrollAccumulator: CGFloat = 0
    var hoveredLink: (url: String, ranges: [(line: Int, cols: ClosedRange<Int>)])?
    var searchBar: SearchBar?
    var searchQuery = ""
    var searchRegex = false
    var searchVersion: UInt64 = 0
    var autoscrollTimer: Timer?
    var lastMouseCell: GridPoint?
    var mouseDownWasSelection = false
    var selectionWordAnchor: (GridPoint, GridPoint)?
    var searchRefreshScheduled = false

    /// Called when the shell exits.
    var onExit: ((SurfaceView) -> Void)?

    init(config: Config, workingDirectory: String?, command: String? = nil) {
        fontSize = config.fontSize
        terminal = Terminal(cols: config.windowColumns, rows: config.windowRows, scrollback: config.scrollbackLines)
        StartupTrace.mark("terminal created")
        renderer = TerminalRenderer(spec: SurfaceView.fontSpec(config, size: config.fontSize), scale: NSScreen.main?.backingScaleFactor ?? 2)
        StartupTrace.mark("renderer created (Metal + fonts)")
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        applyConfig(config, initial: true)
        startProcess(workingDirectory: workingDirectory, command: command)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        blinkTimer?.invalidate()
        link?.invalidate()
        pty?.hangup()
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        renderer.configure(layer: l)
        l.delegate = self
        l.needsDisplayOnBoundsChange = false
        l.contentsGravity = .topLeft
        return l
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { config.backgroundOpacity >= 1 }

    static func fontSpec(_ c: Config, size: Double) -> FontSpec {
        FontSpec(family: c.fontFamily, boldFamily: c.fontFamilyBold, italicFamily: c.fontFamilyItalic, size: CGFloat(size),
                 features: c.fontFeatures, ligatures: c.fontLigatures, thicken: c.fontThicken,
                 adjustWidth: c.adjustCellWidth, adjustHeight: c.adjustCellHeight)
    }

    var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }
    var paddingX: CGFloat { CGFloat(config.windowPaddingX) * scale }
    var paddingY: CGFloat { CGFloat(config.windowPaddingY) * scale }

    // MARK: Config

    func applyConfig(_ c: Config, initial: Bool = false) {
        let systemDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        theme = c.resolvedTheme(systemDark: systemDark)
        terminal.lock.withLock {
            terminal.applyColors(ansi: theme.palette, foreground: theme.foreground, background: theme.background, cursor: theme.cursor)
            terminal.allowClipboardRead = c.clipboardRead
            terminal.allowImageFiles = c.imageFileTransfer
            terminal.primary.maxScrollback = c.scrollbackLines
            terminal.grid.touchAll()
        }
        if !initial {
            fontSize = c.fontSize
            renderer.setFont(SurfaceView.fontSpec(c, size: fontSize), scale: scale)
            metalLayer.isOpaque = c.backgroundOpacity >= 1
            updateGridSize()
        }
        setupBlinkTimer()
        requestRender()
    }

    func setFontSize(_ size: Double) {
        fontSize = min(max(size, 5), 96)
        renderer.setFont(SurfaceView.fontSpec(config, size: fontSize), scale: scale)
        updateGridSize()
        requestRender()
    }

    // MARK: Process

    private func startProcess(workingDirectory: String?, command: String?) {
        let shellPath = config.shell ?? Shell.userShell
        var extraEnv: [String: String] = [:]
        var args: [String]
        var exe: String
        if let command, !command.isEmpty {
            exe = "/bin/sh"
            args = ["/bin/sh", "-c", command]
        } else if shellPath.contains(" ") && !FileManager.default.isExecutableFile(atPath: shellPath) {
            exe = "/bin/sh"
            args = ["/bin/sh", "-c", "exec " + shellPath]
        } else {
            exe = shellPath
            // A leading dash makes the shell a login shell, like Terminal.app.
            args = ["-" + (shellPath as NSString).lastPathComponent]
            if config.shellIntegration {
                ShellIntegration.prepare(shell: shellPath, env: &extraEnv)
            }
        }
        let env = Shell.environment(extra: extraEnv)
        var dir = workingDirectory
        if dir == nil || !FileManager.default.fileExists(atPath: dir!) { dir = NSHomeDirectory() }
        cwd = dir
        do {
            let p = try PTYProcess(executable: exe, args: args, environment: env, cwd: dir,
                                   cols: terminal.cols, rows: terminal.rows)
            pty = p
            p.onOutput = { [weak self] data in self?.ptyOutput(data) }
            p.onExit = { [weak self] status in
                DispatchQueue.main.async { self?.processExited(status) }
            }
            p.start()
        } catch {
            terminal.lock.withLock { terminal.feed("vitterm: failed to start shell: \(error)\r\n") }
        }
    }

    // Latency probe (VITTERM_DEBUG_LATENCY=<file>): time from output arriving after an idle period
    // to the frame showing it being presented. Guarded by the terminal lock.
    static let latencyLog = DebugSnapshot.hooksEnabled ? ProcessInfo.processInfo.environment["VITTERM_DEBUG_LATENCY"] : nil
    static let startupProbe = ProcessInfo.processInfo.environment["VITTERM_DEBUG_STARTUP"] != nil
    nonisolated(unsafe) static var firstFrameLogged = false
    static let idleRenderDisabled = ProcessInfo.processInfo.environment["VITTERM_DISABLE_IDLE_RENDER"] != nil
    private var probeOutputTime: CFTimeInterval = 0
    private var probeLastOutput: CFTimeInterval = 0

    /// PTY read thread.
    private func ptyOutput(_ data: UnsafeBufferPointer<UInt8>) {
        let t = terminal
        t.lock.lock()
        if SurfaceView.latencyLog != nil {
            let now = CACurrentMediaTime()
            if now - probeLastOutput > 0.1 { probeOutputTime = now }
            probeLastOutput = now
        }
        t.imageWorkNanos = 0
        t.feed(data)
        let imageWork = t.imageWorkNanos
        let reply = t.pendingOutput
        if !reply.isEmpty { t.pendingOutput.removeAll(keepingCapacity: true) }
        outputPending = true
        let wake = !wakePending && !linkActive
        if wake { wakePending = true }
        t.lock.unlock()
        if !reply.isEmpty { pty?.writeReply(reply) }
        if wake {
            DispatchQueue.main.async { [weak self] in self?.wakeFromPTY() }
        }
        // Image decoding holds the terminal lock (a crafted 500 KB PNG can take ~100 ms), and the
        // unfair lock lets this thread take it straight back for the next read. After expensive
        // decodes, pause for as long as the decode took (unlocked, capped) so drawing and input
        // always get at least half the time. Text output never takes this path.
        if imageWork > 5_000_000 { usleep(useconds_t(min(imageWork, 100_000_000) / 1000)) }
    }

    private func wakeFromPTY() {
        terminal.lock.withLock { wakePending = false }
        guard drainOutput() else { return }
        renderNowIfIdle()
    }

    /// Process output that arrived since the last call: terminal events, tab activity, search.
    /// Returns false if there was none.
    @discardableResult
    private func drainOutput() -> Bool {
        var events: [TerminalEvent] = []
        let had = terminal.lock.withLock { () -> Bool in
            guard outputPending else { return false }
            outputPending = false
            if !terminal.pendingEvents.isEmpty {
                events = terminal.pendingEvents
                terminal.pendingEvents.removeAll()
            }
            return true
        }
        guard had else { return false }
        for e in events { handle(event: e) }
        updatePasswordPrompt()
        controller?.noteActivity()
        if !searchQuery.isEmpty { scheduleSearchRefresh() }
        return true
    }

    private func replyWithClipboard() {
        let s = NSPasteboard.general.string(forType: .string) ?? ""
        terminal.lock.withLock { terminal.replyClipboard(s) }
        flushReplies()
    }

    private var clipboardReadAskPending = false

    /// `clipboard-read = ask`: confirm before a program reads the clipboard.
    private func askClipboardRead() {
        guard let window, !clipboardReadAskPending else { return }
        clipboardReadAskPending = true
        let alert = NSAlert()
        alert.messageText = "Allow the program to read the clipboard?"
        alert.informativeText = "The program running in this pane asked for the contents of your clipboard."
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        alert.beginSheetModal(for: window) { [weak self] r in
            self?.clipboardReadAskPending = false
            if r == .alertSecondButtonReturn { self?.replyWithClipboard() }
        }
    }

    static func setClipboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private var clipboardAskPending = false

    /// `clipboard-write = ask`: confirm before a program replaces the clipboard.
    private func askClipboardWrite(_ s: String) {
        guard let window, !clipboardAskPending else { return }
        clipboardAskPending = true
        let alert = NSAlert()
        alert.messageText = "Allow the program to copy to the clipboard?"
        let preview = s.count > 400 ? String(s.prefix(400)) + "…" : s
        alert.informativeText = preview
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Don’t Copy")
        alert.beginSheetModal(for: window) { [weak self] r in
            self?.clipboardAskPending = false
            if r == .alertFirstButtonReturn { SurfaceView.setClipboard(s) }
        }
    }

    /// Turn secure keyboard entry on while this (focused) pane is at a password prompt.
    func updatePasswordPrompt() {
        guard hasFocus else { return }
        SecureInput.shared.passwordPrompt = pty?.isPasswordPrompt ?? false
    }

    private func handle(event: TerminalEvent) {
        switch event {
        case .title(let t):
            title = t.isEmpty ? "vitterm" : t
            controller?.surfaceTitleChanged(self)
        case .bell:
            if config.bellVisual { flashUntil = CACurrentMediaTime() + 0.15; requestRender() }
            if config.bellAudible { NSSound.beep() }
            controller?.noteActivity(bell: true)
            if !(window?.isKeyWindow ?? false) { NSApp.requestUserAttention(.informationalRequest) }
        case .workingDirectory(let d):
            cwd = d
            controller?.surfaceTitleChanged(self)
        case .clipboardWrite(let s):
            switch config.clipboardWrite {
            case .allow: SurfaceView.setClipboard(s)
            case .deny: break
            case .ask: askClipboardWrite(s)
            }
        case .clipboardRead:
            if config.clipboardReadAsk { askClipboardRead() } else { replyWithClipboard() }
        case .notification(let t, let body):
            postNotification(title: t.isEmpty ? title : t, body: body)
        case .colorsChanged, .cursorShapeChanged:
            requestRender()
        case .progress:
            break
        }
    }

    private var lastNotification: CFTimeInterval = 0

    /// Notifications come from untrusted output: off with `desktop-notifications = false`, cleaned
    /// of control/bidi characters and capped, and limited to one per second per pane so a program
    /// can't flood Notification Center.
    private func postNotification(title rawTitle: String, body rawBody: String) {
        guard config.desktopNotifications, Bundle.main.bundleIdentifier != nil else { return }
        let now = CACurrentMediaTime()
        guard now - lastNotification >= 1 else { return }
        lastNotification = now
        let title = String(Terminal.sanitizeTitle(rawTitle).prefix(256))
        let body = String(Terminal.sanitizeTitle(rawBody).prefix(1024))
        guard !title.isEmpty || !body.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func flushReplies() {
        let reply: [UInt8] = terminal.lock.withLock {
            defer { terminal.pendingOutput.removeAll() }
            return terminal.pendingOutput
        }
        if !reply.isEmpty { pty?.writeReply(reply) }
    }

    private func processExited(_ status: Int32) {
        exited = true
        onExit?(self)
    }

    /// Ask the user before closing if something is running.
    var needsCloseConfirmation: Bool {
        guard config.confirmClose, !exited, let p = pty else { return false }
        return p.hasRunningChild
    }

    func terminate() {
        pty?.hangup()
        link?.invalidate()
        link = nil
        blinkTimer?.invalidate()
    }

    // MARK: Writing input

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pty?.write(bytes)
    }

    func write(_ s: String) { write(Array(s.utf8)) }

    // MARK: Layout & rendering

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let old = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged(_:)),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: newWindow)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        metalLayer.contentsScale = window.backingScaleFactor
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.add(to: .main, forMode: .common)
            terminal.lock.withLock { linkActive = true }
            link = l
        }
        renderer.setFont(SurfaceView.fontSpec(config, size: fontSize), scale: window.backingScaleFactor)
        updateGridSize()
        requestRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }
        metalLayer.contentsScale = window.backingScaleFactor
        renderer.setFont(SurfaceView.fontSpec(config, size: fontSize), scale: window.backingScaleFactor)
        updateGridSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateGridSize()
        if inLiveResize || window?.inLiveResize == true {
            renderNow(synchronous: true)
        }
    }

    /// Recompute rows/columns from the view size and propagate to the terminal and PTY.
    func updateGridSize() {
        let s = scale
        let w = bounds.width * s, h = bounds.height * s
        metalLayer.drawableSize = CGSize(width: max(1, w), height: max(1, h))
        let cw = CGFloat(renderer.cellWidth), ch = CGFloat(renderer.cellHeight)
        let cols = max(2, Int((w - 2 * paddingX) / cw))
        let rows = max(1, Int((h - 2 * paddingY) / ch))
        var changed = false
        terminal.lock.withLock {
            terminal.cellPixelWidth = Int(cw)
            terminal.cellPixelHeight = Int(ch)
            if terminal.cols != cols || terminal.rows != rows {
                terminal.resize(cols: cols, rows: rows)
                changed = true
            }
        }
        if changed {
            pty?.resize(cols: cols, rows: rows, pixelWidth: Int(cw) * cols, pixelHeight: Int(ch) * rows)
            if !searchQuery.isEmpty { scheduleSearchRefresh() }
        }
        requestRender()
    }

    /// Grid size in cells (cols, rows) that would fit `size` points.
    func cellSizeInPoints() -> NSSize {
        NSSize(width: CGFloat(renderer.cellWidth) / scale, height: CGFloat(renderer.cellHeight) / scale)
    }

    func requestRender() {
        needsRender = true
        idleFrames = 0
        startLink()
    }

    private func startLink() {
        guard let link, link.isPaused else { return }
        terminal.lock.withLock { linkActive = true }
        link.isPaused = false
    }

    /// Pause the display link unless output arrived that it still has to pick up. Decided under
    /// the lock, so output arriving afterwards always wakes the main thread instead.
    private func stopLinkIfQuiet(force: Bool = false) {
        guard let link, !link.isPaused else { return }
        let quiet = terminal.lock.withLock { () -> Bool in
            if !force && (terminal.dirty || outputPending) { return false }
            linkActive = false
            return true
        }
        if quiet {
            link.isPaused = true
            // Output may have arrived (without a wake) while the link was still marked active.
            if force { DispatchQueue.main.async { [weak self] in self?.wakeFromPTY() } }
        }
    }

    /// Whether drawing would be seen: in a window that isn't fully covered or minimized.
    var isVisibleForRendering: Bool {
        guard let w = window else { return false }
        return w.occlusionState.contains(.visible)
    }

    /// Lower latency for output that arrives while idle (typically a keystroke echo): rather than
    /// unpausing the display link and waiting for its next callback, render right away so the frame
    /// is presented at the very next vsync. While output keeps streaming, the running display link
    /// coalesces it to one frame per vsync as usual.
    func renderNowIfIdle() {
        guard !SurfaceView.idleRenderDisabled, let link, link.isPaused, isVisibleForRendering, bounds.width > 0 else {
            requestRender()
            return
        }
        let syncHold = terminal.lock.withLock { () -> Bool in
            if terminal.modes.synchronizedOutput { return true }
            terminal.dirty = false
            return false
        }
        if syncHold { requestRender(); return }
        renderNow(synchronous: false)
        idleFrames = 0
        startLink() // keep running briefly to pick up any follow-up output
    }

    @objc private func occlusionChanged(_ n: Notification) {
        if isVisibleForRendering { requestRender() }
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard isVisibleForRendering else {
            // Covered or minimized: don't render (content stays dirty and is drawn when visible).
            stopLinkIfQuiet(force: true)
            return
        }
        drainOutput()
        var dirty = false
        var syncHold = false
        terminal.lock.withLock {
            dirty = terminal.dirty
            terminal.dirty = false
            syncHold = terminal.modes.synchronizedOutput
        }
        if syncHold {
            // Synchronized output (mode 2026): hold frames briefly while the app is mid-update.
            if syncStart == 0 { syncStart = CACurrentMediaTime() }
            if CACurrentMediaTime() - syncStart < 0.5 {
                if dirty { terminal.lock.withLock { terminal.dirty = true } }
                return
            }
        } else {
            syncStart = 0
        }
        updateStreamingThrottle(l, outputChanged: dirty)
        let flashing = flashUntil > CACurrentMediaTime()
        if dirty || needsRender || flashing || flashWasOn || renderer.isAnimating {
            flashWasOn = flashing
            renderNow(synchronous: false)
            idleFrames = 0
        } else {
            idleFrames += 1
            if idleFrames > 3 { stopLinkIfQuiet() }
        }
    }
    private var syncStart: CFTimeInterval = 0
    private var flashWasOn = false

    /// Consecutive frames in which program output changed the screen.
    private var streamingFrames = 0
    private var streamingThrottled = false
    /// While output streams continuously, frames are capped at 60 fps: every frame shows lines that
    /// were never shaped before, and on 100-120 Hz displays drawing at the full rate roughly
    /// doubles the CPU spent on text nobody can read at that speed. Interactive frames (typing on
    /// a quiet screen, scrolling, the cursor trail) keep the display's full rate.
    static let streamingThrottleAfter = 6

    private func updateStreamingThrottle(_ l: CADisplayLink, outputChanged: Bool) {
        streamingFrames = outputChanged ? streamingFrames + 1 : 0
        let throttle = streamingFrames >= SurfaceView.streamingThrottleAfter
        guard throttle != streamingThrottled else { return }
        streamingThrottled = throttle
        l.preferredFrameRateRange = throttle ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60) : .default
    }

    func renderNow(synchronous: Bool) {
        guard window != nil, bounds.width > 0 else { return }
        needsRender = false
        var onPresented: ((CFTimeInterval) -> Void)? = nil
        if let path = SurfaceView.latencyLog {
            let start: CFTimeInterval = terminal.lock.withLock {
                defer { probeOutputTime = 0 }
                return probeOutputTime
            }
            if start > 0 {
                onPresented = { presented in
                    guard presented > 0 else { return }
                    let line = String(format: "%.2f\n", (presented - start) * 1000)
                    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
                    else { FileManager.default.createFile(atPath: path, contents: Data(line.utf8)) }
                }
            }
        }
        if SurfaceView.startupProbe, !SurfaceView.firstFrameLogged {
            SurfaceView.firstFrameLogged = true
            let prev = onPresented
            onPresented = { t in
                prev?(t)
                // Wall-clock time of the first presented frame, for measuring startup from outside.
                print(String(format: "VITTERM_FIRST_FRAME %.4f", Date().timeIntervalSince1970))
                fflush(stdout)
                StartupTrace.mark("first frame presented")
            }
        }
        if !renderer.draw(layer: metalLayer, terminal: terminal, overlay: currentOverlay(), options: currentOptions(),
                          synchronous: synchronous, onPresented: onPresented) {
            needsRender = true
        }
    }

    /// Draw the first frame synchronously, committed with the window's own Core Animation
    /// transaction, so a new window or tab appears with its content instead of flashing empty.
    func renderInitialFrame() {
        guard window != nil, bounds.width > 0 else { return }
        metalLayer.presentsWithTransaction = true
        terminal.lock.withLock { terminal.dirty = false }
        renderNow(synchronous: true)
        metalLayer.presentsWithTransaction = false
    }

    func renderSnapshot() -> CGImage? {
        renderer.renderImage(terminal: terminal, overlay: currentOverlay(), options: currentOptions(), size: metalLayer.drawableSize)
    }

    private func currentOverlay() -> RenderOverlay {
        overlay.selection = selection
        overlay.markedText = markedText.string
        overlay.hoverLink = hoveredLink?.ranges ?? []
        return overlay
    }

    private func currentOptions() -> RenderOptions {
        var o = RenderOptions()
        o.paddingX = paddingX
        o.paddingY = paddingY
        o.focused = hasFocus
        o.cursorStyle = { switch config.cursorStyle { case .block: return .block; case .bar: return .bar; case .underline: return .underline } }()
        let blinkAllowed = terminal.cursorShapeBlinks ?? terminal.modes.cursorBlink ?? config.cursorBlink
        o.cursorBlinkVisible = !blinkAllowed || blinkVisible || !o.focused
        o.selectionBackground = theme.selectionBackground
        o.selectionForeground = theme.selectionForeground
        o.cursorText = theme.cursorText
        o.boldIsBright = config.boldIsBright
        o.backgroundOpacity = config.backgroundOpacity
        if let c = controller, c.hasMultiplePanes, !o.focused || window?.isKeyWindow != true {
            o.dim = c.focusedSurface === self ? 0 : 1 - config.unfocusedSplitOpacity
        }
        if broadcastEnabled { o.broadcastBorder = 0xE8A33D }
        let remaining = flashUntil - CACurrentMediaTime()
        o.flash = remaining > 0 ? 1 : 0
        let c = config
        if c.cursorTrail {
            o.cursorTrail = CursorTrailOptions(color: c.resolvedTrailColor(theme), opacity: Float(c.cursorTrailOpacity),
                                               fastDecay: Double(c.cursorTrailDecayFast) / 1000,
                                               slowDecay: Double(c.cursorTrailDecaySlow) / 1000,
                                               threshold: c.cursorTrailThreshold)
        }
        return o
    }

    // MARK: Cursor blink

    /// The cursor stops blinking (and its timer stops) after this long without keyboard input, so
    /// an idle terminal does no work at all. Typing or refocusing starts it again.
    static let blinkIdleStop: CFTimeInterval = 15
    private var lastBlinkActivity: CFTimeInterval = 0

    private func setupBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        lastBlinkActivity = CACurrentMediaTime()
        let t = Timer(timeInterval: Double(config.cursorBlinkInterval) / 1000, repeats: true) { [weak self] _ in
            self?.blinkTick()
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func blinkTick() {
        let blinks = terminal.lock.withLock { terminal.cursorShapeBlinks ?? terminal.modes.cursorBlink } ?? config.cursorBlink
        guard blinks, hasFocus, CACurrentMediaTime() - lastBlinkActivity < SurfaceView.blinkIdleStop else {
            // Not blinking: leave the cursor solid and stop the timer until input or focus returns.
            blinkTimer?.invalidate()
            blinkTimer = nil
            if !blinkVisible { blinkVisible = true; renderBlink() }
            return
        }
        blinkVisible.toggle()
        renderBlink()
    }

    /// Draw a blink frame directly when nothing else is rendering, without spinning up the display
    /// link (which would run several idle frames before pausing again).
    private func renderBlink() {
        if let link, link.isPaused, isVisibleForRendering, bounds.width > 0 {
            renderNow(synchronous: false)
        } else {
            requestRender()
        }
    }

    func resetBlink() {
        blinkVisible = true
        lastBlinkActivity = CACurrentMediaTime()
        if blinkTimer == nil { setupBlinkTimer() }
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            controller?.surfaceDidFocus(self)
            sendFocus(true)
            resetBlink()
            requestRender()
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            sendFocus(false)
            requestRender()
        }
        return ok
    }

    func windowFocusChanged(_ focused: Bool) {
        if window?.firstResponder === self { sendFocus(focused) }
        if focused { resetBlink() }
        requestRender()
    }

    private func sendFocus(_ focused: Bool) {
        let enabled = terminal.lock.withLock { terminal.modes.focusEvents }
        if enabled { write(focused ? "\u{1B}[I" : "\u{1B}[O") }
    }

    // MARK: Scrolling the viewport

    func scrollViewport(by lines: Int) {
        terminal.lock.withLock {
            guard !terminal.usingAlternate else { return }
            terminal.scrollOffset = min(max(terminal.scrollOffset + lines, 0), terminal.primary.scrollbackCount)
        }
        requestRender()
    }

    func scrollToBottom() {
        terminal.lock.withLock { terminal.scrollOffset = 0 }
        requestRender()
    }

    func scrollTo(absoluteLine: Int) {
        terminal.lock.withLock {
            let g = terminal.grid
            // Put the line roughly a third from the top.
            let screenTopAbs = g.dropped + g.scrollbackCount
            let want = screenTopAbs - absoluteLine + terminal.rows / 3
            terminal.scrollOffset = min(max(want, 0), g.scrollbackCount)
        }
        requestRender()
    }
}
