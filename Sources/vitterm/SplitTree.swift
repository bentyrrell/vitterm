import AppKit
import VitConfig

/// A binary tree of panes. Leaves hold surfaces; branches split their area horizontally
/// (side by side) or vertically (stacked).
final class SplitNode {
    enum Axis { case horizontal, vertical }

    var surface: SurfaceView?
    var axis: Axis = .horizontal
    var first: SplitNode?
    var second: SplitNode?
    /// Fraction of the space given to `first`.
    var ratio: CGFloat = 0.5
    weak var parent: SplitNode?

    init(surface: SurfaceView) { self.surface = surface }

    init(axis: Axis, first: SplitNode, second: SplitNode, ratio: CGFloat = 0.5) {
        self.axis = axis
        self.first = first
        self.second = second
        self.ratio = ratio
        first.parent = self
        second.parent = self
    }

    var isLeaf: Bool { surface != nil }

    var leaves: [SurfaceView] {
        if let s = surface { return [s] }
        return (first?.leaves ?? []) + (second?.leaves ?? [])
    }

    func find(_ s: SurfaceView) -> SplitNode? {
        if surface === s { return self }
        return first?.find(s) ?? second?.find(s)
    }

    /// Number of leaves laid out along `axis` (for equalizing).
    func weight(along a: Axis) -> CGFloat {
        if isLeaf { return 1 }
        let w1 = first!.weight(along: a), w2 = second!.weight(along: a)
        return axis == a ? w1 + w2 : max(w1, w2)
    }

    func equalize() {
        guard !isLeaf else { return }
        let w1 = first!.weight(along: axis), w2 = second!.weight(along: axis)
        ratio = w1 / (w1 + w2)
        first!.equalize()
        second!.equalize()
    }
}

/// Lays out the split tree and draws/drags dividers.
final class SplitContainerView: NSView {
    var root: SplitNode? { didSet { rebuild() } }
    var zoomed: SurfaceView? { didSet { needsLayout = true; rebuild() } }
    let dividerThickness: CGFloat = 1
    let dividerGrab: CGFloat = 6
    var dividerColor: NSColor = NSColor(white: 0.5, alpha: 0.35) { didSet { needsDisplay = true } }

    private struct Divider { var node: SplitNode; var rect: NSRect; var bounds: NSRect }
    private var dividers: [Divider] = []
    private var dragging: Divider?

    override var isFlipped: Bool { true }

    /// Ensure exactly the visible surfaces are subviews.
    func rebuild() {
        let visible: [SurfaceView] = zoomed.map { [$0] } ?? (root?.leaves ?? [])
        for v in subviews.compactMap({ $0 as? SurfaceView }) where !visible.contains(where: { $0 === v }) {
            v.removeFromSuperview()
        }
        for s in visible where s.superview !== self { addSubview(s) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        dividers.removeAll()
        if let z = zoomed {
            z.frame = bounds
        } else if let r = root {
            layout(r, in: bounds)
        }
        resetCursorRects()
        needsDisplay = true
    }

    private func layout(_ node: SplitNode, in rect: NSRect) {
        if let s = node.surface {
            s.frame = rect.integral
            return
        }
        let t = dividerThickness
        if node.axis == .horizontal {
            let w1 = ((rect.width - t) * node.ratio).rounded()
            let r1 = NSRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
            let d = NSRect(x: rect.minX + w1, y: rect.minY, width: t, height: rect.height)
            let r2 = NSRect(x: d.maxX, y: rect.minY, width: rect.maxX - d.maxX, height: rect.height)
            dividers.append(Divider(node: node, rect: d, bounds: rect))
            layout(node.first!, in: r1)
            layout(node.second!, in: r2)
        } else {
            let h1 = ((rect.height - t) * node.ratio).rounded()
            let r1 = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1)
            let d = NSRect(x: rect.minX, y: rect.minY + h1, width: rect.width, height: t)
            let r2 = NSRect(x: rect.minX, y: d.maxY, width: rect.width, height: rect.maxY - d.maxY)
            dividers.append(Divider(node: node, rect: d, bounds: rect))
            layout(node.first!, in: r1)
            layout(node.second!, in: r2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        dividerColor.setFill()
        for d in dividers { d.rect.fill() }
    }

    private func grabRect(_ d: Divider) -> NSRect {
        d.rect.insetBy(dx: d.node.axis == .horizontal ? -dividerGrab / 2 : 0, dy: d.node.axis == .vertical ? -dividerGrab / 2 : 0)
    }

    override func resetCursorRects() {
        for d in dividers {
            addCursorRect(grabRect(d), cursor: d.node.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        if dividers.contains(where: { grabRect($0).contains(p) }) { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragging = dividers.first { grabRect($0).contains(p) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let d = dragging else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = d.bounds
        let r: CGFloat = d.node.axis == .horizontal ? (p.x - b.minX) / b.width : (p.y - b.minY) / b.height
        d.node.ratio = min(max(r, 0.08), 0.92)
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }
}
