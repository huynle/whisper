import Foundation

/// The user saying a dictation came out wrong, and what it should have been. Kept in feedback.jsonl beside the
/// dictation log, for the review that proposes dictionary and prompt changes.
public struct Feedback: Codable, Equatable, Sendable {
    /// `flagged`: typed in the correction box. `edited`: the user's own correction, seen in the field after
    /// typing. `resaid`: said again with the fix hotkey.
    public enum Source: String, Codable, Sendable { case flagged, edited, resaid }

    public var id = UUID().uuidString
    public var date = Date()
    public var source: Source
    public var dictationID: String
    public var profile: String?
    public var app: String?
    /// What the speech model heard.
    public var rawText: String?
    /// What was typed.
    public var typedText: String?
    /// What the user meant; nil when they only flagged it.
    public var correctedText: String?

    public init(source: Source, record: DictationRecord, correctedText: String?) {
        self.source = source
        dictationID = record.id
        profile = record.profile
        app = record.app
        rawText = record.rawText
        typedText = record.text
        let trimmed = correctedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.correctedText = trimmed.isEmpty || trimmed == record.text ? nil : trimmed
    }

    /// From the menu: `correction` is the text as the user fixed it, or as typed when they only flag it.
    public init(flagging record: DictationRecord, correction: String) {
        self.init(source: .flagged, record: record, correctedText: correction)
    }
}
