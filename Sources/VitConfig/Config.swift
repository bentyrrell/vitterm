import Foundation

/// RGB color as 0x00RRGGBB.
public typealias RGB = UInt32

public enum OptionAsAlt: String, Sendable { case none, left, right, both }
public enum CursorStyleSetting: String, Sendable { case block, bar, underline }

public struct Theme: Sendable, Equatable {
    public var name: String
    public var foreground: RGB = 0xD8DEE9
    public var background: RGB = 0x16181D
    public var cursor: RGB? = nil
    public var cursorText: RGB? = nil
    /// Optional theme-specific cursor trail color (falls back to the theme's magenta).
    public var cursorTrail: RGB? = nil
    public var selectionBackground: RGB? = nil
    public var selectionForeground: RGB? = nil
    public var palette: [RGB] = [
        0x1D2026, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xD8DEE9,
        0x5C6370, 0xFF7A85, 0xB5E890, 0xFFD68A, 0x82C4FF, 0xDA9CF0, 0x7FD4DE, 0xFFFFFF,
    ]
    public init(name: String) { self.name = name }

    public var isDark: Bool {
        let r = Double(background >> 16 & 0xFF), g = Double(background >> 8 & 0xFF), b = Double(background & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b < 128
    }

    /// Apply a `key = value` line from a theme file. Returns false for unknown keys.
    @discardableResult
    public mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "foreground": if let c = parseHexColor(value) { foreground = c }
        case "background": if let c = parseHexColor(value) { background = c }
        case "cursor-color": cursor = parseHexColor(value)
        case "cursor-text": cursorText = parseHexColor(value)
        case "cursor-trail-color": cursorTrail = parseHexColor(value)
        case "selection-background": selectionBackground = parseHexColor(value)
        case "selection-foreground": selectionForeground = parseHexColor(value)
        case "palette":
            guard let eq = value.firstIndex(of: "="), let i = Int(value[..<eq].trimmingCharacters(in: .whitespaces)),
                  i >= 0 && i < 16, let c = parseHexColor(String(value[value.index(after: eq)...])) else { return true }
            palette[i] = c
        default: return false
        }
        return true
    }
}

public func parseHexColor(_ s: String) -> RGB? {
    var h = s.trimmingCharacters(in: .whitespaces)
    if h.hasPrefix("#") { h.removeFirst() }
    if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
    return v
}

/// User configuration, loaded from `~/.config/vitterm/config`.
public struct Config: Sendable {
    public var fontFamily: String = ""
    public var fontFamilyBold: String = ""
    public var fontFamilyItalic: String = ""
    public var fontSize: Double = 13
    /// OpenType features like "ss01", "-calt", "+zero".
    public var fontFeatures: [String] = []
    public var fontLigatures = true
    public var fontThicken = false
    public var adjustCellWidth = 0
    public var adjustCellHeight = 0

    public var theme = "Vit Dark"
    public var themeLight: String? = nil
    public var themeDark: String? = nil
    public var themeOverrides: [(String, String)] = []

    public var backgroundOpacity: Double = 1.0
    public var backgroundBlur = 0
    public var windowPaddingX: Double = 10
    public var windowPaddingY: Double = 6
    public var windowColumns = 110
    public var windowRows = 32
    public var unfocusedSplitOpacity: Double = 0.85
    /// "native" (standard titlebar, default), "compact" or "unified" (toolbar-style, taller).
    public var titlebarStyle = "native"

    public var cursorStyle: CursorStyleSetting = .block
    public var cursorBlink = true
    /// Milliseconds per blink phase.
    public var cursorBlinkInterval = 550
    /// Animated cursor trail (like Rio's trail-cursor).
    public var cursorTrail = false
    /// "theme" (theme's trail color, else its magenta), "cursor", an ANSI color name, "palette:N" or "#rrggbb".
    public var cursorTrailColor = "theme"
    public var cursorTrailOpacity: Double = 0.6
    public var cursorTrailDecayFast = 100   // ms
    public var cursorTrailDecaySlow = 400   // ms
    public var cursorTrailThreshold = 2     // cells

    public var scrollbackLines = 10_000
    public var optionAsAlt: OptionAsAlt = .left
    public var copyOnSelect = false
    public var confirmClose = true
    public var mouseHideWhileTyping = true
    public var boldIsBright = false
    public var clipboardRead = false
    /// `clipboard-read = ask`: confirm each OSC 52 read.
    public var clipboardReadAsk = false
    /// Desktop notifications requested by programs (OSC 9 / OSC 777).
    public var desktopNotifications = true
    /// OSC 52 clipboard writes from programs.
    public enum ClipboardWrite: String, Sendable { case allow, ask, deny }
    public var clipboardWrite = ClipboardWrite.allow
    /// Whether the Kitty graphics protocol may read image files from disk (`t=f` / `t=t`).
    public var imageFileTransfer = true
    public var clipboardPasteProtection = true
    public var shell: String? = nil
    /// "home", "inherit", or a path.
    public var workingDirectory = "inherit"
    public var wordSeparators = " \t'\"`()[]{}<>|│,;:="
    public var shellIntegration = true
    public var bellAudible = false
    public var bellVisual = false

