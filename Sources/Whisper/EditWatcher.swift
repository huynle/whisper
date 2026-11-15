import ApplicationServices
import DictationCore
import Foundation

/// After a dictation is typed, watches the field for up to 30 seconds through Accessibility, and reports the
/// user's own correction of the typed text (`EditCapture`). Only fields that expose their text and cursor take
/// part; password fields never do. Nothing but the corrected span is kept.
@MainActor
final class EditWatcher {
    private struct Watch {
        let record: DictationRecord
        let element: AXUIElement
        let before: String
        let typed: String
        let typedEnd: Int
        var latest: String
        let started: Date
    }

    static let duration: TimeInterval = 30
    private var watch: Watch?
    private var timer: Timer?
    private let found: (Feedback) -> Void

    init(found: @escaping (Feedback) -> Void) {
        self.found = found
    }

    /// Starts watching the focused field for `record`, after typing has settled; any earlier watch ends first.
    func watch(_ record: DictationRecord) {
        finish()
        guard let text = record.text, !text.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.begin(record, typed: text) }
    }

    /// Ends the current watch without reporting anything (Whisper itself is about to change the text).
    func cancel() {
        timer?.invalidate()
        timer = nil
        watch = nil
    }

    /// Ends the current watch now, reporting a correction if there is one (a new dictation is starting).
    func finish() {
        timer?.invalidate()
        timer = nil
        guard let watch else { return }
        self.watch = nil
        if let corrected = EditCapture.correction(before: watch.before, after: watch.latest, typed: watch.typed, typedEnd: watch.typedEnd) {
            found(Feedback(source: .edited, record: watch.record, correctedText: corrected))
        }
    }

    private func begin(_ record: DictationRecord, typed: String) {
        guard watch == nil, let element = Self.focusedElement(), let value = Self.value(of: element),
              let cursor = Self.cursor(of: element)
        else { return }
        let typedEnd: Int
        if EditCapture.startsWatching(fieldValue: value, typed: typed, cursor: cursor) {
            typedEnd = cursor
        } else if EditCapture.startsWatching(fieldValue: value, typed: typed + " ", cursor: cursor) {
            typedEnd = cursor - 1
        } else {
            return
        }
        watch = Watch(record: record, element: element, before: value, typed: typed, typedEnd: typedEnd, latest: value, started: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let current = watch else { return finish() }
        guard let focused = Self.focusedElement(), CFEqual(focused, current.element) else { return finish() }
        if let value = Self.value(of: current.element) { watch?.latest = value }
        if Date().timeIntervalSince(current.started) >= Self.duration { finish() }
    }

    private static func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role) == .success,
           role as? String == kAXSecureTextFieldSubrole as String { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// The cursor's offset, when nothing is selected.
    private static func cursor(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        return range.location
    }
}
