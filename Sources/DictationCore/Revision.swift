/// The key presses that turn the text already typed into the text wanted.
public struct Edit: Equatable, Sendable {
    public let backspaces: Int
    public let text: String

    public init(backspaces: Int, text: String) {
        self.backspaces = backspaces
        self.text = text
    }
}

public enum Revision {
    /// Keeps the shared beginning, deletes the rest of `typed` and types the rest of `target`.
    /// One backspace is counted per visible character, which is how text fields delete emoji and accented letters.
    public static func edit(from typed: String, to target: String) -> Edit {
        let shared = zip(typed, target).prefix { $0 == $1 }.count
        return Edit(backspaces: typed.count - shared, text: String(target.dropFirst(shared)))
    }
}
