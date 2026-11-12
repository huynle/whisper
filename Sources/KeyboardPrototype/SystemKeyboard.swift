import CoreGraphics
import DictationCore
import Foundation

/// The ways a simulated delete can be sent. Which of them a given app honours is what the prototype finds out.
/// None of them may produce Control-H: terminals treat it as a key of its own, and people bind it.
enum DeleteMethod: String, CaseIterable {
    case key = "Delete key, modifiers cleared"
    case keyModifiersLeft = "Delete key, modifiers left"
    case keyHeld = "Delete key, held 40ms"
    case keyWithCharacter = "Delete key carrying DEL"
    case delCharacter = "DEL character alone"
    case keyAtSessionLevel = "Delete key, session level"
}

/// Sends real key presses to whichever app has focus. Needs Accessibility permission.
final class SystemKeyboard: Keyboard {
    private static let deleteKey: CGKeyCode = 51
    private let source = CGEventSource(stateID: .hidSystemState)
    private let delay: TimeInterval
    private let delete: DeleteMethod

    init(delay: TimeInterval, delete: DeleteMethod = .key) {
        self.delay = delay
        self.delete = delete
    }

    func type(_ text: String) {
        for character in text {
            press(key: 0, string: String(character))
        }
    }

    func backspace(_ count: Int) {
        for _ in 0..<count {
            switch delete {
            case .key: press(key: Self.deleteKey)
            case .keyModifiersLeft: press(key: Self.deleteKey, flags: nil)
            case .keyHeld: press(key: Self.deleteKey, hold: 0.04)
            case .keyWithCharacter: press(key: Self.deleteKey, string: "\u{7F}")
            case .delCharacter: press(key: 0, string: "\u{7F}")
            case .keyAtSessionLevel: press(key: Self.deleteKey, tap: .cgSessionEventTap)
            }
        }
    }

    /// `flags` empty clears the modifiers, so a hotkey still held down cannot turn letters into shortcuts;
    /// nil leaves them as the system set them. `hold` is the time between the key going down and coming up.
    private func press(
        key: CGKeyCode, string: String? = nil, flags: CGEventFlags? = [], tap: CGEventTapLocation = .cghidEventTap,
        hold: TimeInterval = 0
    ) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            if let flags { event.flags = flags }
            if let string {
                let units = Array(string.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: tap)
            if down, hold > 0 { Thread.sleep(forTimeInterval: hold) }
        }
        Thread.sleep(forTimeInterval: delay)
    }
}

/// Prints the key presses instead of sending them, and keeps the text a field would hold.
final class PrintingKeyboard: Keyboard {
    private(set) var field = ""

    func type(_ text: String) {
        field += text
        print("  type \"\(text)\"")
    }

    func backspace(_ count: Int) {
        field.removeLast(count)
        print("  backspace x\(count)")
    }
}
