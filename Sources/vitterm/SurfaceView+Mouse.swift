import AppKit
import UniformTypeIdentifiers
import VitCore

extension SurfaceView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        if hoveredLink != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
    }

    // MARK: Coordinates

    /// Cell (col, viewport row) for a point in view coordinates; may be outside the grid.
    func cellPosition(_ p: NSPoint) -> (col: Int, row: Int) {
        let s = scale
        let x = (p.x * s - paddingX) / CGFloat(renderer.cellWidth)
        let y = (p.y * s - paddingY) / CGFloat(renderer.cellHeight)
        return (Int(x.rounded(.down)), Int(y.rounded(.down)))
    }

    /// For selection: a column boundary rounds to the nearest edge.
    func selectionPoint(_ p: NSPoint) -> GridPoint {
        let s = scale
        let (cols, rows, top) = terminal.lock.withLock { () -> (Int, Int, Int) in
            let g = terminal.grid
            return (terminal.cols, terminal.rows, g.dropped + g.scrollbackCount - terminal.scrollOffset)
        }
        let x = (p.x * s - paddingX) / CGFloat(renderer.cellWidth)
        let row = Int(((p.y * s - paddingY) / CGFloat(renderer.cellHeight)).rounded(.down))
        let col = Int(x.rounded(.down))
        _ = rows
        return GridPoint(line: top + row, col: min(max(col, 0), cols - 1))
    }

    var mouseReporting: Bool {
        terminal.lock.withLock { terminal.modes.mouseTracking != .none }
    }

    // MARK: Mouse reporting

    func reportMouse(_ event: NSEvent, button: Int, press: Bool, motion: Bool = false) -> Bool {
        let (tracking, encoding) = terminal.lock.withLock { (terminal.modes.mouseTracking, terminal.modes.mouseEncoding) }
        guard tracking != .none, !event.modifierFlags.contains(.shift) || button >= 64 else { return false }
        if tracking == .x10 && (!press || motion) { return true }
        if motion && tracking == .normal { return true }
        if motion && tracking == .button && button == 3 { return true }

        let p = convert(event.locationInWindow, from: nil)
        var (col, row) = cellPosition(p)
        let (cols, rows) = (terminal.cols, terminal.rows)
        col = min(max(col, 0), cols - 1)
        row = min(max(row, 0), rows - 1)
        if motion, let last = lastMouseCell, last.col == col, last.line == row, encoding != .sgrPixels { return true }
        lastMouseCell = GridPoint(line: row, col: col)

        var cb = button
        if motion { cb += 32 }
        if tracking != .x10 {
            let f = event.modifierFlags
            if f.contains(.shift) { cb += 4 }
            if f.contains(.option) { cb += 8 }
            if f.contains(.control) { cb += 16 }
        }
        switch encoding {
        case .sgr, .sgrPixels:
            var x = col + 1, y = row + 1
            if encoding == .sgrPixels {
                x = max(0, Int(p.x * scale - paddingX)) + 1
                y = max(0, Int(p.y * scale - paddingY)) + 1
            }
            write("\u{1B}[<\(cb);\(x);\(y)\(press ? "M" : "m")")
        case .x10, .utf8:
            let b = press ? cb : (3 + (motion ? 32 : 0) + (cb & ~3 & ~32 & ~64))
            func enc(_ v: Int) -> [UInt8] {
                let n = v + 32
                if encoding == .utf8 && n >= 128 { return Array(String(UnicodeScalar(UInt32(min(n, 2047)))!).utf8) }
                return [UInt8(min(n, 255))]
            }
            write([0x1B, 0x5B, 0x4D] + enc(b) + enc(col + 1) + enc(row + 1))
        }
        return true
    }

    // MARK: Buttons

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        controller?.surfaceDidFocus(self)
        mouseDownWasSelection = false
        if reportMouse(event, button: 0, press: true) { return }

        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command), let link = linkAt(p) {
            openLink(link.url)
            return
        }
        let gp = selectionPoint(p)
        let alt = terminal.lock.withLock { terminal.usingAlternate }
        switch event.clickCount {
        case 2:
            let (a, b) = terminal.lock.withLock { terminal.wordBounds(at: gp, separators: config.wordSeparators) }
            selection = Selection(anchor: a, head: b, mode: .word, onAlternate: alt)
            selectionWordAnchor = (a, b)
            mouseDownWasSelection = true
        case 3...:
            let (a, b) = terminal.lock.withLock { terminal.lineBounds(at: gp.line) }
            selection = Selection(anchor: a, head: b, mode: .line, onAlternate: alt)
            selectionWordAnchor = (a, b)
            mouseDownWasSelection = true
        default:
            if event.modifierFlags.contains(.shift), var sel = selection {
                sel.head = gp
                selection = sel
                mouseDownWasSelection = true
            } else {
                selection = Selection(anchor: gp, head: gp, mode: event.modifierFlags.contains(.option) ? .block : .character, onAlternate: alt)
            }
        }
        requestRender()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportMouse(event, button: 0, press: true, motion: true) { return }
        updateSelectionDrag(event)
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 0 || p.y > bounds.height {
            startAutoscroll()
        } else {
            autoscrollTimer?.invalidate()
            autoscrollTimer = nil
        }
    }

    func updateSelectionDrag(_ event: NSEvent) {
        guard var sel = selection else { return }
        let gp = selectionPoint(convert(event.locationInWindow, from: nil))
        switch sel.mode {
        case .word, .line:
            guard let (a0, b0) = selectionWordAnchor else { break }
            let (a, b) = terminal.lock.withLock {
                sel.mode == .word ? terminal.wordBounds(at: gp, separators: config.wordSeparators) : terminal.lineBounds(at: gp.line)
            }
            if gp < a0 { sel.anchor = b0; sel.head = a } else { sel.anchor = a0; sel.head = b }
        default:
            sel.head = gp
        }
        if sel != selection {
            selection = sel
            mouseDownWasSelection = true
            requestRender()
        }
    }

    private func startAutoscroll() {
        guard autoscrollTimer == nil else { return }
        autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let w = self.window else { return }
            let p = self.convert(w.mouseLocationOutsideOfEventStream, from: nil)
            if p.y < 0 { self.scrollViewport(by: max(1, Int(-p.y / 10))) }
            else if p.y > self.bounds.height { self.scrollViewport(by: -max(1, Int((p.y - self.bounds.height) / 10))) }
            else { return }
            if let e = NSApp.currentEvent { self.updateSelectionDrag(e) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        if reportMouse(event, button: 0, press: false) { return }
        if let sel = selection, sel.isEmpty && !mouseDownWasSelection {
            selection = nil
            requestRender()
        } else if config.copyOnSelect, selection != nil {
            copy(nil)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportMouse(event, button: 2, press: true) { return }
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportMouse(event, button: 2, press: false) { return }
        super.rightMouseUp(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if reportMouse(event, button: 1, press: true) { return }
        if event.buttonNumber == 2, let sel = selection {
            pasteText(terminal.lock.withLock { terminal.text(of: sel) })
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        _ = reportMouse(event, button: 1, press: false)
    }

    override func rightMouseDragged(with event: NSEvent) { _ = reportMouse(event, button: 2, press: true, motion: true) }
    override func otherMouseDragged(with event: NSEvent) { _ = reportMouse(event, button: 1, press: true, motion: true) }

    override func mouseMoved(with event: NSEvent) {
        let tracking = terminal.lock.withLock { terminal.modes.mouseTracking }
        if tracking == .any && !event.modifierFlags.contains(.shift) {
            _ = reportMouse(event, button: 3, press: true, motion: true)
        }
        updateHover(at: convert(event.locationInWindow, from: nil), mods: event.modifierFlags)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredLink != nil { hoveredLink = nil; requestRender() }
    }

    // MARK: Links

    func linkAt(_ p: NSPoint) -> (url: String, ranges: [(line: Int, cols: ClosedRange<Int>)])? {
        let (col, row) = cellPosition(p)
        guard col >= 0, row >= 0, col < terminal.cols, row < terminal.rows else { return nil }
        return terminal.lock.withLock {
            let g = terminal.grid
            let top = g.dropped + g.scrollbackCount - terminal.scrollOffset
            return terminal.link(at: GridPoint(line: top + row, col: col))
        }
    }

    func updateHover(at p: NSPoint, mods: NSEvent.ModifierFlags) {
        let newLink = mods.contains(.command) ? linkAt(p) : nil
        let changed = (newLink?.url != hoveredLink?.url) || (newLink?.ranges.first?.line != hoveredLink?.ranges.first?.line)
        hoveredLink = newLink
        if changed {
            if newLink != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
            // Show where a link really goes (OSC 8 text can differ from its target).
            toolTip = newLink.map { SurfaceView.displayURL($0.url) }
            requestRender()
        }
    }

    /// Links come from untrusted output (OSC 8 can show one URL and point to another), so only web
    /// and mail links open directly. Local files that could run code, remote file links, and any
    /// other scheme (which hands the URL to another app) are confirmed first.
    func openLink(_ s: String) {
        var str = s
        if !str.contains(":") { str = "https://" + str }
        guard let url = URL(string: str), let scheme = url.scheme?.lowercased() else { return }
        switch scheme {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "file":
            openFileLink(url)
        default:
            confirmOpen(url, message: "Open this link in another app?",
                        detail: "Links using “\(scheme):” are handled by whichever app registered that scheme.")
        }
    }

    private func openFileLink(_ url: URL) {
        if let host = url.host, !host.isEmpty, host != "localhost",
           host.lowercased() != ProcessInfo.processInfo.hostName.lowercased(),
           host.lowercased() != (Host.current().localizedName ?? "").lowercased() {
            confirmOpen(url, message: "Open a file link from another computer?",
                        detail: "The link names host “\(host)”, but the file would be opened on this Mac.")
            return
        }
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return }
        if SurfaceView.fileMayRunCode(path, isDirectory: isDir.boolValue) {
            confirmOpen(url, message: "Open a file that can run code?",
                        detail: "This file is an app, script, installer or other item that may run code when opened.",
                        revealInstead: true)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// A link target for display: control and bidirectional-override characters removed (an RLO
    /// can make "evil.com/moc.elgoog" read as something else), and truncated.
    static func displayURL(_ s: String, limit: Int = 300) -> String {
        let clean = Terminal.sanitizeTitle(s)
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }

    /// Whether opening `path` with its default app might execute something.
    static func fileMayRunCode(_ path: String, isDirectory: Bool) -> Bool {
        if isDirectory { return NSWorkspace.shared.isFilePackage(atPath: path) }
        if FileManager.default.isExecutableFile(atPath: path) { return true }
        let risky: Set<String> = ["command", "tool", "terminal", "sh", "zsh", "bash", "fish", "csh", "py", "rb", "pl",
                                  "scpt", "scptd", "applescript", "workflow", "action", "pkg", "mpkg", "dmg", "app",
                                  "jar", "webloc", "inetloc", "fileloc", "url", "mobileconfig", "plugin", "prefpane"]
        let ext = (path as NSString).pathExtension.lowercased()
        if risky.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext) {
            return type.conforms(to: .executable) || type.conforms(to: .script) || type.conforms(to: .application)
                || type.conforms(to: .applicationBundle) || type.conforms(to: .package) || type.conforms(to: .diskImage)
        }
        return false
    }

    private func confirmOpen(_ url: URL, message: String, detail: String, revealInstead: Bool = false) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail + "\n\n" + SurfaceView.displayURL(url.isFileURL ? url.path : url.absoluteString, limit: 500)
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        if revealInstead { alert.addButton(withTitle: "Show in Finder") }
        alert.beginSheetModal(for: window) { r in
            switch r {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(url)
            case .alertThirdButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
            default: break
            }
        }
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        let cellH = cellSizeInPoints().height
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += delta
            let lines = Int((scrollAccumulator / cellH).rounded(.towardZero))
            scrollAccumulator -= CGFloat(lines) * cellH
            delta = CGFloat(lines)
        } else {
            delta = delta.rounded(delta > 0 ? .up : .down) * 3
        }
        let lines = Int(delta)
        guard lines != 0 else { return }

        let (tracking, alt, altScroll, appCursor) = terminal.lock.withLock {
            (terminal.modes.mouseTracking, terminal.usingAlternate, terminal.modes.alternateScroll, terminal.modes.cursorKeysApp)
        }
        if tracking != .none && !event.modifierFlags.contains(.shift) {
            for _ in 0..<min(abs(lines), 10) { _ = reportMouse(event, button: lines > 0 ? 64 : 65, press: true) }
            return
        }
        if alt && altScroll {
            let seq = lines > 0 ? (appCursor ? "\u{1B}OA" : "\u{1B}[A") : (appCursor ? "\u{1B}OB" : "\u{1B}[B")
            write(String(repeating: seq, count: min(abs(lines), 20)))
            return
        }
        scrollViewport(by: lines)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if mouseReporting && !event.modifierFlags.contains(.shift) { return nil }
        let m = NSMenu()
        let copyItem = m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.isEnabled = selection.map { !$0.isEmpty } ?? false
        m.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Split Right", action: #selector(TerminalWindowController.splitRight(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Split Down", action: #selector(TerminalWindowController.splitDown(_:)), keyEquivalent: "")
        m.addItem(.separator())
        let b = m.addItem(withTitle: "Broadcast Input to This Pane", action: #selector(toggleBroadcastPaneMenu(_:)), keyEquivalent: "")
        b.state = broadcastEnabled ? .on : .off
        m.addItem(withTitle: "Clear", action: #selector(clearMenu(_:)), keyEquivalent: "")
        m.addItem(withTitle: "Reset Terminal", action: #selector(resetMenu(_:)), keyEquivalent: "")
        if let link = linkAt(convert(event.locationInWindow, from: nil)) {
            m.insertItem(.separator(), at: 0)
            let open = NSMenuItem(title: "Open Link", action: #selector(openLinkMenu(_:)), keyEquivalent: "")
            open.representedObject = link.url
            m.insertItem(open, at: 0)
        }
        return m
    }

    @objc func toggleBroadcastPaneMenu(_ sender: Any?) { perform(.toggleBroadcastPane) }
    @objc func clearMenu(_ sender: Any?) { perform(.clearScreen) }
    @objc func resetMenu(_ sender: Any?) { perform(.resetTerminal) }
    @objc func openLinkMenu(_ sender: NSMenuItem) { if let s = sender.representedObject as? String { openLink(s) } }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let text = urls.map { SurfaceView.shellEscape($0.isFileURL ? $0.path : $0.absoluteString) }.joined(separator: " ")
            dispatch(.text(text))
            return true
        }
        if let s = pb.string(forType: .string) {
            pasteText(s)
            return true
        }
        return false
    }
}
