import AppKit
import Carbon.HIToolbox
import VitCore
import VitConfig

/// Input that can be fanned out to several panes (broadcast). Each pane encodes it with its own modes.
enum InputEvent {
    case key(KeyInput)
    case text(String)
    case paste(String)
}

extension SurfaceView: NSTextInputClient {
    // MARK: Key events

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        if let action = binding(for: event) {
            perform(action)
            return true
        }
        // Ctrl+key combos that AppKit routes as key equivalents still belong to the terminal.
        if event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command) {
            keyDown(with: event)
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if let action = binding(for: event) {
            perform(action)
            return
        }
        if config.mouseHideWhileTyping { NSCursor.setHiddenUntilMouseMoves(true) }
        resetBlink()
        updatePasswordPrompt()

        let flags = event.modifierFlags
        let bypassIME = !hasMarkedText() && (
            flags.contains(.control) || (flags.contains(.option) && optionIsAlt(event)) || SurfaceView.specialKey(event.keyCode) != nil)
        if bypassIME {
            sendKey(event, text: nil)
            return
        }
        keyDownEvent = event
        keyTextHandled = false
        interpretKeyEvents([event])
        keyDownEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        let flags = terminal.lock.withLock { terminal.kittyKeyboardFlags }
        guard flags & 2 != 0, !hasMarkedText() else { return }
        if let k = keyInput(from: event, text: nil, release: true) { dispatch(.key(k)) }
    }

    override func flagsChanged(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil), mods: event.modifierFlags)
    }

    func optionIsAlt(_ event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        let left = raw & UInt(NX_DEVICELALTKEYMASK) != 0
        let right = raw & UInt(NX_DEVICERALTKEYMASK) != 0
        switch config.optionAsAlt {
        case .none: return false
        case .both: return true
        case .left: return left
        case .right: return right
        }
    }

    static func specialKey(_ code: UInt16) -> KeyInput.Key? {
        switch Int(code) {
        case kVK_Return: return .enter
        case kVK_ANSI_KeypadEnter: return .keypad(0x0D)
        case kVK_Tab: return .tab
        case kVK_Delete: return .backspace
        case kVK_ForwardDelete: return .delete
        case kVK_Escape: return .escape
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        case kVK_Help: return .insert
        case kVK_F1: return .f(1)
        case kVK_F2: return .f(2)
        case kVK_F3: return .f(3)
        case kVK_F4: return .f(4)
        case kVK_F5: return .f(5)
        case kVK_F6: return .f(6)
        case kVK_F7: return .f(7)
        case kVK_F8: return .f(8)
        case kVK_F9: return .f(9)
        case kVK_F10: return .f(10)
        case kVK_F11: return .f(11)
        case kVK_F12: return .f(12)
        case kVK_F13: return .f(13)
        case kVK_F14: return .f(14)
        case kVK_F15: return .f(15)
        case kVK_F16: return .f(16)
        case kVK_F17: return .f(17)
        case kVK_F18: return .f(18)
        case kVK_F19: return .f(19)
        case kVK_F20: return .f(20)
        default: return nil
        }
    }

    static func keypadKey(_ code: UInt16) -> UInt32? {
        switch Int(code) {
        case kVK_ANSI_Keypad0: return 0x30
        case kVK_ANSI_Keypad1: return 0x31
        case kVK_ANSI_Keypad2: return 0x32
        case kVK_ANSI_Keypad3: return 0x33
        case kVK_ANSI_Keypad4: return 0x34
        case kVK_ANSI_Keypad5: return 0x35
        case kVK_ANSI_Keypad6: return 0x36
        case kVK_ANSI_Keypad7: return 0x37
        case kVK_ANSI_Keypad8: return 0x38
        case kVK_ANSI_Keypad9: return 0x39
        case kVK_ANSI_KeypadDecimal: return 0x2E
        case kVK_ANSI_KeypadMultiply: return 0x2A
        case kVK_ANSI_KeypadPlus: return 0x2B
        case kVK_ANSI_KeypadDivide: return 0x2F
        case kVK_ANSI_KeypadMinus: return 0x2D
        case kVK_ANSI_KeypadEquals: return 0x3D
        default: return nil
        }
    }

    /// Strip AppKit's private-use function key characters.
    static func clean(_ s: String?) -> String {
        guard let s else { return "" }
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { !($0.value >= 0xF700 && $0.value <= 0xF8FF) }))
    }

    func keyInput(from event: NSEvent, text override: String?, release: Bool = false) -> KeyInput? {
        let flags = event.modifierFlags
        let altIsMeta = flags.contains(.option) && optionIsAlt(event)
        var mods: KeyInput.Mods = []
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.ctrl) }
        if altIsMeta { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.super) }
        if flags.contains(.capsLock) { mods.insert(.capsLock) }

        var applied: NSEvent.ModifierFlags = flags.intersection([.shift, .capsLock])
        if flags.contains(.option) && !altIsMeta { applied.insert(.option) }
        let text = override ?? SurfaceView.clean(event.characters(byApplyingModifiers: applied))
        let unmodified = SurfaceView.clean(event.characters(byApplyingModifiers: flags.intersection([.shift, .capsLock])))

        let key: KeyInput.Key
        if let k = SurfaceView.specialKey(event.keyCode) {
            key = k
        } else if let kp = SurfaceView.keypadKey(event.keyCode) {
            key = .keypad(kp)
        } else if event.keyCode == UInt16(kVK_Space) {
            key = .space
        } else {
            let base = SurfaceView.clean(event.characters(byApplyingModifiers: [])).lowercased()
            guard let scalar = base.unicodeScalars.first ?? text.unicodeScalars.first else { return nil }
            key = .char(scalar.value)
        }
        let ev: KeyInput.Event = release ? .release : (event.isARepeat ? .repeat : .press)
        return KeyInput(key: key, mods: mods, text: text, unmodifiedText: unmodified, event: ev)
    }

    func sendKey(_ event: NSEvent, text: String?) {
        guard let k = keyInput(from: event, text: text) else {
            if let t = text { dispatch(.text(t)) }
            return
        }
        dispatch(.key(k))
    }

    // MARK: Dispatch (with broadcast)

    func dispatch(_ e: InputEvent) {
        let targets = broadcastEnabled ? AppDelegate.shared.broadcastTargets() : [self]
        for t in targets { t.receive(e) }
    }

    func receive(_ e: InputEvent) {
        switch e {
        case .key(let k):
            let ctx: KeyEncoder.Context = terminal.lock.withLock {
                KeyEncoder.Context(cursorKeysApp: terminal.modes.cursorKeysApp, keypadApp: terminal.modes.keypadApp,
                                   kittyFlags: terminal.kittyKeyboardFlags, newlineMode: terminal.modes.newlineMode)
            }
            write(KeyEncoder.encode(k, ctx))
        case .text(let s):
            write(s)
        case .paste(let s):
            let bracketed = terminal.lock.withLock { terminal.modes.bracketedPaste }
            let text = SurfaceView.sanitizePaste(s).replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
            if bracketed {
                // No ESC can survive sanitizing, so pasted content can't end bracketed paste early.
                write("\u{1B}[200~" + text + "\u{1B}[201~")
            } else {
                write(text)
            }
        }
        if case .key(let k) = e, k.event == .release { return }
        let scrolled = terminal.lock.withLock { terminal.scrollOffset != 0 }
        if scrolled { scrollToBottom() }
    }

    // MARK: Paste

    func pasteText(_ text: String) {
        guard !text.isEmpty else { return }
        let bracketed = terminal.lock.withLock { terminal.modes.bracketedPaste }
        if config.clipboardPasteProtection && !bracketed && text.contains(where: { $0 == "\n" || $0 == "\r" }) {
            let alert = NSAlert()
            alert.messageText = "Paste multiple lines?"
            let preview = text.count > 400 ? String(text.prefix(400)) + "…" : text
            alert.informativeText = "The text contains line breaks and will run as commands when pasted:\n\n\(preview)"
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] r in
                if r == .alertFirstButtonReturn { self?.dispatch(.paste(text)) }
            }
            return
        }
        dispatch(.paste(text))
    }

    @objc func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            dispatch(.text(urls.map { SurfaceView.shellEscape($0.path) }.joined(separator: " ")))
            return
        }
        if let s = pb.string(forType: .string) { pasteText(s) }
    }

    @objc func copy(_ sender: Any?) {
        guard let sel = selection, !sel.isEmpty else { return }
        let text = terminal.lock.withLock { terminal.text(of: sel) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        terminal.lock.withLock {
            let g = terminal.grid
            selection = Selection(anchor: GridPoint(line: g.dropped, col: 0),
                                  head: GridPoint(line: g.dropped + g.count - 1, col: terminal.cols - 1),
                                  mode: .character, onAlternate: terminal.usingAlternate)
        }
        requestRender()
    }

    static func sanitizePaste(_ s: String) -> String { InputSafety.sanitizePaste(s) }
    static func shellEscape(_ s: String) -> String { InputSafety.shellQuote(s) }

    // MARK: Keybindings

    func binding(for event: NSEvent) -> Action? {
        let f = event.modifierFlags
        var mods: KeyCombo.Mods = []
        if f.contains(.command) { mods.insert(.cmd) }
        if f.contains(.control) { mods.insert(.ctrl) }
        if f.contains(.option) { mods.insert(.alt) }
        if f.contains(.shift) { mods.insert(.shift) }
        guard !mods.isEmpty || SurfaceView.specialKey(event.keyCode).map({ if case .f = $0 { return true }; return false }) == true else { return nil }
        let name: String
        switch SurfaceView.specialKey(event.keyCode) {
        case .enter?: name = "enter"
        case .tab?: name = "tab"
        case .backspace?: name = "backspace"
        case .delete?: name = "delete"
        case .escape?: name = "escape"
        case .left?: name = "left"
        case .right?: name = "right"
        case .up?: name = "up"
        case .down?: name = "down"
        case .home?: name = "home"
        case .end?: name = "end"
        case .pageUp?: name = "pageup"
        case .pageDown?: name = "pagedown"
        case .insert?: name = "insert"
        case .f(let n)?: name = "f\(n)"
        case .keypad?: name = "enter"
        default:
            if event.keyCode == UInt16(kVK_Space) { name = "space" }
            else { name = SurfaceView.clean(event.characters(byApplyingModifiers: [])).lowercased() }
        }
        guard !name.isEmpty else { return nil }
        let binds = config.keybinds
        if let a = binds[KeyCombo(mods, name)] { return a }
        // "cmd+shift+]" may also be written with the shifted character ("cmd+}").
        if mods.contains(.shift) {
            let shifted = SurfaceView.clean(event.characters(byApplyingModifiers: .shift)).lowercased()
            if !shifted.isEmpty, shifted != name, let a = binds[KeyCombo(mods.subtracting(.shift), shifted)] { return a }
        }
        return nil
    }

    func perform(_ action: Action) {
        switch action {
        case .copy: copy(nil)
        case .paste: paste(nil)
        case .pasteSelection:
            if let sel = selection { pasteText(terminal.lock.withLock { terminal.text(of: sel) }) }
        case .selectAll: selectAll(nil)
        case .increaseFontSize: setFontSize(fontSize + 1)
        case .decreaseFontSize: setFontSize(fontSize - 1)
        case .resetFontSize: setFontSize(config.fontSize)
        case .find: showSearch()
        case .findNext: findNext(forward: true)
        case .findPrevious: findNext(forward: false)
        case .scrollToTop: terminal.lock.withLock { terminal.scrollOffset = terminal.usingAlternate ? 0 : terminal.primary.scrollbackCount }; requestRender()
        case .scrollToBottom: scrollToBottom()
        case .scrollPageUp: scrollViewport(by: max(1, terminal.rows - 1))
        case .scrollPageDown: scrollViewport(by: -max(1, terminal.rows - 1))
        case .scrollLineUp: scrollViewport(by: 1)
        case .scrollLineDown: scrollViewport(by: -1)
        case .jumpToPrompt(let d): jumpToPrompt(d)
        case .clearScreen:
            // Clear scrollback and ask the shell to redraw its prompt (form feed).
            terminal.lock.withLock {
                terminal.feed("\u{1B}[H\u{1B}[2J\u{1B}[3J")
                terminal.scrollOffset = 0
            }
            selection = nil
            write([0x0C])
            requestRender()
        case .sendText(let s): dispatch(.text(s))
        case .resetTerminal:
            terminal.lock.withLock { terminal.reset() }
            requestRender()
        case .reloadConfig: AppDelegate.shared.reloadConfig()
        case .openConfig: AppDelegate.shared.openConfig(nil)
        case .newWindow: AppDelegate.shared.newWindow(cwd: currentDirectory)
        case .toggleBroadcastPane:
            broadcastEnabled.toggle()
            controller?.updateBroadcastState()
        case .broadcastAllTabs: AppDelegate.shared.toggleBroadcastAll()
        default:
            controller?.perform(action, from: self)
        }
    }

    var currentDirectory: String? {
        terminal.lock.withLock { terminal.workingDirectory } ?? pty?.foregroundCWD ?? cwd
    }

    func jumpToPrompt(_ delta: Int) {
        let (prompts, top): ([Int], Int) = terminal.lock.withLock {
            let g = terminal.grid
            return (terminal.promptLines(), g.dropped + g.scrollbackCount - terminal.scrollOffset)
        }
        guard !prompts.isEmpty else { return }
        let target = delta < 0 ? prompts.last(where: { $0 < top }) : prompts.first(where: { $0 > top })
        if let t = target {
            terminal.lock.withLock {
                let g = terminal.grid
                terminal.scrollOffset = min(max(g.dropped + g.scrollbackCount - t, 0), g.scrollbackCount)
            }
            requestRender()
        } else if delta > 0 {
            scrollToBottom()
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let a = string as? NSAttributedString { text = a.string } else { text = string as? String ?? "" }
        let hadMarked = markedText.length > 0
        markedText = NSMutableAttributedString()
        if let ev = keyDownEvent, !keyTextHandled, !hadMarked {
            keyTextHandled = true
            sendKey(ev, text: text)
        } else {
            dispatch(.text(text))
        }
        requestRender()
    }

    override func doCommand(by selector: Selector) {
        // Keys like Return, Backspace and Escape arrive here via interpretKeyEvents.
        if let ev = keyDownEvent, !keyTextHandled {
            keyTextHandled = true
            sendKey(ev, text: nil)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString { markedText = NSMutableAttributedString(attributedString: a) }
        else { markedText = NSMutableAttributedString(string: string as? String ?? "") }
        keyTextHandled = true
        requestRender()
    }

    func unmarkText() {
        markedText = NSMutableAttributedString()
        requestRender()
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Where the IME candidate window should appear: at the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let (cx, cy) = terminal.lock.withLock { (terminal.cursorX, terminal.cursorY) }
        let cell = cellSizeInPoints()
        let local = NSRect(x: paddingX / scale + CGFloat(cx) * cell.width, y: paddingY / scale + CGFloat(cy) * cell.height,
                           width: cell.width, height: cell.height)
        guard let window else { return .zero }
        let inWindow = convert(local, to: nil)
        return window.convertToScreen(inWindow)
    }
}
