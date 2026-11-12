public enum TerminalLine {
    /// What a shell's input line holds after it receives `bytes`: text is appended and DEL or BS removes the
    /// last character. Nil when any other control byte arrives (an escape sequence, a bracketed paste), because
    /// a line editor may then do something this does not model.
    public static func text(after bytes: [UInt8]) -> String? {
        var line = ""
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x7F, 0x08:
                if !line.isEmpty { line.removeLast() }
            case 0..<0x20:
                return nil
            default:
                line.unicodeScalars.append(scalar)
            }
        }
        return line
    }
}
