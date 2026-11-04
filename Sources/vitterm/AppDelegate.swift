import AppKit
import VitConfig
import VitRender

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    nonisolated(unsafe) static var shared: AppDelegate!

    var config = Config.load()
    private(set) var windows: [TerminalWindowController] = []
    weak var lastActiveWindow: TerminalWindowController?
    /// Every tab in every window.
    var controllers: [TabController] { windows.flatMap { $0.tabs } }
    /// The selected tab of the most recently active window.
    var lastActiveController: TabController? { (lastActiveWindow ?? windows.last)?.selectedTab }
    private var watcher: ConfigWatcher?
    private var appearanceObserver: NSKeyValueObservation?
    private var broadcastMenuItem: NSMenuItem?

    static func main() {
        StartupTrace.mark("main")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        AppDelegate.shared = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupTrace.mark("didFinishLaunching")
        NSWindow.allowsAutomaticWindowTabbing = false
        buildMenu()
        StartupTrace.mark("menu built")
        watcher = ConfigWatcher { [weak self] in self?.reloadConfig() }
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self, self.config.themeLight != nil || self.config.themeDark != nil else { return }
            DispatchQueue.main.async { self.applyConfigToAll() }
        }
        let args = CommandLine.arguments
        var command: String? = nil
        if let i = args.firstIndex(of: "-e"), i + 1 < args.count {
            command = args[(i + 1)...].joined(separator: " ")
        }
        newWindow(cwd: nil, command: command)
        StartupTrace.mark("window shown")
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.scheduleIfRequested()
        showDiagnosticsIfNeeded()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(cwd: nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = controllers.flatMap { $0.surfaces }.filter { $0.needsCloseConfirmation }
        guard !running.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "Quit vitterm?"
        let names = Set(running.compactMap { $0.pty?.foregroundProcessName }).sorted().joined(separator: ", ")
        a.informativeText = "\(running.count) pane\(running.count == 1 ? " has" : "s have") running processes (\(names))."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for s in controllers.flatMap({ $0.surfaces }) { s.terminate() }
    }

    // MARK: Windows

    @discardableResult
    func newWindow(cwd: String?, command: String? = nil) -> TerminalWindowController {
        let dir = cwd ?? initialDirectory()
        let c = TerminalWindowController(tab: TabController(cwd: dir, command: command))
        if let last = lastActiveWindow?.window, let w = c.window {
            // Cascade from the last window.
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 24, y: last.frame.maxY - 24))
        }
        adopt(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        return c
    }

    /// Start tracking a window controller (new windows, tabs moved to their own window).
    func adopt(_ c: TerminalWindowController) {
        windows.append(c)
        lastActiveWindow = c
    }

    func newTab(in parent: TabController?, cwd: String?) {
        guard let wc = parent?.windowController ?? lastActiveWindow ?? windows.last else {
            newWindow(cwd: cwd)
            return
        }
        wc.addTab(TabController(cwd: cwd ?? initialDirectory()))
        wc.window?.makeKeyAndOrderFront(nil)
    }

    func refreshTabStrips() {
        for w in windows { w.refreshTabStrip() }
    }

    private func initialDirectory() -> String? {
        switch config.workingDirectory {
        case "home": return NSHomeDirectory()
        case "inherit":
            if let d = lastActiveController?.focusedSurface?.currentDirectory { return d }
            let pwd = FileManager.default.currentDirectoryPath
            // Launched from Finder/Dock the cwd is "/", which is never what the user wants.
            return pwd == "/" ? NSHomeDirectory() : pwd
        default:
            return (config.workingDirectory as NSString).expandingTildeInPath
        }
    }

    func windowClosed(_ c: TerminalWindowController) {
        windows.removeAll { $0 === c }
        if lastActiveWindow === c { lastActiveWindow = windows.last }
        updateBroadcastMenu()
    }

    // MARK: Broadcast

    /// Every pane (in any window or tab) that has broadcast input enabled.
    func broadcastTargets() -> [SurfaceView] {
        controllers.flatMap { $0.surfaces }.filter { $0.broadcastEnabled }
    }

    func toggleBroadcastAll() {
        let all = controllers.flatMap { $0.surfaces }
        let enable = !all.allSatisfy { $0.broadcastEnabled }
        for s in all { s.broadcastEnabled = enable }
        for c in controllers { c.updateBroadcastState() }
        updateBroadcastMenu()
    }

    func updateBroadcastMenu() {
        let surfaces = lastActiveController?.surfaces ?? []
        broadcastMenuItem?.state = !surfaces.isEmpty && surfaces.allSatisfy { $0.broadcastEnabled } ? .on : .off
    }

    @objc func toggleBroadcastAllMenu(_ sender: Any?) { toggleBroadcastAll() }

    // MARK: Config

    func reloadConfig() {
        config = Config.load()
        MetalContext.shared.purgeFonts()
        applyConfigToAll()
        showDiagnosticsIfNeeded()
    }

    private func applyConfigToAll() {
        for w in windows { w.applyConfig(config) }
    }

    private func showDiagnosticsIfNeeded() {
        for (key, family) in [("font-family", config.fontFamily), ("font-family-bold", config.fontFamilyBold),
                              ("font-family-italic", config.fontFamilyItalic)] where !family.isEmpty {
            if NSFontManager.shared.availableMembers(ofFontFamily: family) == nil && NSFont(name: family, size: 12) == nil {
                config.diagnostics.append("\(key): font '\(family)' is not installed")
            }
        }
        // Show each distinct set of problems once (not again on every save while editing), as a
        // sheet on the terminal window so nothing else is blocked.
        guard !config.diagnostics.isEmpty else { lastShownDiagnostics = []; return }
        guard config.diagnostics != lastShownDiagnostics else { return }
        guard let window = (lastActiveWindow ?? windows.last)?.window, window.attachedSheet == nil else { return }
        lastShownDiagnostics = config.diagnostics
        let a = NSAlert()
        a.messageText = "Problems in vitterm config"
        a.informativeText = config.diagnostics.prefix(12).joined(separator: "\n") + "\n\n" + Config.configFile.path
        a.alertStyle = .warning
        a.addButton(withTitle: "OK")
        a.addButton(withTitle: "Open Config")
        a.beginSheetModal(for: window) { [weak self] r in
            if r == .alertSecondButtonReturn { self?.openConfig(nil) }
        }
    }
    private var lastShownDiagnostics: [String] = []

    @objc func openConfig(_ sender: Any?) {
        let url = Config.configFile
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: Config.configDirectory, withIntermediateDirectories: true)
            try? AppDelegate.configTemplate.write(to: url, atomically: true, encoding: .utf8)
        }
        // Open as plain text so it doesn't launch Xcode or similar for an extensionless file.
        let editor = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: "/tmp/x.txt"))
        if let editor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func reloadConfigMenu(_ sender: Any?) { reloadConfig() }
    @objc func newWindowMenu(_ sender: Any?) { newWindow(cwd: lastActiveController?.focusedSurface?.currentDirectory) }
    @objc func newTabFallback(_ sender: Any?) { newTab(in: lastActiveController, cwd: nil) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureKeyboardEntry(_:)) { item.state = SecureInput.shared.manual ? .on : .off }
        return true
    }

    @objc func toggleSecureKeyboardEntry(_ sender: Any?) { SecureInput.shared.manual.toggle() }

    func applicationDidBecomeActive(_ notification: Notification) {
        lastActiveController?.focusedSurface?.updatePasswordPrompt()
        SecureInput.shared.update()
    }

    func applicationDidResignActive(_ notification: Notification) { SecureInput.shared.update() }

    static let configTemplate = """
    # vitterm configuration. Changes are applied automatically when you save.
    # Syntax: key = value. Lines starting with # are comments.

    # font-family = JetBrains Mono
    # font-size = 13
    # font-ligatures = true
    # font-feature = ss01
    # font-thicken = false
    # adjust-cell-height = 2

    # theme = Vit Dark
    # theme = light:Vit Light,dark:Vit Dark
    # Available: \(Themes.available().joined(separator: ", "))

    # background-opacity = 0.95
    # background-blur = 20
    # window-padding-x = 10
    # window-padding-y = 6
    # window-width = 110
    # window-height = 32
    # unfocused-split-opacity = 0.85
    # titlebar-style = native    # native | compact | unified (applies to new windows)

    # cursor-style = block      # block | bar | underline
    # cursor-blink = true         # stops after 15 s without typing, to save power
    # cursor-blink-interval = 550   # milliseconds

    # Animated cursor trail when the cursor jumps.
    # cursor-trail = true
    # cursor-trail-color = theme     # theme | cursor | magenta | bright-blue | palette:5 | #d33682
    # cursor-trail-opacity = 0.6
    # cursor-trail-decay = 100, 400  # fast, slow (ms)
    # cursor-trail-threshold = 2     # cells; shorter moves (typing) don't animate

    # scrollback-limit = 10000
    # option-as-alt = left       # none | left | right | both
    # copy-on-select = false
    # confirm-close = true
    # clipboard-read = deny          # allow | ask | deny (OSC 52 reads of your clipboard)
    # desktop-notifications = true  # let programs post notifications (OSC 9 / OSC 777)
    # clipboard-write = allow       # allow | ask | deny (OSC 52 copies from programs)
    # image-file-transfer = true    # let Kitty-protocol images be read from local files
    # shell-integration = true
    # bell = none                # none, visual (flash the pane), audible, or "visual audible"
    # working-directory = inherit

    # Key bindings: keybind = <mods>+<key>=<action>
    # keybind = cmd+d=new_split:right
    # keybind = cmd+shift+d=new_split:down
    # keybind = cmd+alt+i=toggle_broadcast
    # keybind = ctrl+shift+t=new_tab
    # keybind = cmd+k=clear_screen
    # keybind = cmd+shift+k=text:\\x0c
    """

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        func item(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            m.addItem(i)
            return i
        }
        func submenu(_ title: String) -> NSMenu {
            let m = NSMenu(title: title)
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = m
            main.addItem(i)
            return m
        }

        let app = submenu("vitterm")
        _ = item(app, "About vitterm", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        _ = item(app, "Settings…", #selector(openConfig(_:)), ",", target: self)
        _ = item(app, "Reload Configuration", #selector(reloadConfigMenu(_:)), ",", [.command, .shift], target: self)
        app.addItem(.separator())
        _ = item(app, "Secure Keyboard Entry", #selector(toggleSecureKeyboardEntry(_:)), target: self)
        app.addItem(.separator())
        let services = NSMenu()
        let si = item(app, "Services", nil)
        si.submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        _ = item(app, "Hide vitterm", #selector(NSApplication.hide(_:)), "h")
        _ = item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        _ = item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        app.addItem(.separator())
        _ = item(app, "Quit vitterm", #selector(NSApplication.terminate(_:)), "q")

        let shell = submenu("Shell")
        _ = item(shell, "New Window", #selector(newWindowMenu(_:)), "n", target: self)
        _ = item(shell, "New Tab", #selector(TerminalWindowController.newTabMenu(_:)), "t")
        shell.addItem(.separator())
        _ = item(shell, "Split Right", #selector(TerminalWindowController.splitRight(_:)), "d")
        _ = item(shell, "Split Down", #selector(TerminalWindowController.splitDown(_:)), "d", [.command, .shift])
        shell.addItem(.separator())
        _ = item(shell, "Close", #selector(TerminalWindowController.closeSurfaceMenu(_:)), "w")
        _ = item(shell, "Close Tab", #selector(TerminalWindowController.closeTabMenu(_:)), "w", [.command, .shift])
        _ = item(shell, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .option])

        let edit = submenu("Edit")
        _ = item(edit, "Undo", Selector(("undo:")), "z")
        _ = item(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        _ = item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        _ = item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        _ = item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        _ = item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let fi = item(edit, "Find", nil)
        fi.submenu = find
        _ = item(find, "Find…", #selector(TerminalWindowController.findMenu(_:)), "f")
        _ = item(find, "Find Next", #selector(TerminalWindowController.findNextMenu(_:)), "g")
        _ = item(find, "Find Previous", #selector(TerminalWindowController.findPreviousMenu(_:)), "g", [.command, .shift])

        let view = submenu("View")
        _ = item(view, "Bigger", #selector(TerminalWindowController.biggerMenu(_:)), "=")
        _ = item(view, "Smaller", #selector(TerminalWindowController.smallerMenu(_:)), "-")
        _ = item(view, "Actual Size", #selector(TerminalWindowController.actualSizeMenu(_:)), "0")
        view.addItem(.separator())
        _ = item(view, "Zoom Split", #selector(TerminalWindowController.toggleZoomMenu(_:)), "\r", [.command, .shift])
        _ = item(view, "Equalize Splits", #selector(TerminalWindowController.equalizeMenu(_:)), "=", [.command, .control])
        view.addItem(.separator())
        _ = item(view, "Clear Screen", #selector(TerminalWindowController.clearMenu(_:)), "k")
        _ = item(view, "Reset Terminal", #selector(TerminalWindowController.resetTerminalMenu(_:)), "")
        view.addItem(.separator())
        _ = item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu("Window")
        broadcastMenuItem = item(window, "Broadcast Input to All Panes in Tab", #selector(TerminalWindowController.toggleBroadcastTabMenu(_:)), "i", [.command, .option])
        _ = item(window, "Broadcast Input to All Panes Everywhere", #selector(toggleBroadcastAllMenu(_:)), "", target: self)
        window.addItem(.separator())
        _ = item(window, "Select Split Left", #selector(TerminalWindowController.focusLeftMenu(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command, .option])
        _ = item(window, "Select Split Right", #selector(TerminalWindowController.focusRightMenu(_:)), String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command, .option])
        _ = item(window, "Select Split Above", #selector(TerminalWindowController.focusUpMenu(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option])
        _ = item(window, "Select Split Below", #selector(TerminalWindowController.focusDownMenu(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option])
        window.addItem(.separator())
        _ = item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        _ = item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        _ = item(window, "Show Previous Tab", #selector(TerminalWindowController.previousTabMenu(_:)), "[", [.command, .shift])
        _ = item(window, "Show Next Tab", #selector(TerminalWindowController.nextTabMenu(_:)), "]", [.command, .shift])
        _ = item(window, "Move Tab to New Window", #selector(TerminalWindowController.moveTabToNewWindowMenu(_:)))
        _ = item(window, "Merge All Windows", #selector(TerminalWindowController.mergeAllWindowsMenu(_:)))
        window.addItem(.separator())
        _ = item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = window

        let help = submenu("Help")
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }
}
