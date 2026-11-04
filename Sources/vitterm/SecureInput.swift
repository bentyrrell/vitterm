import AppKit
import Carbon.HIToolbox

/// Secure keyboard entry (`EnableSecureEventInput`): while on, other processes can't observe
/// keystrokes typed into vitterm. Turned on manually from the app menu (remembered), and
/// automatically while the focused pane is at a password prompt (echo off, canonical mode).
/// Only active while vitterm is the active app, and the system calls are kept balanced.
final class SecureInput {
    static let shared = SecureInput()
    private static let defaultsKey = "SecureKeyboardEntry"

    /// Posted on the main thread whenever `isEnabled` changes.
    static let didChange = Notification.Name("vitterm.secureInputDidChange")

    private(set) var isEnabled = false {
        didSet { if isEnabled != oldValue { NotificationCenter.default.post(name: SecureInput.didChange, object: self) } }
    }

    /// Why it's on, for the indicator's tooltip.
    var statusDescription: String {
        let reason = manual ? "turned on in the vitterm menu" : "on automatically at a password prompt"
        return "Secure Keyboard Entry is \(reason): other apps can’t read what you type."
    }

    var manual: Bool = UserDefaults.standard.bool(forKey: SecureInput.defaultsKey) {
        didSet {
            UserDefaults.standard.set(manual, forKey: SecureInput.defaultsKey)
            update()
            NotificationCenter.default.post(name: SecureInput.didChange, object: self) // reason may change
        }
    }

    var passwordPrompt = false {
        didSet {
            guard passwordPrompt != oldValue else { return }
            update()
            NotificationCenter.default.post(name: SecureInput.didChange, object: self) // reason may change
        }
    }

    func update() {
        let want = NSApp.isActive && (manual || passwordPrompt)
        if want && !isEnabled {
            EnableSecureEventInput()
            isEnabled = true
        } else if !want && isEnabled {
            DisableSecureEventInput()
            isEnabled = false
        }
    }
}
