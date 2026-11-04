import AppKit
import VitConfig

/// One tab: a tree of split panes shown in a `SplitContainerView`. Tabs live inside a
/// `TerminalWindowController`, which owns the window and the tab strip.
final class TabController: NSObject {
    let container = SplitContainerView()
    var tree: SplitNode
    private(set) weak var focusedSurface: SurfaceView?
    weak var windowController: TerminalWindowController?

    /// Output / bell since the tab was last selected (drives the tab strip's status dot).
    var hasActivity = false
    var hasBell = false
    private let created = CACurrentMediaTime()

    var window: NSWindow? { windowController?.window }
    var surfaces: [SurfaceView] { tree.leaves }
    var hasMultiplePanes: Bool { surfaces.count > 1 }
    var isSelected: Bool { windowController?.selectedTab === self }

    init(cwd: String?, command: String? = nil) {
        StartupTrace.mark("tab init")
        let surface = SurfaceView(config: AppDelegate.shared.config, workingDirectory: cwd, command: command)
        StartupTrace.mark("surface created (fonts, Metal, PTY)")
        tree = SplitNode(surface: surface)
        super.init()
        container.autoresizingMask = [.width, .height]
        attach(surface)
        container.root = tree
        focusedSurface = surface
    }

    private func attach(_ s: SurfaceView) {
        s.controller = self
        s.onExit = { [weak self] surface in self?.remove(surface) }
    }

