import Foundation

public enum Themes {
    /// Directory of user themes: `~/.config/vitterm/themes`.
    public static var userDirectory: URL { Config.configDirectory.appendingPathComponent("themes") }

    /// Bundled themes: `Contents/Resources/Themes` in the app, or the SwiftPM resource bundle under `swift run`.
    static var bundledDirectory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Themes"), FileManager.default.fileExists(atPath: r.path) { return r }
        return Bundle.module.url(forResource: "Themes", withExtension: nil)
    }

    /// All available theme names (user themes shadow bundled ones).
    public static func available() -> [String] {
        var names = Set<String>()
        for dir in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
                for i in items where !i.hasPrefix(".") { names.insert(i) }
            }
        }
        return names.sorted()
    }

    public static func named(_ name: String) -> Theme? {
        let candidates: [URL] = [
            name.hasPrefix("/") ? URL(fileURLWithPath: name) : nil,
            userDirectory.appendingPathComponent(name),
            bundledDirectory?.appendingPathComponent(name),
        ].compactMap { $0 }
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return parse(text, name: name)
            }
        }
        return nil
    }

    public static func parse(_ text: String, name: String) -> Theme {
        var t = Theme(name: name)
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            t.apply(key: line[..<eq].trimmingCharacters(in: .whitespaces),
                    value: Config.stripInlineComment(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
        }
        return t
    }
}

/// Watches the config file and user themes, calling `onChange` on the main queue.
///
/// Uses file-system events for instant reloads, plus a once-a-second check of modification times
/// so changes are still picked up when the config directory is created after launch, or when an
/// editor replaces the file in a way that drops the event source.
/// Watches the config file and user themes with kernel file events (no polling, so an idle
/// terminal does no work). Watched: the config file, every user theme file, and the nearest
/// existing directories on the way to them, so files and directories created later are picked up.
public final class ConfigWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var watchedPaths: [String] = []
    private let onChange: () -> Void
    private var pending = false
    private var lastStamp: String

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        lastStamp = ConfigWatcher.stamp()
        rearm()
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    /// Modification times and sizes of everything that affects the config.
    static func stamp() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        func add(_ path: String) {
            if let a = try? fm.attributesOfItem(atPath: path) {
                let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                parts.append("\(path):\(m):\(a[.size] ?? 0)")
            }
        }
        add(Config.configFile.path)
        let themes = Themes.userDirectory.path
        add(themes)
        for f in (try? fm.contentsOfDirectory(atPath: themes)) ?? [] { add(themes + "/" + f) }
        return parts.joined(separator: "|")
    }

    /// What to watch right now. A directory that doesn't exist yet is covered by watching its
    /// nearest existing ancestor, whose change event triggers a re-arm once it appears.
    static func pathsToWatch() -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        func nearestExisting(_ url: URL) -> String {
            var u = url
            while !fm.fileExists(atPath: u.path) && u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
            return u.path
        }
        paths.append(nearestExisting(Config.configDirectory))
        if fm.fileExists(atPath: Config.configFile.path) { paths.append(Config.configFile.path) }
        let themes = Themes.userDirectory
        if fm.fileExists(atPath: themes.path) {
            paths.append(themes.path)
            // In-place edits to a theme don't change its directory, so watch each file too.
            for f in (try? fm.contentsOfDirectory(atPath: themes.path)) ?? [] { paths.append(themes.appendingPathComponent(f).path) }
        }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func rearm() {
        let paths = ConfigWatcher.pathsToWatch()
        guard paths != watchedPaths || sources.isEmpty else { return }
        sources.forEach { $0.cancel() }
        sources = []
        watchedPaths = paths
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
            src.setEventHandler { [weak self] in self?.scheduleCheck() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources.append(src)
        }
    }

    private func scheduleCheck() {
        guard !pending else { return }
        pending = true
        // Debounce: editors write in several steps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.pending = false
            self?.check()
        }
    }

    private func check() {
        // Files or directories may have been created, replaced or removed: always re-arm (cheap;
        // it only runs on file events). Replaced files need new descriptors even at the same path.
        sources.forEach { $0.cancel() }
        sources = []
        rearm()
        let s = ConfigWatcher.stamp()
        guard s != lastStamp else { return }
        lastStamp = s
        onChange()
    }
}
