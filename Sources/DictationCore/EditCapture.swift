import Foundation

/// Finds the user's own correction of a dictation, from the field's text right after typing and a little later.
/// Positions are UTF-16 offsets, as macOS Accessibility reports them.
public enum EditCapture {
    /// True when the text just before the cursor is what was typed, so the field can be watched.
    public static func startsWatching(fieldValue: String, typed: String, cursor: Int) -> Bool {
        let field = fieldValue as NSString
        let length = (typed as NSString).length
        guard length > 0, cursor >= length, cursor <= field.length else { return false }
        return field.substring(with: NSRange(location: cursor - length, length: length)) == typed
    }

    /// What the typed text became, when the user changed it and nothing around it: nil when they left it alone,
    /// typed on after it, edited elsewhere, deleted it, or replaced it with something unrelated.
    public static func correction(before: String, after: String, typed: String, typedEnd: Int) -> String? {
        let old = before as NSString, new = after as NSString
        let start = typedEnd - (typed as NSString).length
        guard start >= 0, typedEnd <= old.length,
              old.substring(with: NSRange(location: start, length: typedEnd - start)) == typed
        else { return nil }

        let head = old.substring(to: start), tail = old.substring(from: typedEnd)
        guard new.length >= start + (tail as NSString).length,
              new.substring(to: start) == head, after.hasSuffix(tail)
        else { return nil }
        let raw = new.substring(with: NSRange(location: start, length: new.length - (tail as NSString).length - start))
        let corrected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = typed.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !corrected.isEmpty, corrected != original,
              !corrected.hasPrefix(original), !corrected.hasSuffix(original)
        else { return nil }

        let typedWords = Set(CleanupGuard.words(original))
        let shared = Set(CleanupGuard.words(corrected)).intersection(typedWords)
        guard !typedWords.isEmpty, Double(shared.count) / Double(typedWords.count) >= 0.3 else { return nil }
        return corrected
    }
}
