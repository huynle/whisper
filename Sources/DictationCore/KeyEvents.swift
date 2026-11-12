import CoreGraphics

/// Key presses built to look like real ones, ready to post.
public enum KeyEvents {
    static let deleteKeyCode: CGKeyCode = 51

    /// Every real key press carries `maskNonCoalesced`; iTerm2 in the kitty keyboard mode (which Herdr turns on)
    /// silently drops a Delete without it. Modifier flags are left out, so a hotkey still held down cannot turn
    /// the keys into shortcuts.
    static let flags = CGEventFlags.maskNonCoalesced

    /// The Delete key going down, then up.
    public static func delete(source: CGEventSource? = nil) -> [CGEvent]? {
        press(key: deleteKeyCode, character: nil, source: source)
    }

    /// One character typed, going down, then up.
    public static func text(_ character: String, source: CGEventSource? = nil) -> [CGEvent]? {
        press(key: 0, character: character, source: source)
    }

    private static func press(key: CGKeyCode, character: String?, source: CGEventSource?) -> [CGEvent]? {
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
