import CoreGraphics
import DictationCore
import Foundation

/// Sends real key presses to whichever app has focus. Needs Accessibility permission.
final class SystemKeyboard: Keyboard {
    private static let deleteKey: CGKeyCode = 51
    private let source = CGEventSource(stateID: .hidSystemState)
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func type(_ text: String) {
        for character in text {
            let units = Array(String(character).utf16)
            press(key: 0) { $0.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
        }
    }

    func backspace(_ count: Int) {
        for _ in 0..<count { press(key: Self.deleteKey) { _ in } }
    }

    private func press(key: CGKeyCode, configure: (CGEvent) -> Void) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            // A hotkey still held down must not turn the typed letters into shortcuts.
            event.flags = []
            configure(event)
            event.post(tap: .cghidEventTap)
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
