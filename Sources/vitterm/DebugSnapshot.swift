import AppKit
import VitRender
import VitConfig

/// Debug aid: with `VITTERM_SNAPSHOT=/path/out.png` (and optional `VITTERM_SNAPSHOT_DELAY` seconds),
/// render the focused pane offscreen and write a PNG. Works without screen-recording permission.
enum DebugSnapshot {
    /// Test hooks (replaying input, writing state/snapshots to arbitrary paths) exist only in debug
    /// builds and in bundles built for end-to-end tests (`TEST_HOOKS=1 scripts/bundle.sh`).
    static var hooksEnabled: Bool {
        #if DEBUG || VITTERM_TEST_HOOKS
        return true
        #else
        return false
        #endif
    }

    static func scheduleIfRequested() {
        guard hooksEnabled else { return }
        let env = ProcessInfo.processInfo.environment
        // VITTERM_DEBUG_ACTIONS="new_split:right;;text:echo hi\r;;toggle_broadcast" replays actions at startup.
        if let list = env["VITTERM_DEBUG_ACTIONS"] {
            var t = 0.8
            for a in list.components(separatedBy: ";;") {
                guard let action = Action(parse: a) else { NSLog("vitterm: bad debug action \(a)"); continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    guard let c = AppDelegate.shared.lastActiveController, let s = c.focusedSurface ?? c.surfaces.first else { return }
                    s.perform(action)
                }
                t += 0.4
            }
        }
        let snapshotPath = env["VITTERM_SNAPSHOT"]
        let dumpPath = env["VITTERM_DEBUG_DUMP"]
        guard snapshotPath != nil || dumpPath != nil else { return }
        let delay = Double(env["VITTERM_SNAPSHOT_DELAY"] ?? "") ?? 2.5
        if let q = env["VITTERM_DEBUG_SEARCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay - 0.6) {
                guard let s = AppDelegate.shared.lastActiveController?.focusedSurface else { return }
                s.showSearch()
                s.searchBar?.field.stringValue = q
                s.setSearch(q)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let path = snapshotPath { capture(to: path) }
            if let path = dumpPath { dumpState(to: path) }
            if env["VITTERM_SNAPSHOT_QUIT"] == "1" {
                // Skip close confirmations: this is an automated run.
                for c in AppDelegate.shared.controllers { c.terminate() }
                exit(0)
            }
        }
    }

    /// Machine-readable app state for end-to-end tests (`VITTERM_DEBUG_DUMP=<file.json>`).
    static func dumpState(to path: String) {
        let app = AppDelegate.shared!
        func hex(_ v: UInt32) -> String { String(format: "#%06x", v) }
        let windows: [[String: Any]] = app.windows.map { wc in
            [
                "title": wc.window?.title ?? "",
                "key": wc.window?.isKeyWindow ?? false,
                "tabs": wc.tabs.map { tab -> [String: Any] in
                    [
                        "selected": tab === wc.selectedTab,
                        "title": tab.tabTitle,
                        "panes": tab.surfaces.map { s -> [String: Any] in
                            let (text, cols, rows) = s.terminal.lock.withLock { (s.terminal.screenText(), s.terminal.cols, s.terminal.rows) }
                            return [
                                "focused": s === tab.focusedSurface,
                                "cols": cols, "rows": rows,
                                "broadcast": s.broadcastEnabled,
                                "text": text,
                                "cwd": s.cwd ?? "",
                                "searchMatches": s.overlay.matches.count,
                                "background": hex(s.theme.background),
                                "fontSize": s.fontSize,
                            ]
                        },
                    ]
                },
            ]
        }
        let state: [String: Any] = ["windows": windows, "theme": app.config.resolvedTheme(systemDark: true).name,
                                    "diagnostics": app.config.diagnostics]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func dumpGeometry() -> String {
        guard let c = AppDelegate.shared.lastActiveController, let w = c.window else { return "" }
        var out = "window frame \(w.frame.size)  scale \(w.backingScaleFactor)\n"
        out += "contentLayoutRect \(w.contentLayoutRect)\n"
        out += "titlebar height \(w.frame.height - w.contentLayoutRect.height)\n"
        for (n, b) in [("close", NSWindow.ButtonType.closeButton), ("mini", .miniaturizeButton), ("zoom", .zoomButton)] {
            if let btn = w.standardWindowButton(b), let sv = btn.superview {
                let r = sv.convert(btn.frame, to: nil)
                out += "\(n) button (window coords, y up) \(r)  midY-from-top \(w.frame.height - r.midY)\n"
            }
        }
        out += "container frame \(c.container.frame)\n"
        if let s = c.focusedSurface {
            out += "surface frame \(s.frame)  cell(pt) \(s.cellSizeInPoints())  padding(pt) \(s.config.windowPaddingX),\(s.config.windowPaddingY)\n"
            out += "grid \(s.terminal.cols)x\(s.terminal.rows)\n"
        }
        return out
    }

    static func capture(to path: String) {
        try? dumpGeometry().write(toFile: path + ".geometry", atomically: true, encoding: .utf8)
        guard let c = AppDelegate.shared.lastActiveController, let window = c.window,
              let frameView = window.contentView?.superview else { return }
        // Composite the window chrome (titlebar, traffic lights, tab bar) with every pane.
        let scale = window.backingScaleFactor
        let size = frameView.bounds.size
        let W = Int(size.width * scale), H = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let img = rep.cgImage { ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H)) }
        }
        for s in c.surfaces {
            guard let img = s.renderSnapshot() else { continue }
            let f = s.convert(s.bounds, to: nil) // window coordinates, y up
            ctx.draw(img, in: CGRect(x: f.minX * scale, y: f.minY * scale, width: f.width * scale, height: f.height * scale))
        }
        if let s = c.focusedSurface {
            let text = s.terminal.lock.withLock { s.terminal.screenText() }
            try? text.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
        }
        guard let out = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: out)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// VITTERM_DEBUG_STARTUP=1: print wall-clock timestamps of startup phases.
enum StartupTrace {
    static let enabled = ProcessInfo.processInfo.environment["VITTERM_DEBUG_STARTUP"] != nil
    static func mark(_ phase: String) {
        guard enabled else { return }
        print(String(format: "VITTERM_T %.4f %@", Date().timeIntervalSince1970, phase))
        fflush(stdout)
    }
}
