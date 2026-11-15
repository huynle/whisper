import Foundation
import Testing
@testable import DictationCore

@Suite struct ReviewEvidenceTests {
    private func record(_ raw: String, typed: String, profile: String = "Coding", rejected: String? = nil, minutesAgo: Double = 1) -> DictationRecord {
        var r = DictationRecord(outcome: .typed)
        r.date = Date(timeIntervalSinceNow: -minutesAgo * 60)
        r.rawText = raw
        r.text = typed
        r.profile = profile
        r.cleanupRejected = rejected
        return r
    }

    @Test func keepsDictationsWhereSomethingHappened() {
        let unchanged = record("hello", typed: "hello")
        let cleaned = record("cd today slash projects", typed: "cd ~/projects")
        let rejected = record("can you help?", typed: "can you help?", rejected: "Lost the question mark")
        let flagged = record("is that good?", typed: "is that good?")
        let feedback = Feedback(flagging: flagged, correction: "Is that good?")
        let items = ReviewEvidence.items(records: [unchanged, cleaned, rejected, flagged], feedback: [feedback], since: nil)
        #expect(items.map(\.id) == [cleaned.id, rejected.id, flagged.id])
        #expect(items[1].rejected == "Lost the question mark")
        #expect(items[2].corrected == "Is that good?")
        #expect(items[2].flagged == true)
    }

    @Test func onlyDictationsSinceTheLastReview() {
        let old = record("a b", typed: "A b.", minutesAgo: 120)
        let new = record("c d", typed: "C d.", minutesAgo: 1)
        let items = ReviewEvidence.items(records: [old, new], feedback: [], since: Date(timeIntervalSinceNow: -3600))
        #expect(items.map(\.id) == [new.id])
    }

    @Test func keepsTheNewestWhenThereAreTooMany() {
        let records = (0..<300).map { record("word \($0)", typed: "Word \($0).", minutesAgo: Double(300 - $0)) }
        let items = ReviewEvidence.items(records: records, feedback: [], since: nil, limit: 100)
        #expect(items.count == 100)
        #expect(items.last?.said == "word 299")
    }
}

@Suite struct ReviewProposalTests {
    private let profiles = ProfileSet.defaults
    private let dictionary = UserDictionary.defaults

    private func parse(_ json: String) -> [ReviewProposal] {
        ReviewProposal.parse(json, profiles: profiles, dictionary: dictionary)
    }

    @Test func readsEachKindOfChange() {
        let proposals = parse("""
        ```json
        {"proposals": [
          {"kind": "add_word", "written": "OmniRoute", "misheard": ["omni route"], "applies": "always", "reason": "misheard twice", "evidence": ["a", "b"]},
          {"kind": "add_misheard", "written": "~", "misheard": ["to"], "reason": "cd to projects", "evidence": ["c"]},
          {"kind": "set_instructions", "profile": "Coding", "instructions": "Keep greetings.", "reason": "dropped Justin", "evidence": ["d"]},
          {"kind": "set_setting", "profile": "Coding", "setting": "punctuation", "value": "full", "reason": "questions", "evidence": ["e"]}
        ]}
        ```
        """)
        #expect(proposals.count == 4)
        #expect(proposals[0].change == .addWord(DictionaryEntry(written: "OmniRoute", spoken: [], misheard: ["omni route"], kind: .always, profiles: nil)))
        #expect(proposals[1].change == .addMisheard(written: "~", forms: ["to"]))
        #expect(proposals[2].change == .setInstructions(profile: "Coding", instructions: "Keep greetings."))
        #expect(proposals[3].change == .setSetting(profile: "Coding", setting: "punctuation", value: "full"))
        #expect(proposals[0].reason == "misheard twice")
        #expect(proposals[0].evidence == ["a", "b"])
    }

    @Test func dropsChangesThatCannotApply() {
        let proposals = parse("""
        {"proposals": [
          {"kind": "set_instructions", "profile": "Nope", "instructions": "x", "reason": "", "evidence": []},
          {"kind": "set_setting", "profile": "Coding", "setting": "punctuation", "value": "loud", "reason": "", "evidence": []},
          {"kind": "set_setting", "profile": "Coding", "setting": "apps", "value": "x", "reason": "", "evidence": []},
          {"kind": "add_word", "written": " ", "reason": "", "evidence": []},
          {"kind": "delete_everything", "reason": "", "evidence": []}
        ]}
        """)
        #expect(proposals.isEmpty)
    }

    @Test func extraMishearingsOfAnUnknownWordBecomeANewWord() {
        let proposals = parse(#"{"proposals": [{"kind": "add_misheard", "written": "Huy", "misheard": ["we"], "reason": "", "evidence": []}]}"#)
        #expect(proposals.first?.change == .addWord(DictionaryEntry(written: "Huy", spoken: [], misheard: ["we"], kind: .context, profiles: nil)))
    }

    @Test func anUnreadableAnswerGivesNothing() {
        #expect(parse("Sorry, I cannot help with that.").isEmpty)
    }

    @Test func applyingChangesTheProfilesAndDictionary() {
        var set = profiles
        var dict = dictionary
        let changes: [ReviewProposal.Change] = [
            .addWord(DictionaryEntry(written: "OmniRoute", spoken: [], misheard: ["omni route"], kind: .always, profiles: nil)),
            .addMisheard(written: "~", forms: ["to", "today"]),
            .setInstructions(profile: "Coding", instructions: "Keep greetings."),
            .setSetting(profile: "Chat", setting: "tone", value: "professional"),
        ]
        for change in changes { change.apply(to: &set, dictionary: &dict) }
        #expect(dict.entries.contains { $0.written == "OmniRoute" })
        #expect(dict.entries.first { $0.written == "~" }?.misheard.filter { $0 == "today" }.count == 1)
        #expect(dict.entries.first { $0.written == "~" }?.misheard.contains("to") == true)
        #expect(set.profiles[0].instructions == "Keep greetings.")
        #expect(set.profiles.first { $0.name == "Chat" }?.tone == .professional)
    }

    @Test func summariesUseTheNamesSettingsShows() {
        #expect(ReviewProposal.Change.setSetting(profile: "Coding", setting: "correctness", value: "asSaid").summary == "Coding: Correctness \u{2192} Word for word")
    }

    @Test func thePromptCarriesTheProfilesTheDictionaryAndTheEvidence() throws {
        var item = ReviewEvidence.Item(id: "x1", profile: "Coding", app: nil, said: "cd to projects", typed: "cd to projects")
        item.corrected = "cd ~/projects"
        let prompt = ReviewPrompt.user(profiles: profiles, dictionary: dictionary, evidence: [item])
        #expect(prompt.contains("\"cd ~/projects\""))
        #expect(prompt.contains("\"Coding\""))
        #expect(prompt.contains("\"tilde\""))
        #expect(ReviewPrompt.system.contains("add_misheard"))
        #expect(prompt.contains("Never summarise or shorten"))
    }
}
