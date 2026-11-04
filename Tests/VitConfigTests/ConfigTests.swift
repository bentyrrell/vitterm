import XCTest
@testable import VitConfig

final class ConfigParsingTests: XCTestCase {
    func parsed(_ text: String) -> Config {
        var c = Config()
        c.parse(text)
        return c
    }

    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.fontSize, 13)
        XCTAssertTrue(c.fontLigatures)
        XCTAssertEqual(c.theme, "Vit Dark")
        XCTAssertEqual(c.scrollbackLines, 10_000)
        XCTAssertEqual(c.titlebarStyle, "native")
        XCTAssertFalse(c.cursorTrail)
        // The bell (e.g. zsh on an ambiguous Tab completion) only marks the tab by default.
        XCTAssertFalse(c.bellVisual)
        XCTAssertFalse(c.bellAudible)
        XCTAssertTrue(c.diagnostics.isEmpty)
    }

    func testBellValues() {
        XCTAssertTrue(parsed("bell = visual").bellVisual)
        let none = parsed("bell = none")
        XCTAssertFalse(none.bellVisual || none.bellAudible)
        XCTAssertTrue(parsed("bell = audible").bellAudible)
    }

    /// Every supported key accepts a representative valid value and lands in the right property.
    func testEverySettingParses() {
        let c = parsed("""
        font-family = Fira Code
        font-family-bold = Fira Code Bold
        font-family-italic = Fira Code Italic
        font-size = 15.5
        font-feature = ss01, -calt
        font-feature = +zero
        font-ligatures = false
        font-thicken = yes
        adjust-cell-width = -1
        adjust-cell-height = 3
        background-opacity = 0.8
        background-blur = 20
        window-padding-x = 4
        window-padding-y = 2
        window-width = 120
        window-height = 40
        unfocused-split-opacity = 0.7
        titlebar-style = unified
        cursor-style = bar
        cursor-blink = off
        cursor-blink-interval = 700
        cursor-trail = true
        cursor-trail-color = bright-blue
        cursor-trail-opacity = 0.4
        cursor-trail-decay = 80, 300
        cursor-trail-threshold = 3
        scrollback-limit = 50000
        option-as-alt = right
        copy-on-select = true
        confirm-close = false
        mouse-hide-while-typing = false
        bold-is-bright = true
        clipboard-read = allow
        clipboard-paste-protection = false
        command = /bin/bash
        working-directory = home
        word-separators = " ,"
        shell-integration = none
        bell = visual audible
        """)
        XCTAssertTrue(c.diagnostics.isEmpty, "\(c.diagnostics)")
        XCTAssertEqual(c.fontFamily, "Fira Code")
        XCTAssertEqual(c.fontFamilyBold, "Fira Code Bold")
        XCTAssertEqual(c.fontFamilyItalic, "Fira Code Italic")
        XCTAssertEqual(c.fontSize, 15.5)
        XCTAssertEqual(c.fontFeatures, ["ss01", "-calt", "+zero"])
        XCTAssertFalse(c.fontLigatures)
        XCTAssertTrue(c.fontThicken)
        XCTAssertEqual(c.adjustCellWidth, -1)
        XCTAssertEqual(c.adjustCellHeight, 3)
        XCTAssertEqual(c.backgroundOpacity, 0.8)
        XCTAssertEqual(c.backgroundBlur, 20)
        XCTAssertEqual(c.windowPaddingX, 4)
        XCTAssertEqual(c.windowPaddingY, 2)
        XCTAssertEqual(c.windowColumns, 120)
        XCTAssertEqual(c.windowRows, 40)
        XCTAssertEqual(c.unfocusedSplitOpacity, 0.7)
        XCTAssertEqual(c.titlebarStyle, "unified")
        XCTAssertEqual(c.cursorStyle, .bar)
        XCTAssertFalse(c.cursorBlink)
        XCTAssertEqual(c.cursorBlinkInterval, 700)
        XCTAssertTrue(c.cursorTrail)
        XCTAssertEqual(c.cursorTrailColor, "bright-blue")
        XCTAssertEqual(c.cursorTrailOpacity, 0.4)
        XCTAssertEqual(c.cursorTrailDecayFast, 80)
        XCTAssertEqual(c.cursorTrailDecaySlow, 300)
        XCTAssertEqual(c.cursorTrailThreshold, 3)
        XCTAssertEqual(c.scrollbackLines, 50_000)
        XCTAssertEqual(c.optionAsAlt, .right)
        XCTAssertTrue(c.copyOnSelect)
        XCTAssertFalse(c.confirmClose)
        XCTAssertFalse(c.mouseHideWhileTyping)
        XCTAssertTrue(c.boldIsBright)
        XCTAssertTrue(c.clipboardRead)
        XCTAssertFalse(c.clipboardPasteProtection)
        XCTAssertEqual(c.shell, "/bin/bash")
        XCTAssertEqual(c.workingDirectory, "home")
        XCTAssertEqual(c.wordSeparators, " ,")
        XCTAssertFalse(c.shellIntegration)
        XCTAssertTrue(c.bellAudible && c.bellVisual)
    }

    func testSecuritySettings() {
        XCTAssertEqual(Config().clipboardWrite, .allow)
        XCTAssertTrue(Config().imageFileTransfer)
        XCTAssertEqual(parsed("clipboard-write = ask").clipboardWrite, .ask)
        XCTAssertEqual(parsed("clipboard-write = deny").clipboardWrite, .deny)
        XCTAssertEqual(parsed("clipboard-write = false").clipboardWrite, .deny)
        XCTAssertFalse(parsed("image-file-transfer = false").imageFileTransfer)
        XCTAssertFalse(parsed("clipboard-write = maybe").diagnostics.isEmpty)
        XCTAssertFalse(Config().clipboardRead)
        let ask = parsed("clipboard-read = ask")
        XCTAssertTrue(ask.clipboardRead && ask.clipboardReadAsk)
        let allow = parsed("clipboard-read = allow")
        XCTAssertTrue(allow.clipboardRead && !allow.clipboardReadAsk)
        XCTAssertTrue(Config().desktopNotifications)
        XCTAssertFalse(parsed("desktop-notifications = false").desktopNotifications)
    }

    func testInvalidValuesAreReportedWithLineNumbers() {
        let c = parsed("""
        font-size = huge
        cursor-style = triangle
        no-such-setting = 1
        just some words
        option-as-alt = sideways
        titlebar-style = fancy
        cursor-trail-color = not-a-color
        cursor-trail-decay = 100
        scrollback-limit = -5
        """)
        XCTAssertEqual(c.diagnostics.count, 9, "\(c.diagnostics)")
        XCTAssertTrue(c.diagnostics[0].hasPrefix("line 1:"))
        XCTAssertTrue(c.diagnostics[3].contains("expected key = value"))
        // Invalid values leave the defaults in place.
        XCTAssertEqual(c.fontSize, 13)
        XCTAssertEqual(c.cursorStyle, .block)
    }

    func testCommentsQuotesAndWhitespace() {
        let c = parsed("""
        # full-line comment
           font-size   =   14    # trailing comment
        font-family = "JetBrains Mono"
        background = #fdf6e3        # colors starting with # are values, not comments
        palette = 1=#ff0000
        word-separators = "a # b"

        """)
        XCTAssertTrue(c.diagnostics.isEmpty, "\(c.diagnostics)")
        XCTAssertEqual(c.fontSize, 14)
        XCTAssertEqual(c.fontFamily, "JetBrains Mono")
        XCTAssertEqual(c.wordSeparators, "a # b")
        let theme = c.resolvedTheme(systemDark: true)
        XCTAssertEqual(theme.background, 0xFDF6E3)
        XCTAssertEqual(theme.palette[1], 0xFF0000)
    }

    func testThemeSelectionFollowsAppearance() {
        let c = parsed("theme = light:Solarized Light,dark:Nord")
        XCTAssertEqual(c.resolvedTheme(systemDark: false).name, "Solarized Light")
        XCTAssertEqual(c.resolvedTheme(systemDark: true).name, "Nord")
        let single = parsed("theme = Dracula")
        XCTAssertEqual(single.resolvedTheme(systemDark: false).name, "Dracula")
        XCTAssertEqual(single.resolvedTheme(systemDark: true).name, "Dracula")
    }

    func testUnknownThemeFallsBackAndIsReported() {
        var c = parsed("theme = Solarised Lite")
        c.validate()
        XCTAssertEqual(c.resolvedTheme(systemDark: true).name, "Vit Dark")
        XCTAssertEqual(c.diagnostics.count, 1)
    }

    func testIncludedConfigFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitterm-include-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "font-size = 18\nconfig-file = more\n".write(to: dir.appendingPathComponent("extra"), atomically: true, encoding: .utf8)
        try "cursor-style = underline\n".write(to: dir.appendingPathComponent("more"), atomically: true, encoding: .utf8)
        var c = Config()
        c.parse("config-file = extra\nfont-family = Menlo", base: dir)
        XCTAssertTrue(c.diagnostics.isEmpty, "\(c.diagnostics)")
        XCTAssertEqual(c.fontSize, 18)
        XCTAssertEqual(c.cursorStyle, .underline)
        XCTAssertEqual(c.fontFamily, "Menlo")
    }

    func testIncludeCyclesTerminate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitterm-cycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "config-file = a\nfont-size = 20\n".write(to: dir.appendingPathComponent("a"), atomically: true, encoding: .utf8)
        var c = Config()
        c.parse("config-file = a", base: dir)
        XCTAssertEqual(c.fontSize, 20)
    }
}

