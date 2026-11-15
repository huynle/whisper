import AppKit
import DictationCore

/// The box for typing what a dictation should have said, opened from the fix hotkey while another app is in
/// front. It is a panel that takes the keyboard without making Whisper the active app (as Spotlight does), so
/// focus goes straight back to the field when it closes. Return saves, Shift-Return adds a line, Esc cancels.
@MainActor
final class CorrectionBox: NSObject, NSTextViewDelegate, NSWindowDelegate {
    private let panel: Panel
    private let editor: NSTextView
    private var done: ((String?) -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Shows the box; `done` gets the corrected text, or nil when cancelled.
    static func show(for record: DictationRecord, done: @escaping (String?) -> Void) -> CorrectionBox {
        let box = CorrectionBox(record: record, done: done)
        box.panel.center()
        box.panel.makeKeyAndOrderFront(nil)
        box.panel.makeFirstResponder(box.editor)
        return box
    }

    var isOpen: Bool { done != nil }

    private init(record: DictationRecord, done: @escaping (String?) -> Void) {
        self.done = done
        panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 178),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "Fix the last dictation"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 80))
        editor.string = record.text ?? ""
        editor.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        super.init()
        editor.delegate = self
        panel.delegate = self

        let said = NSTextField(wrappingLabelWithString: "You said: \u{201C}\(record.rawText ?? "")\u{201D}")
        said.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "Return saves and fixes it in place · Shift-Return new line · Esc cancels")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .tertiaryLabelColor
        let scroll = NSScrollView()
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        editor.autoresizingMask = [.width]

        let stack = NSStackView(views: [said, scroll, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            said.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    func close(saving: Bool) {
        guard let done else { return }
        self.done = nil
        let text = editor.string
        editor.isEditable = false
        // Stay key a moment, so the release of Return or Esc lands here and not in the field (iTerm in kitty
        // keyboard mode reports key releases to the program running there).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [panel] in
            panel.orderOut(nil)
            done(saving ? text : nil)
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
            close(saving: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(saving: false)
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        close(saving: false)
    }
}
