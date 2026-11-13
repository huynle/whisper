import CoreGraphics
import DictationCore
import Foundation

/// Types into whichever app has focus with simulated key presses (KeyEvents). Needs Accessibility permission.
final class TypingKeyboard: Keyboard {
    private let source = CGEventSource(stateID: .hidSystemState)
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.002) {
        self.delay = delay
    }

    func type(_ text: String) {
        for character in text { post(KeyEvents.text(String(character), source: source)) }
    }

    func backspace(_ count: Int) {
        for _ in 0..<count { post(KeyEvents.delete(source: source)) }
    }

    private func post(_ events: [CGEvent]?) {
        events?.forEach { $0.post(tap: .cghidEventTap) }
        Thread.sleep(forTimeInterval: delay)
    }
}
