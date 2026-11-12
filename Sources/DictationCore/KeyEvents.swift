import CoreGraphics

/// Key presses built to look like real ones, ready to post.
public enum KeyEvents {
    static let deleteKeyCode: CGKeyCode = 51

    /// The Delete key going down, then up. It carries `maskNonCoalesced`, as every real key press does:
    /// iTerm2 in the kitty keyboard mode (which Herdr turns on) silently drops a Delete without it.
    public static func delete(source: CGEventSource? = nil) -> [CGEvent]? {
        press(key: deleteKeyCode, character: nil, flags: .maskNonCoalesced, source: source)
    }

    /// One character typed, going down, then up. Text is sent on the A key with the character attached, and
    /// without `maskNonCoalesced`: with it, the kitty keyboard mode reports a release of the A key after each
    /// character; without it, text arrives as plain characters.
    public static func text(_ character: String, source: CGEventSource? = nil) -> [CGEvent]? {
        press(key: 0, character: character, flags: [], source: source)
    }

    /// No modifier flags, so a hotkey still held down cannot turn the keys into shortcuts.
    private static func press(key: CGKeyCode, character: String?, flags: CGEventFlags, source: CGEventSource?) -> [CGEvent]? {
        var events: [CGEvent] = []
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return nil }
            event.flags = flags
            if let character {
                let units = Array(character.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            events.append(event)
        }
        return events
    }
}
