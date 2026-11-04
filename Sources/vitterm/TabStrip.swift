import AppKit

/// Theme colors for the tab strip, derived from the terminal theme.
struct TabStripColors {
    var background: NSColor
    var foreground: NSColor
    var accent: NSColor
    var bell: NSColor
    var isDark: Bool

    static func from(_ c: TabController) -> TabStripColors {
        guard let s = c.surfaces.first else {
            return TabStripColors(background: .windowBackgroundColor, foreground: .labelColor, accent: .controlAccentColor, bell: .systemRed, isDark: true)
        }
        let t = s.theme
        func ns(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return TabStripColors(background: ns(t.background), foreground: ns(t.foreground),
                              accent: ns(t.palette[4]), bell: ns(t.palette[1]), isDark: t.isDark)
    }

    /// Foreground blended into the background by `amount` (0...1), for fills that stay on-theme.
    func tint(_ amount: CGFloat) -> NSColor {
        background.blended(withFraction: amount, of: foreground) ?? background
    }
}

/// A custom tab bar drawn in the titlebar row, next to the traffic lights.
final class TabStripView: NSView {
    weak var controller: TerminalWindowController?
    private var items: [TabItemView] = []
    private let plus = TabIconButton(symbol: "plus", size: 11)
    static let height: CGFloat = 28
    private let pillHeight: CGFloat = 26
    private let spacing: CGFloat = 4

    // Drag-to-reorder state.
    private var dragging: TabItemView?
    private var dragOffset: CGFloat = 0
    private var dragStartX: CGFloat = 0
    private var didDrag = false

