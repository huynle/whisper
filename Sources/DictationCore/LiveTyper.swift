public enum RenderResult: Equatable, Sendable {
    /// The keys that were sent.
    case typed(Edit)
    /// Nothing was sent because the user touched the field; `corrected` is what the text should now read.
    case blocked(corrected: String)
}

/// Types one dictation into the focused field and revises it in place as the text improves.
/// It types blind: it only knows what it sent, so it stops for good once the user interferes.
public final class LiveTyper {
    private let keyboard: Keyboard
    private var typed = ""
    private var blocked = false

    public init(keyboard: Keyboard) {
        self.keyboard = keyboard
    }

    @discardableResult
    public func render(_ target: String) -> RenderResult {
        let wanted = Self.typeable(target)
        if blocked { return .blocked(corrected: wanted) }
        let edit = Revision.edit(from: typed, to: wanted)
        if edit.backspaces > 0 { keyboard.backspace(edit.backspaces) }
        if !edit.text.isEmpty { keyboard.type(edit.text) }
        typed = wanted
        return .typed(edit)
    }

    /// The user typed, clicked or switched apps: what is in the field is no longer known.
    public var isBlocked: Bool { blocked }

    public func userInterfered() {
        blocked = true
    }

    /// Enter and Tab act on the field (run a command, send a message, complete a word), so line breaks and
    /// tabs become spaces and other control characters are dropped.
    static func typeable(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isNewline || character == "\t" {
                out.append(" ")
            } else if !character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .control }) {
                out.append(character)
            }
        }
        return out
    }
}
