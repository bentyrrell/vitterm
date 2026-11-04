import Foundation

/// Automatic shell integration (prompt marks, cwd reporting) for zsh and fish.
enum ShellIntegration {
    static var directory: URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("ShellIntegration"), FileManager.default.fileExists(atPath: r.path) { return r }
        return Bundle.module.url(forResource: "ShellIntegration", withExtension: nil)
    }

    static func prepare(shell: String, env: inout [String: String]) {
        guard let dir = directory?.path else { return }
        env["VITTERM_SHELL_INTEGRATION"] = dir
        let name = (shell as NSString).lastPathComponent
        switch name {
        case "zsh":
            if let orig = ProcessInfo.processInfo.environment["ZDOTDIR"] { env["VITTERM_ORIG_ZDOTDIR"] = orig }
            env["ZDOTDIR"] = dir + "/zsh"
        case "fish":
            let existing = ProcessInfo.processInfo.environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = dir + ":" + existing
        default:
            break
        }
    }
}
