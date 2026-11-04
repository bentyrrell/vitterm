import XCTest

/// End-to-end tests: launch the test build of the app (build/e2e/vitterm.app, built by
/// `TEST_HOOKS=1 APP=build/e2e/vitterm.app scripts/bundle.sh`), drive it with scripted keybinding
/// actions, and inspect a JSON dump of its state. They open real windows, so they only run when
/// `VITTERM_E2E=1` (scripts/test.sh does this after building the bundle).
final class E2ETests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let app = root.appendingPathComponent("build/e2e/vitterm.app/Contents/MacOS/vitterm")
    var tmp: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["VITTERM_E2E"] == "1", "set VITTERM_E2E=1 to run end-to-end tests")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: E2ETests.app.path), "run TEST_HOOKS=1 APP=build/e2e/vitterm.app scripts/bundle.sh first")
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vitterm-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("vitterm"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    struct Pane { let text: String; let focused: Bool; let broadcast: Bool; let cwd: String; let searchMatches: Int; let background: String; let cols: Int }
    struct Tab { let selected: Bool; let title: String; let panes: [Pane] }
    struct State { let windows: [[Tab]]; let theme: String; let diagnostics: [String] }

    func writeConfig(_ text: String) throws {
        try text.write(to: tmp.appendingPathComponent("vitterm/config"), atomically: true, encoding: .utf8)
    }

    /// Launch the app, wait for it to dump its state and quit, and parse the dump.
    func run(config: String = "", args: [String] = [], actions: [String] = [], env extra: [String: String] = [:],
             delay: Double = 3.5, during: ((Process) -> Void)? = nil) throws -> State {
        try writeConfig("command = /bin/sh\nshell-integration = false\nwindow-width = 60\nwindow-height = 12\n" + config)
        let dump = tmp.appendingPathComponent("state.json")
        let p = Process()
        p.executableURL = E2ETests.app
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["XDG_CONFIG_HOME"] = tmp.path
        env["VITTERM_DEBUG_DUMP"] = dump.path
        env["VITTERM_SNAPSHOT_DELAY"] = String(delay)
        env["VITTERM_SNAPSHOT_QUIT"] = "1"
        if !actions.isEmpty { env["VITTERM_DEBUG_ACTIONS"] = actions.joined(separator: ";;") }
        for (k, v) in extra { env[k] = v }
        p.environment = env
        try p.run()
        during?(p)
        let deadline = Date().addingTimeInterval(delay + 15)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate(); XCTFail("app did not exit") }
        let data = try Data(contentsOf: dump)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let windows = (json["windows"] as? [[String: Any]] ?? []).map { w in
            (w["tabs"] as? [[String: Any]] ?? []).map { t in
                Tab(selected: t["selected"] as? Bool ?? false, title: t["title"] as? String ?? "",
                    panes: (t["panes"] as? [[String: Any]] ?? []).map { p in
                        Pane(text: p["text"] as? String ?? "", focused: p["focused"] as? Bool ?? false,
                             broadcast: p["broadcast"] as? Bool ?? false, cwd: p["cwd"] as? String ?? "",
                             searchMatches: p["searchMatches"] as? Int ?? 0, background: p["background"] as? String ?? "",
                             cols: p["cols"] as? Int ?? 0)
                    })
            }
        }
        return State(windows: windows, theme: json["theme"] as? String ?? "", diagnostics: json["diagnostics"] as? [String] ?? [])
    }

    func testCommandOutputAppears() throws {
        let s = try run(args: ["-e", "printf 'hello from e2e'; sleep 30"])
        let pane = try XCTUnwrap(s.windows.first?.first?.panes.first)
        XCTAssertTrue(pane.text.contains("hello from e2e"), pane.text)
        XCTAssertEqual(pane.cols, 60, "window-width config is honored")
        XCTAssertTrue(s.diagnostics.isEmpty, "\(s.diagnostics)")
    }

    func testSplitsAndBroadcastInput() throws {
        let s = try run(actions: ["new_split:right", "new_split:down", "toggle_broadcast", "text:echo broadcast-ok\\r"], delay: 4)
        let panes = try XCTUnwrap(s.windows.first?.first?.panes)
        XCTAssertEqual(panes.count, 3)
        XCTAssertEqual(panes.filter(\.focused).count, 1)
        for (i, p) in panes.enumerated() {
            XCTAssertTrue(p.broadcast, "pane \(i) in the broadcast group")
            XCTAssertTrue(p.text.contains("broadcast-ok"), "pane \(i) received broadcast input:\n\(p.text)")
        }
    }

    func testInputWithoutBroadcastGoesToFocusedPaneOnly() throws {
        let s = try run(actions: ["new_split:right", "text:echo only-here\\r"], delay: 3.5)
        let panes = try XCTUnwrap(s.windows.first?.first?.panes)
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.filter { $0.text.contains("only-here") }.count, 1)
        XCTAssertTrue(panes.first { $0.focused }!.text.contains("only-here"))
    }

    func testTabs() throws {
        let s = try run(actions: ["new_tab", "text:echo in-second-tab\\r", "new_tab", "goto_tab:1"], delay: 4)
        let tabs = try XCTUnwrap(s.windows.first)
        XCTAssertEqual(s.windows.count, 1, "tabs live in one window")
        XCTAssertEqual(tabs.count, 3)
        XCTAssertTrue(tabs[0].selected)
        XCTAssertTrue(tabs[1].panes[0].text.contains("in-second-tab"), tabs[1].panes[0].text)
    }

    func testClosingTabsAndPanes() throws {
        let s = try run(actions: ["new_tab", "new_split:right", "close_surface", "new_tab", "close_tab"], delay: 4)
        let tabs = try XCTUnwrap(s.windows.first)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(tabs[1].panes.count, 1, "the split was closed")
    }

    func testShellExitClosesWindow() throws {
        let s = try run(args: ["-e", "exit 0"], delay: 2.5)
        XCTAssertEqual(s.windows.count, 0, "the only pane exited, so its window closed")
    }

    func testConfigHotReload() throws {
        let s = try run(config: "theme = Nord\n", delay: 4) { _ in
            usleep(1_500_000)
            try? "command = /bin/sh\nwindow-width = 60\nwindow-height = 12\ntheme = Solarized Light\n"
                .write(to: self.tmp.appendingPathComponent("vitterm/config"), atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(s.theme, "Solarized Light")
        XCTAssertEqual(s.windows.first?.first?.panes.first?.background, "#fdf6e3", "open panes picked up the new theme")
    }

    func testInvalidConfigIsReported() throws {
        let s = try run(config: "font-size = enormous\n", delay: 2.5)
        // Diagnostics are shown in an alert at launch; the dump exposes them for this test.
        XCTAssertEqual(s.diagnostics.count, 1, "\(s.diagnostics)")
    }

    func testSearch() throws {
        let s = try run(args: ["-e", "printf 'needle hay\\nhay needle\\nneedle\\n'; sleep 30"],
                        env: ["VITTERM_DEBUG_SEARCH": "needle"], delay: 3)
        XCTAssertEqual(s.windows.first?.first?.panes.first?.searchMatches, 3)
    }

    func testShellIntegrationReportsWorkingDirectory() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/bin/zsh"))
        let dir = tmp.appendingPathComponent("work dir").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try writeConfig("")
        let s = try run(config: "command = /bin/zsh\nshell-integration = true\nworking-directory = \(dir)\n",
                        actions: ["text:cd ..\\r"], delay: 5)
        let pane = try XCTUnwrap(s.windows.first?.first?.panes.first)
        // The shell reported its directory via OSC 7 after `cd ..` (works through the ZDOTDIR shim).
        XCTAssertEqual(URL(fileURLWithPath: pane.cwd).standardizedFileURL.path,
                       URL(fileURLWithPath: tmp.path).standardizedFileURL.path, pane.text)
    }
}
