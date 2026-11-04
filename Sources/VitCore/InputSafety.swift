import Foundation

/// Helpers for text that goes into the shell from outside the terminal (paste, drag and drop).
public enum InputSafety {
    /// Pasted text may come from anywhere (a web page, a document). Drop control characters other
    /// than tab and line breaks: ESC could end bracketed paste early or inject terminal input, and
    /// other C0/C1 controls can trigger shell editing actions.
    public static func sanitizePaste(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0x09, 0x0A, 0x0D: out.append(u)
            case 0x00...0x1F, 0x7F...0x9F: continue
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Quote a path or URL for typing into a shell. Plain names are left readable; anything else
    /// is single-quoted. Names with control characters (macOS allows newlines in filenames, which
    /// would otherwise run commands) use ANSI-C quoting (`$'...'`, bash/zsh) with every control
    /// escaped, so nothing in the name can act as a keystroke.
    public static func shellQuote(_ s: String) -> String {
        let plain = s.unicodeScalars.allSatisfy { u in
            switch u {
            case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@": return true
            default: return u.value > 0x9F && !u.properties.isWhitespace
            }
        }
        if plain && !s.isEmpty { return s }
        if s.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) {
            var out = "$'"
            for u in s.unicodeScalars {
                switch u.value {
                case 0x5C: out += "\\\\"
                case 0x27: out += "\\'"
                case 0x00..<0x20, 0x7F...0x9F: out += String(format: "\\x%02x", u.value)
                default: out.unicodeScalars.append(u)
                }
            }
            return out + "'"
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
