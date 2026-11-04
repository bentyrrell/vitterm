import AppKit
import VitConfig

/// A terminal window: a themed titlebar with a custom tab strip, and the selected tab's panes.
final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    private let root = NSView()
    private let titlebarFill = NSView()
    private var blurView: NSVisualEffectView?
    let tabStrip = TabStripView()
    /// Lock shown in the titlebar while secure keyboard entry is on.
    private let secureIndicator: NSImageView = {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Keyboard Entry")
        v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        v.contentTintColor = .secondaryLabelColor
        v.isHidden = true
        return v
    }()
    private static let indicatorSize: CGFloat = 16
    private var contentLayoutObserver: NSKeyValueObservation?

    private(set) var tabs: [TabController] = []
    private(set) weak var selectedTab: TabController?

    var focusedSurface: SurfaceView? { selectedTab?.focusedSurface }

    init(tab: TabController) {
        StartupTrace.mark("window controller init")
        let config = AppDelegate.shared.config
        // Size the window from the configured columns/rows.
        let surface = tab.surfaces[0]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let cw = CGFloat(surface.renderer.cellWidth) / scale, ch = CGFloat(surface.renderer.cellHeight) / scale
        let size = NSSize(width: CGFloat(config.windowColumns) * cw + 2 * config.windowPaddingX,
                          height: CGFloat(config.windowRows) * ch + 2 * config.windowPaddingY)
        let window = TerminalWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.title = "vitterm"
        window.minSize = NSSize(width: 240, height: 120)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Optional (empty) toolbar for a taller, toolbar-style titlebar. The default "native" style
        // matches standard macOS terminal windows.
        let style = config.titlebarStyle
        if style == "compact" || style == "unified" {
            let toolbar = NSToolbar(identifier: "vitterm.titlebar")
            toolbar.showsBaselineSeparator = false
            toolbar.displayMode = .iconOnly
            window.toolbar = toolbar
            window.toolbarStyle = style == "unified" ? .unified : .unifiedCompact
        }
        super.init(window: window)
        window.delegate = self

        root.frame = NSRect(origin: .zero, size: size)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        titlebarFill.autoresizingMask = [.width, .minYMargin]
        root.addSubview(titlebarFill)
        tabStrip.controller = self
        tabStrip.isHidden = true
        root.addSubview(tabStrip)
        root.addSubview(secureIndicator)
        window.contentView = root
        NotificationCenter.default.addObserver(self, selector: #selector(secureInputChanged(_:)), name: SecureInput.didChange, object: nil)

        // The content view spans the (transparent) titlebar; keep the terminal below it so text never
        // sits under the traffic lights or title. Grow the window so the configured grid still fits.
        let titlebar = window.frame.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(width: size.width, height: size.height + titlebar))
        contentLayoutObserver = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.layoutContainer() }
        }

        addTab(tab)
        updateSecureIndicator()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Tabs

    func addTab(_ tab: TabController, at index: Int? = nil) {
        tab.windowController = self
        let i = index ?? (selectedTab.flatMap { s in tabs.firstIndex { $0 === s } }.map { $0 + 1 } ?? tabs.count)
        tabs.insert(tab, at: min(i, tabs.count))
        selectTab(tab)
    }

    func selectTab(_ tab: TabController) {
        guard let window else { return }
        let old = selectedTab
        if old !== tab {
            old?.container.removeFromSuperview()
            selectedTab = tab
            root.addSubview(tab.container, positioned: .below, relativeTo: tabStrip)
            layoutContainer()
            tab.container.layoutSubtreeIfNeeded()
        }
        tab.hasActivity = false
        tab.hasBell = false
        if let s = tab.focusedSurface ?? tab.surfaces.first {
            window.makeFirstResponder(s)
            tab.container.layoutSubtreeIfNeeded()
            s.renderInitialFrame()
            s.requestRender()
        }
        applyAppearance()
        tabChanged(tab)
        AppDelegate.shared.updateBroadcastMenu()
    }

    func selectTab(index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectTab(tabs[index])
    }

    func selectTab(offset: Int) {
        guard let s = selectedTab, let i = tabs.firstIndex(where: { $0 === s }), !tabs.isEmpty else { return }
        selectTab(tabs[(i + offset + tabs.count) % tabs.count])
    }

    func moveTab(_ tab: TabController, to index: Int) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: i)
        tabs.insert(tab, at: max(0, min(index, tabs.count)))
        refreshTabStrip()
    }

    func closeTab(_ tab: TabController, confirm: Bool) {
        let running = tab.runningSurfaces
        if confirm && !running.isEmpty {
            self.confirm(message: "Close this tab?", info: Set(running.compactMap { $0.pty?.foregroundProcessName }).sorted().joined(separator: ", ") + " is still running.") { [weak self] in
                self?.closeTab(tab, confirm: false)
            }
            return
        }
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.terminate()
        tab.container.removeFromSuperview()
        tabs.remove(at: i)
        if tabs.isEmpty {
            window?.close()
            return
        }
        if selectedTab === tab {
            selectedTab = nil
            selectTab(tabs[min(i, tabs.count - 1)])
        } else {
            refreshTabStrip()
        }
    }

    /// Detach a tab into its own window.
    func moveTabToNewWindow(_ tab: TabController) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.container.removeFromSuperview()
        tabs.remove(at: i)
        if selectedTab === tab { selectedTab = nil; selectTab(tabs[min(i, tabs.count - 1)]) } else { refreshTabStrip() }
        let wc = TerminalWindowController(tab: tab)
        AppDelegate.shared.adopt(wc)
        if let w = window, let nw = wc.window {
            nw.setFrameTopLeftPoint(NSPoint(x: w.frame.minX + 30, y: w.frame.maxY - 30))
        }
        wc.showWindow(nil)
    }

    /// Pull every tab from the other windows into this one.
    @objc func mergeAllWindowsMenu(_ sender: Any?) {
        for wc in AppDelegate.shared.windows where wc !== self {
            for t in wc.tabs {
                t.container.removeFromSuperview()
                tabs.append(t)
                t.windowController = self
            }
            wc.tabs.removeAll()
            wc.window?.close()
        }
        refreshTabStrip()
    }

    /// A tab's title, selection, or status changed.
    func tabChanged(_ tab: TabController) {
        if tab === selectedTab { updateTitle() }
        refreshTabStrip()
    }

    func updateTitle() {
        guard let tab = selectedTab else { return }
        let anyBroadcast = tab.surfaces.contains { $0.broadcastEnabled }
        window?.title = anyBroadcast ? "📡 " + tab.windowTitle : tab.windowTitle
        if let d = tab.focusedSurface?.cwd { window?.representedURL = URL(fileURLWithPath: d) }
    }

    func refreshTabStrip() {
        guard let window else { return }
        let showTabs = tabs.count > 1
        window.titleVisibility = showTabs ? .hidden : .visible
        // Hide the proxy icon too when the strip takes over the titlebar row.
        window.standardWindowButton(.documentIconButton)?.isHidden = showTabs
        if tabStrip.isHidden == showTabs {
            tabStrip.isHidden = !showTabs
            layoutContainer()
        }
        if let t = selectedTab { tabStrip.colors = TabStripColors.from(t) }
        tabStrip.reload()
    }

    // MARK: Layout & appearance

    /// Fit the selected tab below the titlebar; the tab strip shares the titlebar row with the
    /// traffic lights (or gets its own row in full screen, where there is no titlebar).
    func layoutContainer() {
        guard let window else { return }
        var r = window.contentLayoutRect.intersection(root.bounds)
        let fullScreen = window.styleMask.contains(.fullScreen)
        // The strip fills the titlebar so its pills are centered on the traffic lights.
        let titlebarH = root.bounds.maxY - r.maxY
        let stripH = fullScreen ? TabStripView.height : max(TabStripView.height, titlebarH)
        // The lock sits at the right end of the titlebar row (the tab strip's row in full screen).
        let lockW: CGFloat = secureIndicator.isHidden ? 0 : TerminalWindowController.indicatorSize + 8
        if !tabStrip.isHidden {
            if fullScreen || titlebarH < stripH { r.size.height = root.bounds.maxY - stripH - r.minY }
            let left: CGFloat = fullScreen ? 8 : trafficLightsMaxX + 12
            tabStrip.frame = NSRect(x: left, y: root.bounds.maxY - stripH, width: max(0, root.bounds.width - left - 8 - lockW), height: stripH)
        }
        if !secureIndicator.isHidden {
            let rowH = tabStrip.isHidden ? max(titlebarH, TerminalWindowController.indicatorSize) : stripH
            let s = TerminalWindowController.indicatorSize
            secureIndicator.frame = NSRect(x: root.bounds.maxX - s - 10, y: (root.bounds.maxY - rowH + (rowH - s) / 2).rounded(), width: s, height: s)
        }
        if let c = selectedTab?.container, c.frame != r { c.frame = r }
        titlebarFill.frame = NSRect(x: 0, y: r.maxY, width: root.bounds.width, height: max(0, root.bounds.maxY - r.maxY))
    }

    @objc private func secureInputChanged(_ n: Notification) { updateSecureIndicator() }

    func updateSecureIndicator() {
        let on = SecureInput.shared.isEnabled
        secureIndicator.toolTip = on ? SecureInput.shared.statusDescription : nil
        guard secureIndicator.isHidden == on else { return }
        secureIndicator.isHidden = !on
        layoutContainer()
    }

    private var trafficLightsMaxX: CGFloat {
        guard let b = window?.standardWindowButton(.zoomButton), let sv = b.superview else { return 70 }
        return sv.convert(b.frame, to: nil).maxX
    }

    func windowDidEnterFullScreen(_ notification: Notification) { layoutContainer() }
    func windowDidExitFullScreen(_ notification: Notification) { layoutContainer() }

    /// Window background, transparency, blur and titlebar color from the theme.
    func applyAppearance() {
        guard let window, let tab = selectedTab, let s = tab.surfaces.first else { return }
        let c = AppDelegate.shared.config
        let bg = s.theme.background
        let color = NSColor(srgbRed: CGFloat(bg >> 16 & 0xFF) / 255, green: CGFloat(bg >> 8 & 0xFF) / 255, blue: CGFloat(bg & 0xFF) / 255, alpha: 1)
        window.appearance = NSAppearance(named: s.theme.isDark ? .darkAqua : .aqua)
        let transparent = c.backgroundOpacity < 1
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : color
        for t in tabs {
            t.container.dividerColor = s.theme.isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.15)
            t.container.wantsLayer = true
            t.container.layer?.backgroundColor = transparent ? NSColor.clear.cgColor : color.cgColor
        }
        // Paint the titlebar with the terminal background (same opacity) so the window reads as one surface.
        titlebarFill.wantsLayer = true
        titlebarFill.layer?.backgroundColor = color.withAlphaComponent(transparent ? c.backgroundOpacity : 1).cgColor
        tabStrip.colors = TabStripColors.from(tab)
        if transparent && c.backgroundBlur > 0 {
            if blurView == nil {
                let v = NSVisualEffectView(frame: root.bounds)
                v.autoresizingMask = [.width, .height]
                v.blendingMode = .behindWindow
                v.state = .active
                v.material = .hudWindow
                root.addSubview(v, positioned: .below, relativeTo: titlebarFill)
                blurView = v
            }
        } else {
            blurView?.removeFromSuperview()
            blurView = nil
        }
    }

    func applyConfig(_ c: Config) {
        for t in tabs { t.applyConfig(c) }
        applyAppearance()
        refreshTabStrip()
    }

    // MARK: Window delegate

    func windowDidBecomeKey(_ notification: Notification) {
        AppDelegate.shared.lastActiveWindow = self
        for s in selectedTab?.surfaces ?? [] { s.windowFocusChanged(true) }
        AppDelegate.shared.updateBroadcastMenu()
    }

    func windowDidResignKey(_ notification: Notification) {
        for s in selectedTab?.surfaces ?? [] { s.windowFocusChanged(false) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let running = tabs.flatMap { $0.runningSurfaces }
        guard !running.isEmpty else { return true }
        confirm(message: tabs.count > 1 ? "Close this window and all its tabs?" : "Close this window?",
                info: Set(running.compactMap { $0.pty?.foregroundProcessName }).sorted().joined(separator: ", ") + " is still running.") { [weak self] in
            guard let self else { return }
            for t in self.tabs { t.terminate() }
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        for t in tabs { t.terminate() }
        AppDelegate.shared.windowClosed(self)
    }

    func confirm(message: String, info: String, then: @escaping () -> Void) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.addButton(withTitle: "Close")
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { then() } }
    }

    // MARK: Menu targets (responder chain)

    private func act(_ a: Action) {
        guard let t = selectedTab, let s = t.focusedSurface ?? t.surfaces.first else { return }
        t.perform(a, from: s)
    }

    @objc func splitRight(_ sender: Any?) { act(.splitRight) }
    @objc func splitDown(_ sender: Any?) { act(.splitDown) }
    @objc func newTabMenu(_ sender: Any?) { act(.newTab) }
    @objc func closeSurfaceMenu(_ sender: Any?) { act(.closeSurface) }
    @objc func closeTabMenu(_ sender: Any?) { act(.closeTab) }
    @objc func nextTabMenu(_ sender: Any?) { selectTab(offset: 1) }
    @objc func previousTabMenu(_ sender: Any?) { selectTab(offset: -1) }
    @objc func moveTabToNewWindowMenu(_ sender: Any?) { if let t = selectedTab { moveTabToNewWindow(t) } }
    @objc func toggleBroadcastTabMenu(_ sender: Any?) { act(.toggleBroadcastTab) }
    @objc func toggleZoomMenu(_ sender: Any?) { act(.toggleSplitZoom) }
    @objc func equalizeMenu(_ sender: Any?) { act(.equalizeSplits) }
    @objc func findMenu(_ sender: Any?) { focusedSurface?.showSearch() }
    @objc func findNextMenu(_ sender: Any?) { focusedSurface?.findNext(forward: true) }
    @objc func findPreviousMenu(_ sender: Any?) { focusedSurface?.findNext(forward: false) }
    @objc func biggerMenu(_ sender: Any?) { focusedSurface?.perform(.increaseFontSize) }
    @objc func smallerMenu(_ sender: Any?) { focusedSurface?.perform(.decreaseFontSize) }
    @objc func actualSizeMenu(_ sender: Any?) { focusedSurface?.perform(.resetFontSize) }
    @objc func clearMenu(_ sender: Any?) { focusedSurface?.perform(.clearScreen) }
    @objc func resetTerminalMenu(_ sender: Any?) { focusedSurface?.perform(.resetTerminal) }
    @objc func focusLeftMenu(_ sender: Any?) { act(.focusSplit(.left)) }
    @objc func focusRightMenu(_ sender: Any?) { act(.focusSplit(.right)) }
    @objc func focusUpMenu(_ sender: Any?) { act(.focusSplit(.up)) }
    @objc func focusDownMenu(_ sender: Any?) { act(.focusSplit(.down)) }
}