    public var keybinds: [KeyCombo: Action] = Keybinds.defaults

    /// Problems found while parsing, shown to the user.
    public var diagnostics: [String] = []

    public init() {}

    public static var configDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg).appendingPathComponent("vitterm")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vitterm")
    }

    public static var configFile: URL { configDirectory.appendingPathComponent("config") }

    public static func load() -> Config {
        var c = Config()
        if let text = try? String(contentsOf: configFile, encoding: .utf8) {
            c.parse(text, base: configDirectory)
        }
        c.validate()
        return c
    }

    /// Report references to things that don't exist (they would otherwise fall back silently).
    public mutating func validate() {
        let available = Themes.available()
        for name in Set([theme, themeLight, themeDark].compactMap { $0 }) where Themes.named(name) == nil {
            let close = available.first { $0.lowercased().hasPrefix(name.lowercased()) || name.lowercased().hasPrefix($0.lowercased()) }
            diagnostics.append("unknown theme '\(name)'" + (close.map { " (did you mean '\($0)'?)" } ?? ""))
        }
    }

    public mutating func parse(_ text: String, base: URL? = nil, depth: Int = 0) {
        for (n, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                diagnostics.append("line \(n + 1): expected key = value")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = Config.stripInlineComment(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            if value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if key == "config-file", depth < 4 {
                let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : (base ?? Config.configDirectory).appendingPathComponent(value)
                if let t = try? String(contentsOf: url, encoding: .utf8) { parse(t, base: url.deletingLastPathComponent(), depth: depth + 1) }
                continue
            }
            if !set(key: key, value: value) {
                diagnostics.append("line \(n + 1): unknown or invalid setting '\(key)'")
            }
        }
    }

    static let ansiNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

    static func isValidTrailColor(_ v: String) -> Bool {
        let l = v.lowercased()
        if l == "theme" || l == "cursor" || parseHexColor(v) != nil { return true }
        if l.hasPrefix("palette:"), let n = Int(l.dropFirst(8)), n >= 0, n < 16 { return true }
        let base = l.hasPrefix("bright-") ? String(l.dropFirst(7)) : l
        return ansiNames.contains(base)
    }

    /// The trail color for a theme, following `cursor-trail-color`.
    public func resolvedTrailColor(_ t: Theme) -> RGB {
        let v = cursorTrailColor.lowercased()
        if let hex = parseHexColor(cursorTrailColor) { return hex }
        if v == "cursor" { return t.cursor ?? t.foreground }
        if v.hasPrefix("palette:"), let n = Int(v.dropFirst(8)), n >= 0, n < 16 { return t.palette[n] }
        let bright = v.hasPrefix("bright-")
        if let i = Config.ansiNames.firstIndex(of: bright ? String(v.dropFirst(7)) : v) { return t.palette[i + (bright ? 8 : 0)] }
        return t.cursorTrail ?? t.palette[5]
    }

    /// Remove a trailing `# comment` (a `#` preceded by whitespace, outside double quotes), so
    /// values like `#fdf6e3` or `palette = 0=#073642` are unaffected.
    public static func stripInlineComment(_ v: String) -> String {
        var inQuotes = false
        var prevSpace = false
        for i in v.indices {
            let c = v[i]
            if c == "\"" { inQuotes.toggle() }
            if c == "#" && prevSpace && !inQuotes {
                return v[..<i].trimmingCharacters(in: .whitespaces)
            }
            prevSpace = c == " " || c == "\t"
        }
        return v
    }

    public mutating func set(key: String, value: String) -> Bool {
        func bool(_ v: String) -> Bool? {
            switch v.lowercased() { case "true", "yes", "on", "1": return true; case "false", "no", "off", "0": return false; default: return nil }
        }
        switch key {
        case "font-family": fontFamily = value
        case "font-family-bold": fontFamilyBold = value
        case "font-family-italic": fontFamilyItalic = value
        case "font-size": guard let v = Double(value), v >= 4, v <= 200 else { return false }; fontSize = v
        case "font-feature": fontFeatures.append(contentsOf: value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        case "font-ligatures": guard let b = bool(value) else { return false }; fontLigatures = b
        case "font-thicken": guard let b = bool(value) else { return false }; fontThicken = b
        case "adjust-cell-width": guard let v = Int(value) else { return false }; adjustCellWidth = v
        case "adjust-cell-height": guard let v = Int(value) else { return false }; adjustCellHeight = v
        case "theme":
            // "theme = light:Foo,dark:Bar" or a single name.
            if value.contains("light:") || value.contains("dark:") {
                for part in value.split(separator: ",") {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    if p.hasPrefix("light:") { themeLight = String(p.dropFirst(6)) }
                    if p.hasPrefix("dark:") { themeDark = String(p.dropFirst(5)) }
                }
            } else {
                theme = value; themeLight = nil; themeDark = nil
            }
        case "foreground", "background", "cursor-color", "cursor-text", "selection-background", "selection-foreground", "palette":
            themeOverrides.append((key, value))
        case "background-opacity": guard let v = Double(value) else { return false }; backgroundOpacity = min(max(v, 0), 1)
        case "background-blur": guard let v = Int(value) else { if let b = bool(value) { backgroundBlur = b ? 20 : 0; return true }; return false }; backgroundBlur = v
        case "window-padding-x": guard let v = Double(value) else { return false }; windowPaddingX = v
        case "window-padding-y": guard let v = Double(value) else { return false }; windowPaddingY = v
        case "window-width": guard let v = Int(value), v > 10 else { return false }; windowColumns = v
        case "window-height": guard let v = Int(value), v > 3 else { return false }; windowRows = v
        case "titlebar-style", "macos-titlebar-style":
            guard ["native", "compact", "unified", "legacy"].contains(value) else { return false }
            titlebarStyle = value == "legacy" ? "native" : value
        case "unfocused-split-opacity": guard let v = Double(value) else { return false }; unfocusedSplitOpacity = min(max(v, 0.15), 1)
        case "cursor-style": guard let s = CursorStyleSetting(rawValue: value) else { return false }; cursorStyle = s
        case "cursor-style-blink", "cursor-blink": guard let b = bool(value) else { return false }; cursorBlink = b
        case "cursor-trail", "trail-cursor": guard let b = bool(value) else { return false }; cursorTrail = b
        case "cursor-trail-color", "trail-cursor-color":
            guard Config.isValidTrailColor(value) else { return false }; cursorTrailColor = value
        case "cursor-trail-opacity", "trail-cursor-opacity": guard let v = Double(value) else { return false }; cursorTrailOpacity = min(max(v, 0), 1)
        case "cursor-trail-decay", "trail-cursor-decay":
            let parts = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return false }
            cursorTrailDecayFast = min(parts[0], parts[1]); cursorTrailDecaySlow = max(parts[0], parts[1])
        case "cursor-trail-threshold", "trail-cursor-start-threshold": guard let v = Int(value), v >= 0 else { return false }; cursorTrailThreshold = v
        case "cursor-blink-interval": guard let v = Int(value), v >= 100, v <= 5000 else { return false }; cursorBlinkInterval = v
        case "scrollback-limit", "scrollback-lines": guard let v = Int(value), v >= 0 else { return false }; scrollbackLines = min(v, 10_000_000)
        case "macos-option-as-alt", "option-as-alt":
            if let b = bool(value) { optionAsAlt = b ? .both : .none } else if let o = OptionAsAlt(rawValue: value) { optionAsAlt = o } else { return false }
        case "copy-on-select": guard let b = bool(value) else { return false }; copyOnSelect = b
        case "confirm-close-surface", "confirm-close": guard let b = bool(value) else { return false }; confirmClose = b
        case "mouse-hide-while-typing": guard let b = bool(value) else { return false }; mouseHideWhileTyping = b
        case "bold-is-bright": guard let b = bool(value) else { return false }; boldIsBright = b
        case "clipboard-read":
            clipboardReadAsk = value == "ask"
            clipboardRead = value == "allow" || value == "ask" || bool(value) == true
        case "desktop-notifications": guard let b = bool(value) else { return false }; desktopNotifications = b
        case "clipboard-write":
            if let p = ClipboardWrite(rawValue: value) { clipboardWrite = p }
            else if let b = bool(value) { clipboardWrite = b ? .allow : .deny }
            else { return false }
        case "image-file-transfer": guard let b = bool(value) else { return false }; imageFileTransfer = b
        case "clipboard-paste-protection": guard let b = bool(value) else { return false }; clipboardPasteProtection = b
        case "command", "shell": shell = value.isEmpty ? nil : value
        case "working-directory": workingDirectory = value
        case "word-separators": wordSeparators = value
        case "shell-integration": shellIntegration = value != "none" && bool(value) != false
        case "bell":
            bellAudible = value.contains("audible")
            bellVisual = value.contains("visual")
        case "keybind":
            if value == "clear" { keybinds = [:]; return true }
            // The key itself may be "=" (`cmd+==action`) and `text:` payloads may contain "=", so
            // use the first "=" that splits the value into a valid key combination and action.
            var idx = value.startIndex
            while let eq = value[idx...].firstIndex(of: "=") {
                if let combo = KeyCombo(parse: String(value[..<eq])) {
                    let actionText = String(value[value.index(after: eq)...])
                    if actionText == "unbind" { keybinds[combo] = nil; return true }
                    if let a = Action(parse: actionText) { keybinds[combo] = a; return true }
                }
                idx = value.index(after: eq)
            }
            return false
        default:
            return false
        }
        return true
    }

    /// Resolve the theme for the given system appearance.
    public func resolvedTheme(systemDark: Bool) -> Theme {
        let name = (systemDark ? themeDark : themeLight) ?? theme
        var t = Themes.named(name) ?? Themes.named("Vit Dark")!
        for (k, v) in themeOverrides { t.apply(key: k, value: v) }
        return t
    }
}
