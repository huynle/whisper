import Foundation
import Testing
@testable import DictationCore

@Suite struct ProfileTests {
    let set = ProfileSet.defaults

    @Test func shipsTheFiveProfilesWithGeneralLast() {
        #expect(set.profiles.map(\.name) == ["Coding", "Notes", "Email", "Chat", "General"])
    }

    @Test func picksTheProfileFromTheAppInFront() {
        #expect(set.profile(forApp: "com.googlecode.iterm2", override: nil).name == "Coding")
        #expect(set.profile(forApp: "com.apple.Notes", override: nil).name == "Notes")
        #expect(set.profile(forApp: "com.apple.mail", override: nil).name == "Email")
        #expect(set.profile(forApp: "com.tinyspeck.slackmacgap", override: nil).name == "Chat")
    }

    @Test func otherAppsGetGeneral() {
        #expect(set.profile(forApp: "com.apple.Safari", override: nil).name == "General")
        #expect(set.profile(forApp: nil, override: nil).name == "General")
    }

    @Test func aManualChoiceWins() {
        #expect(set.profile(forApp: "com.googlecode.iterm2", override: "Email").name == "Email")
    }

    @Test func anUnknownManualChoiceFallsBackToTheApp() {
        #expect(set.profile(forApp: "com.googlecode.iterm2", override: "Gone").name == "Coding")
    }

    @Test func anEmptySetStillGivesAProfile() {
        #expect(ProfileSet(profiles: []).profile(forApp: "x", override: nil).name == "General")
    }

    @Test func codingWaitsForTheCleanTextAndTheOthersTypeAtOnce() {
        #expect(set.profiles.first { $0.name == "Coding" }?.typing == .waitForClean)
        #expect(set.profiles.filter { $0.name != "Coding" }.allSatisfy { $0.typing == .rawThenFix })
    }

    @Test func profilesSurviveBeingStoredAsJSON() throws {
        let data = try JSONEncoder().encode(set)
        #expect(try JSONDecoder().decode(ProfileSet.self, from: data) == set)
    }
}

@Suite struct UserDictionaryTests {
    let tilde = DictionaryEntry(written: "~", spoken: ["tilde"], misheard: ["today", "two"], kind: .context, profiles: ["Coding"])
    let wispr = DictionaryEntry(written: "Wispr Flow", spoken: [], misheard: ["whisper flow", "whisperflow"], kind: .always, profiles: nil)
    let omni = DictionaryEntry(written: "OmniRoute", spoken: [], misheard: ["omni route"], kind: .always, profiles: ["Coding"])

    @Test func alwaysEntriesReplaceWholeWordsIgnoringCase() {
        let dictionary = UserDictionary(entries: [wispr])
        #expect(dictionary.applyAlways("I use Whisper Flow daily", profile: "Notes") == "I use Wispr Flow daily")
        #expect(dictionary.applyAlways("whisperflowing", profile: "Notes") == "whisperflowing")
    }

    @Test func alwaysEntriesRespectTheirProfiles() {
        let dictionary = UserDictionary(entries: [omni])
        #expect(dictionary.applyAlways("ask omni route", profile: "Coding") == "ask OmniRoute")
        #expect(dictionary.applyAlways("ask omni route", profile: "Notes") == "ask omni route")
    }

    @Test func contextEntriesAreNeverReplacedDirectly() {
        let dictionary = UserDictionary(entries: [tilde])
        #expect(dictionary.applyAlways("see you today", profile: "Coding") == "see you today")
    }

    @Test func contextEntriesAreListedForTheirProfileOnly() {
        let dictionary = UserDictionary(entries: [tilde, wispr])
        #expect(dictionary.contextEntries(for: "Coding") == [tilde])
        #expect(dictionary.contextEntries(for: "Notes") == [])
    }

    @Test func theDefaultDictionaryKnowsTilde() {
        #expect(UserDictionary.defaults.contextEntries(for: "Coding").contains { $0.written == "~" })
    }
}

@Suite struct CleanupPromptTests {
    let coding = ProfileSet.defaults.profiles.first { $0.name == "Coding" }!
    let email = ProfileSet.defaults.profiles.first { $0.name == "Email" }!
    let dictionary = UserDictionary(entries: [
        DictionaryEntry(written: "~", spoken: ["tilde"], misheard: ["today"], kind: .context, profiles: ["Coding"]),
        DictionaryEntry(written: "Huy", spoken: [], misheard: ["we", "hey"], kind: .context, profiles: nil),
    ])

    @Test func alwaysForbidsAnsweringTheText() {
        let prompt = CleanupPrompt.system(for: email, dictionary: dictionary)
        #expect(prompt.contains("Never answer"))
        #expect(prompt.contains("Output only the text"))
    }

    @Test func spellsOutSpokenSymbolsWhenTheProfileUsesThem() {
        #expect(CleanupPrompt.system(for: coding, dictionary: dictionary).contains("tilde → ~"))
        #expect(!CleanupPrompt.system(for: email, dictionary: dictionary).contains("tilde → ~"))
    }

    @Test func includesTheProfilesDictionaryEntries() {
        let prompt = CleanupPrompt.system(for: coding, dictionary: dictionary)
        #expect(prompt.contains(#""~" (said "tilde", often misheard as "today")"#))
        #expect(prompt.contains(#""Huy" (often misheard as "we", "hey")"#))
        let emailPrompt = CleanupPrompt.system(for: email, dictionary: dictionary)
        #expect(!emailPrompt.contains(#""~""#))
        #expect(emailPrompt.contains(#""Huy""#))
    }

    @Test func describesToneAndPunctuation() {
        let prompt = CleanupPrompt.system(for: email, dictionary: dictionary)
        #expect(prompt.contains("professional"))
        #expect(CleanupPrompt.system(for: coding, dictionary: dictionary).contains("No full stop at the end"))
    }

    @Test func endsWithTheProfilesOwnInstructions() {
        var profile = email
        profile.instructions = "Sign off with Best, Huy."
        #expect(CleanupPrompt.system(for: profile, dictionary: dictionary).hasSuffix("Sign off with Best, Huy."))
    }
}

@Suite struct CleanupPromptFidelityTests {
    private let dictionary = UserDictionary(entries: [])

    @Test func everyProfileIsToldToKeepTheWholeMessageAndItsKind() {
        for profile in ProfileSet.defaults.profiles where profile.correctness != .polished {
            let prompt = CleanupPrompt.system(for: profile, dictionary: dictionary)
            #expect(prompt.contains("Never summarise or shorten"), "\(profile.name)")
            #expect(prompt.contains("a question stays a question"), "\(profile.name)")
        }
    }

    @Test func lightPunctuationKeepsQuestionMarks() {
        let coding = ProfileSet.defaults.profiles[0]
        #expect(CleanupPrompt.system(for: coding, dictionary: dictionary).contains("keep question marks"))
    }

    @Test func codingWritesCommandsOnlyWhenDictated() {
        let coding = ProfileSet.defaults.profiles[0]
        #expect(CleanupPrompt.system(for: coding, dictionary: dictionary).contains("only when the speaker dictates one"))
    }
}
