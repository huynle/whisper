import CoreGraphics
import DictationCore
import Foundation

/// The ways a simulated delete can be sent. Which of them a given app honours is what the prototype finds out.
enum DeleteMethod: String, CaseIterable {
    case key = "Delete key, modifiers cleared"
    case keyModifiersLeft = "Delete key, modifiers left alone"
    case keyWithCharacter = "Delete key carrying DEL"
    case delCharacter = "DEL character alone"
    case bsCharacter = "BS character alone"
    case keyAtSessionLevel = "Delete key, session level"
    case controlH = "Control-H"
}

/// Sends real key presses to whichever app has focus. Needs Accessibility permission.
final class SystemKeyboard: Keyboard {
    private static let deleteKey: CGKeyCode = 51
    private static let hKey: CGKeyCode = 4
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
            case .keyWithCharacter: press(key: Self.deleteKey, string: "\u{7F}")
            case .delCharacter: press(key: 0, string: "\u{7F}")
            case .bsCharacter: press(key: 0, string: "\u{08}")
            case .keyAtSessionLevel: press(key: Self.deleteKey, tap: .cgSessionEventTap)
            case .controlH: press(key: Self.hKey, flags: .maskControl)
            }
        }
    }

    /// `flags` empty clears the modifiers, so a hotkey still held down cannot turn letters into shortcuts;
    /// nil leaves them as the system set them.
    private func press(key: CGKeyCode, string: String? = nil, flags: CGEventFlags? = [], tap: CGEventTapLocation = .cghidEventTap) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            if let flags { event.flags = flags }
            if let string {
                let units = Array(string.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.post(tap: tap)
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
