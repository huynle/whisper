import CoreGraphics
import DictationCore
import Foundation

/// How a simulated delete is sent: as fixed (`KeyEvents.delete`), or as it was before the fix.
/// Never Control-H: terminals treat it as a key of its own, and people bind it.
enum DeleteMethod {
    case fixed
    case key
}

/// Sends real key presses to whichever app has focus. Needs Accessibility permission.
/// `delete` other than `.fixed` sends one of the older delete variants, for the echo test's comparison.
final class SystemKeyboard: Keyboard {
    private static let deleteKey: CGKeyCode = 51
    private let source = CGEventSource(stateID: .hidSystemState)
    private let delay: TimeInterval
    private let delete: DeleteMethod

    init(delay: TimeInterval, delete: DeleteMethod = .fixed) {
        self.delay = delay
        self.delete = delete
    }

    func type(_ text: String) {
        for character in text {
            post(KeyEvents.text(String(character), source: source))
        }
    }

    func backspace(_ count: Int) {
        for _ in 0..<count {
            switch delete {
            case .fixed: post(KeyEvents.delete(source: source))
            case .key: legacyDelete(flags: [])
            }
        }
    }

    private func post(_ events: [CGEvent]?) {
        events?.forEach { $0.post(tap: .cghidEventTap) }
        Thread.sleep(forTimeInterval: delay)
    }

    /// How deletes were sent before the fix: no real-key mark, so iTerm2's kitty keyboard mode drops them.
    private func legacyDelete(flags: CGEventFlags) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: Self.deleteKey, keyDown: down) else { continue }
            event.flags = flags
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