final class ThemeTests: XCTestCase {
    func testAllBundledThemesAreComplete() {
        let names = Themes.available()
        for expected in ["Vit Dark", "Vit Light", "Solarized Dark", "Solarized Light", "Dracula", "Nord",
                         "Gruvbox Dark", "Tokyo Night", "Catppuccin Mocha", "Catppuccin Latte"] {
            XCTAssertTrue(names.contains(expected), "missing bundled theme \(expected)")
        }
        for name in names {
            guard let t = Themes.named(name) else { XCTFail("theme \(name) failed to load"); continue }
            XCTAssertEqual(t.palette.count, 16, name)
            XCTAssertNotEqual(t.foreground, t.background, "\(name): foreground equals background")
            // Text must be readable: require a minimum luminance contrast.
            XCTAssertGreaterThan(contrast(t.foreground, t.background), 3, "\(name): low contrast")
        }
    }

    func testDarkAndLightClassification() {
        XCTAssertTrue(Themes.named("Solarized Dark")!.isDark)
        XCTAssertFalse(Themes.named("Solarized Light")!.isDark)
        XCTAssertFalse(Themes.named("Catppuccin Latte")!.isDark)
        XCTAssertTrue(Themes.named("Tokyo Night")!.isDark)
    }

    func testThemeFileParsing() {
        let t = Themes.parse("""
        # comment
        background = #000000
        foreground = #ffffff  # trailing comment
        cursor-color = #ff00ff
        cursor-trail-color = #123456
        selection-background = #333
        palette = 3=#abcdef
        palette = 99=#000000
        nonsense line
        """, name: "test")
        XCTAssertEqual(t.background, 0x000000)
        XCTAssertEqual(t.foreground, 0xFFFFFF)
        XCTAssertEqual(t.cursor, 0xFF00FF)
        XCTAssertEqual(t.cursorTrail, 0x123456)
        XCTAssertEqual(t.selectionBackground, 0x333333)
        XCTAssertEqual(t.palette[3], 0xABCDEF)
    }