    func applyConfig(_ c: Config) {
        for s in surfaces { s.applyConfig(c) }
        container.dividerColor = (surfaces.first?.theme.isDark ?? true) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.15)
    }

    func terminate() {
        for s in surfaces { s.terminate() }
    }

    var runningSurfaces: [SurfaceView] { surfaces.filter { $0.needsCloseConfirmation } }

    // MARK: Titles

    /// Full title for the window: the focused pane's title or working directory.
    var windowTitle: String {
        guard let s = focusedSurface ?? surfaces.first else { return "vitterm" }
        var t = s.title
        if t == "vitterm" || t.isEmpty, let d = s.cwd { t = (d as NSString).abbreviatingWithTildeInPath }
        return t
    }

    /// Short label for the tab strip: last path component for directory titles.
    var tabTitle: String {
        let t = windowTitle
        if t.hasPrefix("/") || t.hasPrefix("~/") {
            let last = (t as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        return t
    }

    func surfaceDidFocus(_ s: SurfaceView) {
        guard focusedSurface !== s else { return }
        let old = focusedSurface
        focusedSurface = s
        old?.requestRender()
        s.requestRender()
        windowController?.tabChanged(self)
    }

    func surfaceTitleChanged(_ s: SurfaceView) {
        if s === focusedSurface { windowController?.tabChanged(self) }
    }

    /// Called when a pane in this tab produces output or rings the bell.
    func noteActivity(bell: Bool = false) {
        guard !isSelected, CACurrentMediaTime() - created > 1.5 else { return }
        if bell { guard !hasBell else { return }; hasBell = true } else { guard !hasActivity else { return }; hasActivity = true }
        windowController?.refreshTabStrip()
    }

    // MARK: Closing panes

    func close(surface s: SurfaceView, confirmIfRunning: Bool = true) {
        if confirmIfRunning && s.needsCloseConfirmation {
            windowController?.confirm(message: "Close this pane?", info: "\(s.pty?.foregroundProcessName ?? "A process") is still running.") { [weak self] in
                self?.close(surface: s, confirmIfRunning: false)
            }
            return
        }
        s.terminate()
        remove(s)
    }

    private func remove(_ s: SurfaceView) {
        guard let node = tree.find(s) else { return }
        if container.zoomed === s { container.zoomed = nil }
        guard let parent = node.parent else {
            // Last pane: the tab goes away.
            windowController?.closeTab(self, confirm: false)
            return
        }
        let sibling = parent.first === node ? parent.second! : parent.first!
        if let gp = parent.parent {
            if gp.first === parent { gp.first = sibling } else { gp.second = sibling }
            sibling.parent = gp
        } else {
            tree = sibling
            sibling.parent = nil
        }
        s.removeFromSuperview()
        container.root = tree
        focusedSurface = nil
        if let n = sibling.leaves.first {
            if isSelected { window?.makeFirstResponder(n) }
            surfaceDidFocus(n)
        }
        for v in surfaces { v.requestRender() }
    }

    // MARK: Splits

    func split(_ dir: Direction) {
        guard let current = focusedSurface ?? surfaces.first, let node = tree.find(current) else { return }
        if container.zoomed != nil { container.zoomed = nil }
        let new = SurfaceView(config: AppDelegate.shared.config, workingDirectory: current.currentDirectory)
        new.fontSize = current.fontSize
        attach(new)
        new.broadcastEnabled = current.broadcastEnabled
        let leaf = SplitNode(surface: new)
        let existing = SplitNode(surface: current)
        let axis: SplitNode.Axis = (dir == .left || dir == .right) ? .horizontal : .vertical
        let newFirst = dir == .left || dir == .up
        node.surface = nil
        node.axis = axis
        node.ratio = 0.5
        node.first = newFirst ? leaf : existing
        node.second = newFirst ? existing : leaf
        leaf.parent = node
        existing.parent = node
        container.root = tree
        container.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(new)
        surfaceDidFocus(new)
        for v in surfaces { v.requestRender() }
    }

    func focusSplit(_ dir: Direction) {
        guard let cur = focusedSurface else { return }
        let f = cur.frame
        let c = NSPoint(x: f.midX, y: f.midY)
        var best: (SurfaceView, CGFloat)?
        for s in surfaces where s !== cur {
            let g = s.frame
            let ok: Bool
            switch dir {
            case .left: ok = g.maxX <= f.minX + 1 && g.maxY > f.minY && g.minY < f.maxY
            case .right: ok = g.minX >= f.maxX - 1 && g.maxY > f.minY && g.minY < f.maxY
            case .up: ok = g.maxY <= f.minY + 1 && g.maxX > f.minX && g.minX < f.maxX
            case .down: ok = g.minY >= f.maxY - 1 && g.maxX > f.minX && g.minX < f.maxX
            }
            guard ok else { continue }
            let d = hypot(g.midX - c.x, g.midY - c.y)
            if best == nil || d < best!.1 { best = (s, d) }
        }
        if let (s, _) = best {
            if container.zoomed != nil { container.zoomed = s }
            window?.makeFirstResponder(s)
            surfaceDidFocus(s)
        }
    }

    func resizeSplit(_ dir: Direction, by points: Int) {
        guard let cur = focusedSurface, var node = tree.find(cur) else { return }
        let axis: SplitNode.Axis = (dir == .left || dir == .right) ? .horizontal : .vertical
        while let p = node.parent {
            if p.axis == axis {
                let total = axis == .horizontal ? container.bounds.width : container.bounds.height
                let delta = CGFloat(points) / max(total, 1) * (dir == .left || dir == .up ? -1 : 1)
                p.ratio = min(max(p.ratio + delta, 0.08), 0.92)
                container.needsLayout = true
                return
            }
            node = p
        }
    }

    // MARK: Broadcast

    func toggleBroadcastTab() {
        let enable = !surfaces.allSatisfy { $0.broadcastEnabled }
        for s in surfaces { s.broadcastEnabled = enable }
        updateBroadcastState()
    }

    func updateBroadcastState() {
        windowController?.tabChanged(self)
        AppDelegate.shared.updateBroadcastMenu()
    }

    // MARK: Actions

    func perform(_ action: Action, from surface: SurfaceView) {
        let wc = windowController
        switch action {
        case .newTab: AppDelegate.shared.newTab(in: self, cwd: surface.currentDirectory)
        case .newWindow: AppDelegate.shared.newWindow(cwd: surface.currentDirectory)
        case .closeSurface: close(surface: surface)
        case .closeTab: wc?.closeTab(self, confirm: true)
        case .closeWindow: wc?.window?.performClose(nil)
        case .nextTab: wc?.selectTab(offset: 1)
        case .previousTab: wc?.selectTab(offset: -1)
        case .gotoTab(let n): wc?.selectTab(index: n - 1)
        case .lastTab: wc?.selectTab(index: (wc?.tabs.count ?? 1) - 1)
        case .splitRight: split(.right)
        case .splitDown: split(.down)
        case .splitLeft: split(.left)
        case .splitUp: split(.up)
        case .focusSplit(let d): focusSplit(d)
        case .resizeSplit(let d, let n): resizeSplit(d, by: n)
        case .equalizeSplits: tree.equalize(); container.needsLayout = true
        case .toggleSplitZoom:
            container.zoomed = container.zoomed == nil && hasMultiplePanes ? surface : nil
            window?.makeFirstResponder(surface)
        case .toggleBroadcastTab: toggleBroadcastTab()
        case .toggleFullscreen: window?.toggleFullScreen(nil)
        default: surface.perform(action)
        }
    }
}
