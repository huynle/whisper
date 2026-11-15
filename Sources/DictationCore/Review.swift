import Foundation

/// What a review looks at: the dictations where something happened (cleaned, rejected, flagged or corrected).
public enum ReviewEvidence {
    public struct Item: Codable, Equatable, Sendable {
        public var id: String
        public var profile: String?
        public var app: String?
        /// What the speech model heard.
        public var said: String
        /// What the clean-up model answered, when it differs from what was typed.
        public var cleaned: String?
        public var typed: String
        /// Why the clean-up was not typed.
        public var rejected: String?
        /// The user marked it as wrong.
        public var flagged: Bool?
        /// What the user meant.
        public var corrected: String?

        public init(id: String, profile: String?, app: String?, said: String, typed: String) {
            self.id = id
            self.profile = profile
            self.app = app
            self.said = said
            self.typed = typed
        }
    }

    /// The newest `limit` typed dictations after `since` worth reviewing, oldest first.
    public static func items(records: [DictationRecord], feedback: [Feedback], since: Date?, limit: Int = 150) -> [Item] {
        var latestFeedback: [String: Feedback] = [:]
        for entry in feedback { latestFeedback[entry.dictationID] = entry }

        let items: [Item] = records.compactMap { record in
            guard record.outcome == .typed, let said = record.rawText, let typed = record.text else { return nil }
            if let since, record.date <= since, latestFeedback[record.id].map({ $0.date <= since }) ?? true { return nil }
            let note = latestFeedback[record.id]
            guard note != nil || record.cleanupRejected != nil || said != typed else { return nil }
            var item = Item(id: record.id, profile: record.profile, app: record.app, said: said, typed: typed)
            if let cleaned = record.cleanedText, cleaned != typed { item.cleaned = cleaned }
            item.rejected = record.cleanupRejected
            if let note {
                item.flagged = true
                item.corrected = note.correctedText
            }
            return item
        }
        return Array(items.suffix(limit))
    }
}

/// One change a review suggests, for the user to accept or not.
public struct ReviewProposal: Equatable, Identifiable, Sendable {
    public enum Change: Equatable, Sendable {
        case addWord(DictionaryEntry)
        case addMisheard(written: String, forms: [String])
        case setInstructions(profile: String, instructions: String)
        case setSetting(profile: String, setting: String, value: String)
    }

    public let id = UUID()
    public var change: Change
    public var reason: String
    /// The dictation ids it is based on.
    public var evidence: [String]

    public init(change: Change, reason: String, evidence: [String]) {
        self.change = change
        self.reason = reason
        self.evidence = evidence
    }

    public static func == (a: ReviewProposal, b: ReviewProposal) -> Bool {
        a.change == b.change && a.reason == b.reason && a.evidence == b.evidence
    }

    /// The profile settings a review may change, with the values each accepts.
    static let settings: [String: [String]] = [
        "tone": ["asSpoken", "casual", "professional"],
        "punctuation": ["full", "light", "spokenOnly"],
        "correctness": ["asSaid", "clean", "corrected", "polished"],
        "typing": ["waitForClean", "rawThenFix"],
        "spokenSymbols": ["true", "false"],
        "trailingSpace": ["true", "false"],
    ]

    private struct Answer: Decodable {
        struct Item: Decodable {
            var kind: String
            var written: String?
            var spoken: [String]?
            var misheard: [String]?
            var applies: String?
            var profiles: [String]?
            var profile: String?
            var instructions: String?
            var setting: String?
            var value: String?
            var reason: String?
            var evidence: [String]?
        }
        var proposals: [Item]
    }