    func testHexColorParsing() {
        XCTAssertEqual(parseHexColor("#abc"), 0xAABBCC)
        XCTAssertEqual(parseHexColor("abcdef"), 0xABCDEF)
        XCTAssertEqual(parseHexColor(" #ABCDEF "), 0xABCDEF)
        XCTAssertNil(parseHexColor("#abcd"))
        XCTAssertNil(parseHexColor("#ggg"))
    }

    func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            func ch(_ v: UInt32) -> Double {
                let x = Double(v) / 255
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(c >> 16 & 0xFF) + 0.7152 * ch(c >> 8 & 0xFF) + 0.0722 * ch(c & 0xFF)
        }
        let la = lum(a), lb = lum(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

final class KeybindTests: XCTestCase {
    func testComboParsing() {
        XCTAssertEqual(KeyCombo(parse: "cmd+shift+]"), KeyCombo([.cmd, .shift], "]"))
        XCTAssertEqual(KeyCombo(parse: "CTRL+Tab"), KeyCombo([.ctrl], "tab"))
        XCTAssertEqual(KeyCombo(parse: "cmd++"), KeyCombo([.cmd], "+"))
        XCTAssertEqual(KeyCombo(parse: "super+alt+left"), KeyCombo([.cmd, .alt], "left"))
        XCTAssertEqual(KeyCombo(parse: "f5"), KeyCombo([], "f5"))
        XCTAssertNil(KeyCombo(parse: "hyper+x"))
        XCTAssertNil(KeyCombo(parse: "cmd+"))
    }

    func testActionParsing() {
        XCTAssertEqual(Action(parse: "new_tab"), .newTab)
        XCTAssertEqual(Action(parse: "goto_tab:3"), .gotoTab(3))
        XCTAssertEqual(Action(parse: "new_split:down"), .splitDown)
        XCTAssertEqual(Action(parse: "goto_split:left"), .focusSplit(.left))
        XCTAssertEqual(Action(parse: "resize_split:up,40"), .resizeSplit(.up, 40))
        XCTAssertEqual(Action(parse: "jump_to_prompt:-1"), .jumpToPrompt(-1))
        XCTAssertEqual(Action(parse: "text:\\x1b[A\\n"), .sendText("\u{1B}[A\n"))
        XCTAssertNil(Action(parse: "goto_tab:x"))
        XCTAssertNil(Action(parse: "new_split:sideways"))
        XCTAssertNil(Action(parse: "fly"))
    }

    func testKeybindConfigLines() {
        var c = Config()
        c.parse("""
        keybind = cmd+t=unbind
        keybind = ctrl+shift+t=new_tab
        keybind = cmd+k=text:\\x0c
        keybind = cmd+==equalize_splits
        keybind = ctrl+equal=reset_font_size
        keybind = ctrl+a=text:a=b
        keybind = bogus
        """)
        XCTAssertNil(c.keybinds[KeyCombo([.cmd], "t")])
        XCTAssertEqual(c.keybinds[KeyCombo([.ctrl, .shift], "t")], .newTab)
        XCTAssertEqual(c.keybinds[KeyCombo([.cmd], "k")], .sendText("\u{0C}"))
        XCTAssertEqual(c.keybinds[KeyCombo([.cmd], "=")], .equalizeSplits)
        XCTAssertEqual(c.keybinds[KeyCombo([.ctrl], "=")], .resetFontSize)
        XCTAssertEqual(c.keybinds[KeyCombo([.ctrl], "a")], .sendText("a=b"))
        XCTAssertEqual(c.diagnostics.count, 1, "\(c.diagnostics)")
        var cleared = Config()
        cleared.parse("keybind = clear")
        XCTAssertTrue(cleared.keybinds.isEmpty)
    }

    func testDefaultBindingsCoverEssentials() {
        let d = Keybinds.defaults
        XCTAssertEqual(d[KeyCombo([.cmd], "t")], .newTab)
        XCTAssertEqual(d[KeyCombo([.cmd], "d")], .splitRight)
        XCTAssertEqual(d[KeyCombo([.cmd, .shift], "d")], .splitDown)
        XCTAssertEqual(d[KeyCombo([.cmd], "c")], .copy)
        XCTAssertEqual(d[KeyCombo([.cmd], "v")], .paste)
        XCTAssertEqual(d[KeyCombo([.cmd], "f")], .find)
        XCTAssertEqual(d[KeyCombo([.cmd, .alt], "i")], .toggleBroadcastTab)
        // Every default combo survives a description/parse round trip.
        for combo in d.keys {
            XCTAssertEqual(KeyCombo(parse: combo.description), combo, combo.description)
        }
    }

    func testUnescape() {
        XCTAssertEqual(Keybinds.unescape("a\\tb\\r\\n\\e\\\\\\x41"), "a\tb\r\n\u{1B}\\A")
        XCTAssertEqual(Keybinds.unescape("trailing\\"), "trailing\\")
    }
}

/// Live reload: the watcher must notice changes even when the config directory didn't exist when it
/// started (a real bug: the user's first config edits were ignored).
final class ConfigWatcherTests: XCTestCase {
    var dir: URL!
    var previousXDG: String?

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vitterm-watch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        previousXDG = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        setenv("XDG_CONFIG_HOME", dir.path, 1)
    }

    override func tearDown() {
        if let p = previousXDG { setenv("XDG_CONFIG_HOME", p, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        try? FileManager.default.removeItem(at: dir)
    }

    func testDetectsConfigCreatedAfterStart() throws {
        XCTAssertEqual(Config.configFile.path, dir.appendingPathComponent("vitterm/config").path)
        let fired = expectation(description: "reload")
        fired.assertForOverFulfill = false
        let watcher = ConfigWatcher { fired.fulfill() }
        // The vitterm directory doesn't exist yet when watching starts.
        try FileManager.default.createDirectory(at: Config.configDirectory, withIntermediateDirectories: true)
        try "font-size = 20\n".write(to: Config.configFile, atomically: true, encoding: .utf8)
        wait(for: [fired], timeout: 5)
        XCTAssertEqual(Config.load().fontSize, 20)
        withExtendedLifetime(watcher) {}
    }

    func testDetectsEditsAndAtomicReplacement() throws {
        try FileManager.default.createDirectory(at: Config.configDirectory, withIntermediateDirectories: true)
        try "font-size = 12\n".write(to: Config.configFile, atomically: false, encoding: .utf8)
        var fires = 0
        let watcher = ConfigWatcher { fires += 1 }
        let first = expectation(description: "in-place edit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? "font-size = 13\n".write(to: Config.configFile, atomically: false, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { first.fulfill() }
        wait(for: [first], timeout: 5)
        XCTAssertGreaterThanOrEqual(fires, 1)
        // Editors often write a new file and rename it over the old one.
        let before = fires
        let second = expectation(description: "atomic replace")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? "font-size = 14 # replaced\n".write(to: Config.configFile, atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { second.fulfill() }
        wait(for: [second], timeout: 5)
        XCTAssertGreaterThan(fires, before)
        XCTAssertEqual(Config.load().fontSize, 14)
        withExtendedLifetime(watcher) {}
    }

    /// Editing a user theme in place (no directory change) must still reload, without polling.
    func testDetectsInPlaceThemeEdit() throws {
        try FileManager.default.createDirectory(at: Themes.userDirectory, withIntermediateDirectories: true)
        let theme = Themes.userDirectory.appendingPathComponent("mine")
        try "background = #000000\n".write(to: theme, atomically: false, encoding: .utf8)
        var fires = 0
        let watcher = ConfigWatcher { fires += 1 }
        let done = expectation(description: "theme edit")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let h = try? FileHandle(forWritingTo: theme) { h.seekToEndOfFile(); h.write(Data("foreground = #ffffff\n".utf8)); try? h.close() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(fires, 1)
        withExtendedLifetime(watcher) {}
    }

    /// The whole chain may be missing at launch (no ~/.config/vitterm, no themes directory).
    func testDetectsThemeDirectoryCreatedAfterStart() throws {
        var fires = 0
        let watcher = ConfigWatcher { fires += 1 }
        let done = expectation(description: "themes created")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? FileManager.default.createDirectory(at: Themes.userDirectory, withIntermediateDirectories: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            try? "background = #111111\n".write(to: Themes.userDirectory.appendingPathComponent("late"), atomically: true, encoding: .utf8)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertGreaterThanOrEqual(fires, 1)
        withExtendedLifetime(watcher) {}
    }

    func testUserThemeOverridesBundledTheme() throws {
        try FileManager.default.createDirectory(at: Themes.userDirectory, withIntermediateDirectories: true)
        try "background = #010203\nforeground = #fefefe\n".write(to: Themes.userDirectory.appendingPathComponent("Nord"),
                                                                  atomically: true, encoding: .utf8)
        XCTAssertEqual(Themes.named("Nord")?.background, 0x010203)
        XCTAssertTrue(Themes.available().contains("Nord"))
    }
}
