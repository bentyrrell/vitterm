import Foundation

/// A keyboard shortcut: modifier set plus a key name (lowercased character or named key).
public struct KeyCombo: Hashable, Sendable, CustomStringConvertible {
    public struct Mods: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let shift = Mods(rawValue: 1)
        public static let ctrl = Mods(rawValue: 2)
        public static let alt = Mods(rawValue: 4)
        public static let cmd = Mods(rawValue: 8)
    }
    public var mods: Mods
    /// e.g. "t", "1", "=", "left", "enter", "tab", "[", "f1".
    public var key: String

    public init(_ mods: Mods, _ key: String) { self.mods = mods; self.key = key.lowercased() }

    public init?(parse s: String) {
        var mods: Mods = []
        var parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" means cmd and plus.
        if parts.count >= 2 && parts.last == "" && parts[parts.count - 2] == "" { parts.removeLast(2); parts.append("+") }
        guard var key = parts.popLast(), !key.isEmpty else { return nil }
        // Names for keys that are awkward to write literally.
        let aliases = ["equal": "=", "plus": "+", "minus": "-", "comma": ",", "period": ".", "slash": "/",
                       "backslash": "\\", "semicolon": ";", "quote": "'", "backquote": "`", "grave": "`",
                       "bracketleft": "[", "bracketright": "]", "return": "enter", "esc": "escape", "del": "delete"]
        if let a = aliases[key] { key = a }
        for p in parts {
            switch p {
            case "cmd", "super", "command": mods.insert(.cmd)
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        self.mods = mods
        self.key = key
    }

    public var description: String {
        var s = ""
        if mods.contains(.ctrl) { s += "ctrl+" }
        if mods.contains(.alt) { s += "alt+" }
        if mods.contains(.shift) { s += "shift+" }
        if mods.contains(.cmd) { s += "cmd+" }
        return s + key
    }
}

public enum Direction: String, Sendable { case left, right, up, down }

/// User-bindable actions.
public enum Action: Hashable, Sendable {
    case newWindow, newTab, closeSurface, closeTab, closeWindow
    case nextTab, previousTab, gotoTab(Int), lastTab
    case splitRight, splitDown, splitLeft, splitUp
    case focusSplit(Direction), resizeSplit(Direction, Int), equalizeSplits, toggleSplitZoom
    case toggleBroadcastTab, toggleBroadcastPane, broadcastAllTabs
    case copy, paste, pasteSelection, selectAll
    case increaseFontSize, decreaseFontSize, resetFontSize
    case find, findNext, findPrevious
    case scrollToTop, scrollToBottom, scrollPageUp, scrollPageDown, scrollLineUp, scrollLineDown
    case jumpToPrompt(Int)
    case clearScreen
    case reloadConfig, openConfig
    case toggleFullscreen
    case sendText(String)
    case resetTerminal

    public init?(parse s: String) {
        let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : nil
        switch name {
        case "new_window": self = .newWindow
        case "new_tab": self = .newTab
        case "close_surface": self = .closeSurface
        case "close_tab": self = .closeTab
        case "close_window": self = .closeWindow
        case "next_tab": self = .nextTab
        case "previous_tab": self = .previousTab
        case "last_tab": self = .lastTab
        case "goto_tab": guard let n = arg.flatMap({ Int($0) }) else { return nil }; self = .gotoTab(n)
        case "new_split":
            switch arg ?? "right" {
            case "right": self = .splitRight
            case "down": self = .splitDown
            case "left": self = .splitLeft
            case "up": self = .splitUp
            default: return nil
            }
        case "goto_split", "focus_split":
            guard let d = arg.flatMap(Direction.init(rawValue:)) else { return nil }; self = .focusSplit(d)
        case "resize_split":
            let a = (arg ?? "").split(separator: ",")
            guard let d = a.first.flatMap({ Direction(rawValue: String($0)) }) else { return nil }
            self = .resizeSplit(d, a.count > 1 ? Int(a[1]) ?? 20 : 20)
        case "equalize_splits": self = .equalizeSplits
        case "toggle_split_zoom": self = .toggleSplitZoom
        case "toggle_broadcast", "toggle_broadcast_tab": self = .toggleBroadcastTab
        case "toggle_broadcast_pane": self = .toggleBroadcastPane
        case "broadcast_all_tabs": self = .broadcastAllTabs
        case "copy_to_clipboard", "copy": self = .copy
        case "paste_from_clipboard", "paste": self = .paste
        case "paste_from_selection": self = .pasteSelection
        case "select_all": self = .selectAll
        case "increase_font_size": self = .increaseFontSize
        case "decrease_font_size": self = .decreaseFontSize
        case "reset_font_size": self = .resetFontSize
        case "find", "search": self = .find
        case "find_next": self = .findNext
        case "find_previous": self = .findPrevious
        case "scroll_to_top": self = .scrollToTop
        case "scroll_to_bottom": self = .scrollToBottom
        case "scroll_page_up": self = .scrollPageUp
        case "scroll_page_down": self = .scrollPageDown
        case "scroll_line_up": self = .scrollLineUp
        case "scroll_line_down": self = .scrollLineDown
        case "jump_to_prompt": guard let n = arg.flatMap({ Int($0) }) else { return nil }; self = .jumpToPrompt(n)
        case "clear_screen": self = .clearScreen
        case "reload_config": self = .reloadConfig
        case "open_config": self = .openConfig
        case "toggle_fullscreen": self = .toggleFullscreen
        case "reset": self = .resetTerminal
        case "text":
            guard let a = arg else { return nil }
            self = .sendText(Keybinds.unescape(a))
        default: return nil
        }
    }
}

public enum Keybinds {
    public static let defaults: [KeyCombo: Action] = {
        var m: [KeyCombo: Action] = [:]
        func b(_ s: String, _ a: Action) { m[KeyCombo(parse: s)!] = a }
        b("cmd+n", .newWindow)
        b("cmd+t", .newTab)
        b("cmd+w", .closeSurface)
        b("cmd+shift+w", .closeTab)
        b("cmd+alt+w", .closeWindow)
        b("cmd+shift+]", .nextTab)
        b("cmd+shift+[", .previousTab)
        b("ctrl+tab", .nextTab)
        b("ctrl+shift+tab", .previousTab)
        for i in 1...8 { b("cmd+\(i)", .gotoTab(i)) }
        b("cmd+9", .lastTab)
        b("cmd+d", .splitRight)
        b("cmd+shift+d", .splitDown)
        b("cmd+alt+left", .focusSplit(.left))
        b("cmd+alt+right", .focusSplit(.right))
        b("cmd+alt+up", .focusSplit(.up))
        b("cmd+alt+down", .focusSplit(.down))
        b("cmd+]", .focusSplit(.right))
        b("cmd+[", .focusSplit(.left))
        b("cmd+ctrl+left", .resizeSplit(.left, 20))
        b("cmd+ctrl+right", .resizeSplit(.right, 20))
        b("cmd+ctrl+up", .resizeSplit(.up, 20))
        b("cmd+ctrl+down", .resizeSplit(.down, 20))
        b("cmd+ctrl+=", .equalizeSplits)
        b("cmd+shift+enter", .toggleSplitZoom)
        b("cmd+alt+i", .toggleBroadcastTab)
        b("cmd+alt+shift+i", .toggleBroadcastPane)
        b("cmd+c", .copy)
        b("cmd+v", .paste)
        b("cmd+shift+v", .pasteSelection)
        b("cmd+a", .selectAll)
        b("cmd+=", .increaseFontSize)
        b("cmd++", .increaseFontSize)
        b("cmd+-", .decreaseFontSize)
        b("cmd+0", .resetFontSize)
        b("cmd+f", .find)
        b("cmd+g", .findNext)
        b("cmd+shift+g", .findPrevious)
        b("cmd+home", .scrollToTop)
        b("cmd+end", .scrollToBottom)
        b("shift+pageup", .scrollPageUp)
        b("shift+pagedown", .scrollPageDown)
        b("cmd+pageup", .scrollPageUp)
        b("cmd+pagedown", .scrollPageDown)
        b("cmd+up", .jumpToPrompt(-1))
        b("cmd+down", .jumpToPrompt(1))
        b("cmd+k", .clearScreen)
        b("cmd+shift+,", .reloadConfig)
        b("cmd+,", .openConfig)
        b("cmd+ctrl+f", .toggleFullscreen)
        b("cmd+enter", .toggleFullscreen)
        b("cmd+left", .sendText("\u{01}"))
        b("cmd+right", .sendText("\u{05}"))
        b("cmd+backspace", .sendText("\u{15}"))
        b("alt+left", .sendText("\u{1B}b"))
        b("alt+right", .sendText("\u{1B}f"))
        return m
    }()

    /// Interpret \n, \r, \t, \e, \xNN and \\ escapes in `text:` bindings.
    public static func unescape(_ s: String) -> String {
        var out = ""
        var it = Array(s.unicodeScalars)[...]
        while let c = it.popFirst() {
            guard c == "\\", let n = it.popFirst() else { out.unicodeScalars.append(c); continue }
            switch n {
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case "e": out += "\u{1B}"
            case "\\": out += "\\"
            case "x":
                let hex = String(String.UnicodeScalarView(it.prefix(2)))
                if let v = UInt8(hex, radix: 16) { out.unicodeScalars.append(Unicode.Scalar(v)); it = it.dropFirst(2) }
            default: out.unicodeScalars.append(n)
            }
        }
        return out
    }
}