    /// The review model's answer as proposals; any that name an unknown profile, setting or value are left out.
    public static func parse(_ answer: String, profiles: ProfileSet, dictionary: UserDictionary) -> [ReviewProposal] {
        let text = OpenAIChatCleaner.unwrap(answer)
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let decoded = try? JSONDecoder().decode(Answer.self, from: Data(text[start...end].utf8))
        else { return [] }
        let names = Set(profiles.profiles.map(\.name))

        return decoded.proposals.compactMap { item in
            let reason = item.reason ?? ""
            let evidence = item.evidence ?? []
            let clean = { (list: [String]?) in (list ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            let change: Change?
            switch item.kind {
            case "add_word", "add_misheard":
                let written = (item.written ?? "").trimmingCharacters(in: .whitespaces)
                let misheard = clean(item.misheard), spoken = clean(item.spoken)
                if written.isEmpty {
                    change = nil
                } else if dictionary.entries.contains(where: { $0.written == written }) {
                    change = misheard.isEmpty && spoken.isEmpty ? nil : .addMisheard(written: written, forms: misheard + spoken)
                } else if item.kind == "add_misheard" && misheard.isEmpty {
                    change = nil
                } else {
                    let scoped = clean(item.profiles).filter { names.contains($0) }
                    change = .addWord(DictionaryEntry(
                        written: written, spoken: spoken, misheard: misheard,
                        kind: item.applies == "always" ? .always : .context, profiles: scoped.isEmpty ? nil : scoped))
                }
            case "set_instructions":
                if let profile = item.profile, names.contains(profile), let instructions = item.instructions {
                    change = .setInstructions(profile: profile, instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    change = nil
                }
            case "set_setting":
                if let profile = item.profile, names.contains(profile), let setting = item.setting, let value = item.value,
                   settings[setting]?.contains(value) == true {
                    change = .setSetting(profile: profile, setting: setting, value: value)
                } else {
                    change = nil
                }
            default:
                change = nil
            }
            return change.map { ReviewProposal(change: $0, reason: reason, evidence: evidence) }
        }
    }
}

extension ReviewProposal.Change {
    public func apply(to set: inout ProfileSet, dictionary: inout UserDictionary) {
        switch self {
        case .addWord(let entry):
            if let i = dictionary.entries.firstIndex(where: { $0.written == entry.written }) {
                Self.merge(entry.misheard + entry.spoken, into: &dictionary.entries[i].misheard)
            } else {
                dictionary.entries.append(entry)
            }
        case .addMisheard(let written, let forms):
            guard let i = dictionary.entries.firstIndex(where: { $0.written == written }) else { return }
            Self.merge(forms, into: &dictionary.entries[i].misheard)
        case .setInstructions(let name, let instructions):
            guard let i = set.profiles.firstIndex(where: { $0.name == name }) else { return }
            set.profiles[i].instructions = instructions
        case .setSetting(let name, let setting, let value):
            guard let i = set.profiles.firstIndex(where: { $0.name == name }) else { return }
            var profile = set.profiles[i]
            switch setting {
            case "tone": profile.tone = Profile.Tone(rawValue: value) ?? profile.tone
            case "punctuation": profile.punctuation = Profile.Punctuation(rawValue: value) ?? profile.punctuation
            case "correctness": profile.correctness = Profile.Correctness(rawValue: value) ?? profile.correctness
            case "typing": profile.typing = Profile.Typing(rawValue: value) ?? profile.typing
            case "spokenSymbols": profile.spokenSymbols = value == "true"
            case "trailingSpace": profile.trailingSpace = value == "true"
            default: return
            }
            set.profiles[i] = profile
        }
    }

    private static func merge(_ forms: [String], into list: inout [String]) {
        for form in forms where !list.contains(where: { $0.caseInsensitiveCompare(form) == .orderedSame }) {
            list.append(form)
        }
    }

    /// One line for the review window.
    public var summary: String {
        switch self {
        case .addWord(let entry):
            let heard = (entry.misheard + entry.spoken).map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
            return "Add \u{201C}\(entry.written)\u{201D} to the dictionary" + (heard.isEmpty ? "" : " (heard as \(heard))")
                + (entry.kind == .always ? ", replaced everywhere" : "")
                + (entry.profiles.map { ", in " + $0.joined(separator: ", ") } ?? "")
        case .addMisheard(let written, let forms):
            return "\u{201C}\(written)\u{201D} is also heard as " + forms.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        case .setInstructions(let profile, let instructions):
            return "\(profile): new instructions: \(instructions)"
        case .setSetting(let profile, let setting, let value):
            return "\(profile): \(Self.labels[setting] ?? setting) \u{2192} \(Self.labels[setting + "." + value] ?? value)"
        }
    }

    /// The names Settings shows for each setting and value.
    static let labels = [
        "tone": "Tone", "tone.asSpoken": "As spoken", "tone.casual": "Casual", "tone.professional": "Professional",
        "punctuation": "Punctuation", "punctuation.full": "Full sentences",
        "punctuation.light": "Light, no full stop at the end", "punctuation.spokenOnly": "Only what is said aloud",
        "correctness": "Correctness", "correctness.asSaid": "Word for word",
        "correctness.clean": "Remove fillers and false starts", "correctness.corrected": "Also correct grammar",
        "correctness.polished": "Polish for clarity",
        "typing": "Typing", "typing.waitForClean": "Wait for the clean text", "typing.rawThenFix": "Type at once, then correct",
        "spokenSymbols": "Spoken symbols", "spokenSymbols.true": "On", "spokenSymbols.false": "Off",
        "trailingSpace": "End with a space", "trailingSpace.true": "On", "trailingSpace.false": "Off",
    ]
}

/// The review model's instructions, and the material it is given.
public enum ReviewPrompt {
    public static let system = """
    You improve a dictation app's settings from how it has been used. The app records speech, a speech model \
    transcribes it ("said"), a clean-up model rewrites it per profile ("cleaned"), and the result is typed ("typed"). \
    You get the profiles, the dictionary, and dictations where something happened: the clean-up changed the text, \
    the app rejected the clean-up for straying from what was said ("rejected"), or the user flagged it ("flagged") \
    and maybe wrote what they meant ("corrected").

    Suggest a few changes that would make future dictations come out the way the user means them. Each change must \
    rest on the dictations given; cite their ids. Prefer the smallest change: a dictionary entry for a misheard word, \
    a sentence added to a profile's instructions for a habit of the clean-up model, a setting only when the evidence \
    is clear. Use "always" only for words that can never mean anything else; otherwise "context". When you change a \
    profile's instructions, give the whole new instructions, keeping what is still needed. "cleanupPrompts" shows \
    the full prompt each profile's clean-up model gets now, built from its settings with its own instructions at \
    the end: never repeat a rule it already has; when the model breaks a rule it already has, prefer a setting \
    change or say so in the reason. Suggest nothing when nothing is clearly wrong. At most 8 changes.

    Answer with JSON only, in this form:
    {"proposals": [
      {"kind": "add_word", "written": "...", "spoken": ["..."], "misheard": ["..."], "applies": "context|always", "profiles": ["..."], "reason": "...", "evidence": ["id"]},
      {"kind": "add_misheard", "written": "<an existing dictionary word>", "misheard": ["..."], "reason": "...", "evidence": ["id"]},
      {"kind": "set_instructions", "profile": "<name>", "instructions": "...", "reason": "...", "evidence": ["id"]},
      {"kind": "set_setting", "profile": "<name>", "setting": "tone|punctuation|correctness|typing|spokenSymbols|trailingSpace", "value": "...", "reason": "...", "evidence": ["id"]}
    ]}
    Setting values: tone asSpoken|casual|professional; punctuation full|light|spokenOnly; correctness \
    asSaid|clean|corrected|polished; typing waitForClean|rawThenFix; spokenSymbols and trailingSpace true|false. \
    Write each reason in one short sentence for the user.
    """

    public static func user(profiles: ProfileSet, dictionary: UserDictionary, evidence: [ReviewEvidence.Item]) -> String {
        struct Material: Encodable {
            let profiles: [Profile]
            let cleanupPrompts: [String: String]
            let dictionary: [DictionaryEntry]
            let dictations: [ReviewEvidence.Item]
        }
        var prompts: [String: String] = [:]
        for profile in profiles.profiles { prompts[profile.name] = CleanupPrompt.system(for: profile, dictionary: dictionary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Material(profiles: profiles.profiles, cleanupPrompts: prompts, dictionary: dictionary.entries, dictations: evidence))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
