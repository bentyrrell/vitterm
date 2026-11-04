import AppKit
import VitCore

/// Find overlay shown in the top-right corner of a surface.
final class SearchBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    let count = NSTextField(labelWithString: "")
    let regexButton = NSButton(title: ".*", target: nil, action: nil)
    weak var surface: SurfaceView?

    init(surface: SurfaceView) {
        self.surface = surface
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        shadow = NSShadow()

        field.placeholderString = "Find"
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.target = self
        field.action = #selector(changed)
        field.focusRingType = .none

        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right

        regexButton.bezelStyle = .inline
        regexButton.setButtonType(.pushOnPushOff)
        regexButton.toolTip = "Regular expression"
        regexButton.target = self
        regexButton.action = #selector(changed)

        let prev = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: self, action: #selector(prev))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: self, action: #selector(next))
        let close = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")!, target: self, action: #selector(close))
        for b in [prev, next, close] { b.bezelStyle = .inline; b.isBordered = false }

        let stack = NSStackView(views: [field, count, regexButton, prev, next, close])
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(equalToConstant: 200),
            count.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func changed() {
        surface?.searchRegex = regexButton.state == .on
        surface?.setSearch(field.stringValue)
    }

    @objc func next() { surface?.findNext(forward: true) }
    @objc func prev() { surface?.findNext(forward: false) }
    @objc func close() { surface?.hideSearch() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            surface?.findNext(forward: !shift)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            surface?.hideSearch()
            return true
        default:
            return false
        }
    }

    func update(count n: Int, current: Int?) {
        if field.stringValue.isEmpty { count.stringValue = "" }
        else if n == 0 { count.stringValue = "0/0" }
        else { count.stringValue = "\((current ?? 0) + 1)/\(n)\(n >= 50_000 ? "+" : "")" }
    }
}

extension SurfaceView {
    func showSearch() {
        if searchBar == nil {
            let bar = SearchBar(surface: self)
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            searchBar = bar
            if let sel = selection, !sel.isEmpty {
                let t = terminal.lock.withLock { terminal.text(of: sel) }
                if !t.contains("\n") { bar.field.stringValue = t; setSearch(t) }
            }
        }
        window?.makeFirstResponder(searchBar?.field)
        searchBar?.field.selectText(nil)
    }

    func hideSearch() {
        searchBar?.removeFromSuperview()
        searchBar = nil
        searchQuery = ""
        overlay.matches = []
        overlay.currentMatch = nil
        window?.makeFirstResponder(self)
        requestRender()
    }

    func setSearch(_ q: String) {
        searchQuery = q
        runSearch(selectNearest: true)
    }

    func runSearch(selectNearest: Bool) {
        guard !searchQuery.isEmpty else {
            overlay.matches = []
            overlay.currentMatch = nil
            searchBar?.update(count: 0, current: nil)
            requestRender()
            return
        }
        let previous = overlay.currentMatch.flatMap { $0 < overlay.matches.count ? overlay.matches[$0] : nil }
        let (matches, bottom, version) = terminal.lock.withLock { () -> ([SearchMatch], Int, UInt64) in
            let g = terminal.grid
            return (terminal.search(searchQuery, regex: searchRegex), g.dropped + g.scrollbackCount - terminal.scrollOffset + terminal.rows, terminal.contentVersion)
        }
        searchVersion = version
        overlay.matches = matches
        if matches.isEmpty {
            overlay.currentMatch = nil
        } else if selectNearest || previous == nil {
            // Nearest match above the bottom of the viewport (search proceeds upward like most terminals).
            overlay.currentMatch = matches.lastIndex(where: { $0.start.line < bottom }) ?? matches.count - 1
            if selectNearest, let i = overlay.currentMatch { reveal(matches[i]) }
        } else if let p = previous {
            overlay.currentMatch = matches.firstIndex(of: p) ?? matches.lastIndex(where: { $0.start <= p.start }) ?? 0
        }
        searchBar?.update(count: matches.count, current: overlay.currentMatch)
        requestRender()
    }

    func findNext(forward: Bool) {
        if searchBar == nil { showSearch(); return }
        guard !overlay.matches.isEmpty else { return }
        let n = overlay.matches.count
        let cur = overlay.currentMatch ?? (forward ? n - 1 : 0)
        // "Next" moves up through older output (towards the top), like Terminal.app.
        let next = forward ? (cur - 1 + n) % n : (cur + 1) % n
        overlay.currentMatch = next
        reveal(overlay.matches[next])
        searchBar?.update(count: n, current: next)
        requestRender()
    }

    func reveal(_ m: SearchMatch) {
        let (top, rows) = terminal.lock.withLock { () -> (Int, Int) in
            let g = terminal.grid
            return (g.dropped + g.scrollbackCount - terminal.scrollOffset, terminal.rows)
        }
        if m.start.line < top || m.end.line >= top + rows { scrollTo(absoluteLine: m.start.line) }
    }

    func scheduleSearchRefresh() {
        guard !searchRefreshScheduled else { return }
        searchRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.searchRefreshScheduled = false
            let v = self.terminal.lock.withLock { self.terminal.contentVersion }
            if v != self.searchVersion { self.runSearch(selectNearest: false) }
        }
    }
}