    var colors = TabStripColors(background: .black, foreground: .white, accent: .orange, bell: .red, isDark: true) {
        didSet { items.forEach { $0.colors = colors }; plus.colors = colors; needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.toolTip = "New Tab (⌘T)"
        plus.onClick = { [weak self] in
            guard let t = self?.controller?.selectedTab, let s = t.focusedSurface ?? t.surfaces.first else { return }
            t.perform(.newTab, from: s)
        }
        addSubview(plus)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    var tabControllers: [TabController] { controller?.tabs ?? [] }

    func reload() {
        let tabs = tabControllers
        while items.count < tabs.count {
            let v = TabItemView()
            v.strip = self
            v.colors = colors
            addSubview(v)
            items.append(v)
        }
        while items.count > tabs.count { items.removeLast().removeFromSuperview() }
        let selected = controller?.selectedTab
        for (i, c) in tabs.enumerated() {
            let v = items[i]
            v.tab = c
            v.title = c.tabTitle
            v.isActive = c === selected
            v.hasActivity = c.hasActivity
            v.hasBell = c.hasBell
            v.isBroadcasting = c.surfaces.contains { $0.broadcastEnabled }
            v.index = i
            v.needsDisplay = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let n = CGFloat(max(items.count, 1))
        let plusW: CGFloat = 26
        let avail = bounds.width - plusW - spacing * 2
        let w = max(60, min(220, (avail - spacing * (n - 1)) / n))
        let y = ((bounds.height - pillHeight) / 2).rounded()
        var x: CGFloat = 0
        for v in items {
            if v !== dragging { v.frame = NSRect(x: x, y: y, width: w, height: pillHeight) }
            x += w + spacing
        }
        plus.frame = NSRect(x: min(x, bounds.width - plusW), y: y, width: plusW, height: pillHeight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Behave like a titlebar: honor the system "double-click a window's title bar" setting.
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Item interaction

    func itemMouseDown(_ v: TabItemView, _ event: NSEvent) {
        if let t = v.tab { controller?.selectTab(t) }
        dragging = v
        didDrag = false
        let p = convert(event.locationInWindow, from: nil)
        dragOffset = p.x - v.frame.minX
        dragStartX = p.x
    }

    func itemMouseDragged(_ v: TabItemView, _ event: NSEvent) {
        guard dragging === v, items.count > 1 else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !didDrag && abs(p.x - dragStartX) < 4 { return }
        didDrag = true
        v.frame.origin.x = min(max(p.x - dragOffset, 0), bounds.width - v.frame.width)
        v.isDragging = true
        // Reorder the local list as the dragged tab passes neighbors' midpoints.
        if let i = items.firstIndex(where: { $0 === v }) {
            let mid = v.frame.midX
            if i > 0, mid < items[i - 1].frame.midX { items.swapAt(i, i - 1) }
            else if i < items.count - 1, mid > items[i + 1].frame.midX { items.swapAt(i, i + 1) }
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            layout()
        }
    }

    func itemMouseUp(_ v: TabItemView, _ event: NSEvent) {
        defer { dragging = nil; v.isDragging = false; needsLayout = true }
        guard didDrag, let t = v.tab, let newIndex = items.firstIndex(where: { $0 === v }) else { return }
        controller?.moveTab(t, to: newIndex)
    }

    func close(_ v: TabItemView) {
        if let t = v.tab { controller?.closeTab(t, confirm: true) }
    }
}

/// One pill-shaped tab.
final class TabItemView: NSView {
    weak var strip: TabStripView?
    weak var tab: TabController?
    var title = "" { didSet { if title != oldValue { needsDisplay = true; toolTip = title } } }
    var isActive = false { didSet { closeButton.isHidden = !(isActive || hovering) } }
    var hasActivity = false
    var hasBell = false
    var isBroadcasting = false
    var isDragging = false { didSet { needsDisplay = true } }
    var index = 0
    var colors = TabStripColors(background: .black, foreground: .white, accent: .orange, bell: .red, isDark: true) {
        didSet { closeButton.colors = colors; needsDisplay = true }
    }
    private var hovering = false { didSet { closeButton.isHidden = !(isActive || hovering); needsDisplay = true } }
    private let closeButton = TabIconButton(symbol: "xmark", size: 8.5)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        closeButton.isHidden = true
        closeButton.toolTip = "Close Tab (⇧⌘W)"
        closeButton.onClick = { [weak self] in
            guard let self else { return }
            self.strip?.close(self)
        }
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func layout() {
        super.layout()
        let s: CGFloat = 16
        closeButton.frame = NSRect(x: 5, y: ((bounds.height - s) / 2).rounded(), width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        if isActive || isDragging {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(colors.isDark ? 0.35 : 0.10)
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = isDragging ? 6 : 2
            shadow.set()
            colors.tint(colors.isDark ? 0.14 : 0.11).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            colors.tint(colors.isDark ? 0.21 : 0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else if hovering {
            colors.tint(0.06).setFill()
            path.fill()
        }

        // Status dot: bell > broadcast > activity.
        let dotColor: NSColor? = hasBell ? colors.bell : (isBroadcasting ? NSColor.systemOrange : (hasActivity && !isActive ? colors.accent : nil))
        let textColor = colors.foreground.withAlphaComponent(isActive ? 0.95 : (hovering ? 0.78 : 0.6))
        let font = NSFont.systemFont(ofSize: 12, weight: isActive ? .medium : .regular)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: para]

        // Leave room for the close button on the left and the dot / shortcut hint on the right.
        let inset: CGFloat = 24
        var textRect = NSRect(x: inset, y: 0, width: bounds.width - inset * 2, height: bounds.height)
        let size = (title as NSString).size(withAttributes: attrs)
        textRect.origin.y = ((bounds.height - size.height) / 2).rounded() - 0.5
        textRect.size.height = size.height + 1
        (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)

        if let dot = dotColor {
            let d: CGFloat = 6
            let dr = NSRect(x: bounds.width - 12 - d / 2, y: (bounds.height - d) / 2, width: d, height: d)
            dot.setFill()
            NSBezierPath(ovalIn: dr).fill()
        } else if hovering && index < 9 {
            let hint = "⌘\(index + 1)" as NSString
            let hAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .regular),
                                                         .foregroundColor: colors.foreground.withAlphaComponent(0.35)]
            let hs = hint.size(withAttributes: hAttrs)
            hint.draw(at: NSPoint(x: bounds.width - hs.width - 8, y: ((bounds.height - hs.height) / 2).rounded()), withAttributes: hAttrs)
        }
    }

    override func mouseDown(with event: NSEvent) { strip?.itemMouseDown(self, event) }
    override func mouseDragged(with event: NSEvent) { strip?.itemMouseDragged(self, event) }
    override func mouseUp(with event: NSEvent) { strip?.itemMouseUp(self, event) }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { strip?.close(self) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "New Tab", action: #selector(newTab), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close Tab", action: #selector(closeTab), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close Other Tabs", action: #selector(closeOthers), keyEquivalent: "").target = self
        m.addItem(withTitle: "Move Tab to New Window", action: #selector(moveToNewWindow), keyEquivalent: "").target = self
        return m
    }

    @objc private func newTab() { tab.map { t in t.perform(.newTab, from: t.focusedSurface ?? t.surfaces[0]) } }
    @objc private func closeTab() { strip?.close(self) }
    @objc private func closeOthers() {
        for c in strip?.tabControllers ?? [] where c !== tab { strip?.controller?.closeTab(c, confirm: true) }
    }
    @objc private func moveToNewWindow() { if let t = tab { strip?.controller?.moveTabToNewWindow(t) } }
}

/// A small circular icon button (close, new tab) that tints with the theme.
final class TabIconButton: NSView {
    private let symbol: String
    private let size: CGFloat
    var onClick: (() -> Void)?
    var colors = TabStripColors(background: .black, foreground: .white, accent: .orange, bell: .red, isDark: true) { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(symbol: String, size: CGFloat) {
        self.symbol = symbol
        self.size = size
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let circle = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        if hovering || pressed {
            colors.tint(pressed ? 0.22 : 0.14).setFill()
            NSBezierPath(roundedRect: circle, xRadius: d / 2 > 8 ? 7 : d / 2, yRadius: d / 2 > 8 ? 7 : d / 2).fill()
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            self.colors.foreground.withAlphaComponent(self.hovering ? 0.9 : 0.6).set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(at: NSPoint(x: ((bounds.width - img.size.width) / 2).rounded(), y: ((bounds.height - img.size.height) / 2).rounded()),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
}
