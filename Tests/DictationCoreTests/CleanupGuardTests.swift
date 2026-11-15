import Testing
@testable import DictationCore

@Suite struct CleanupGuardTests {
    private let general = Profile.fallback
    private var coding: Profile { ProfileSet.defaults.profiles[0] }
    private let dictionary = UserDictionary.defaults

    private func problem(_ raw: String, _ cleaned: String, _ profile: Profile) -> String? {
        CleanupGuard.problem(raw: raw, cleaned: cleaned, profile: profile, dictionary: dictionary)
    }

    // Real clean-ups from the log, 2026-11-13 to 15.

    @Test func aSummaryIsRejected() {
        let raw = "Now help me understand if this tool has proper logging for us to improve upon and dynamically adjust our profiles and various prompts to make it a lot cleaner as we use it."
        let cleaned = "The tool has proper logging to improve and dynamically adjust profiles and prompts to make it cleaner with use."
        #expect(problem(raw, cleaned, general)?.hasPrefix("Dropped") == true)
    }

    @Test func proseTurnedIntoACommandIsRejected() {
        let raw = "Let's do a general check on where we are with this. I want Dot to be a location of where we can host all of our Agentic conversation from and easily be able to fork it and start it on a new machine to get all of the skills and agents that are necessary for us to run."
        let cleaned = "cd ~/Dot check location to host Agentic conversation and easily fork and start on new machine to get necessary skills and agents"
        #expect(problem(raw, cleaned, coding) != nil)
    }

    @Test func aQuestionTurnedIntoAStatementIsRejected() {
        let raw = "Hey, can you create an automation to keep my mouse moving on this remote machine?"
        let cleaned = "I need to create an automation to keep my mouse moving on this remote machine."
        #expect(problem(raw, cleaned, general) != nil)
    }

    @Test func aLostQuestionMarkIsRejectedEvenWithLightPunctuation() {
        #expect(problem("Can you hear me?", "Can you hear me", coding) == "Lost the question mark")
    }

    @Test func aLostFinalQuestionMarkIsPutBack() {
        #expect(CleanupGuard.repair(raw: "Is that a good pattern?", cleaned: "is that a good pattern", profile: coding) == "is that a good pattern?")
        #expect(CleanupGuard.repair(raw: "Is that a good pattern?", cleaned: "is that a good pattern?", profile: coding) == "is that a good pattern?")
        #expect(CleanupGuard.repair(raw: "That is good.", cleaned: "that is good", profile: coding) == "that is good")
        #expect(CleanupGuard.repair(raw: "Why? Because I said so.", cleaned: "Because I said so.", profile: general) == "Because I said so.")
    }

    @Test func aDroppedOpeningIsRejected() {
        let raw = "Now help me understand if this tool has proper logging for us to improve upon and dynamically adjust our profiles and various prompts to make it a lot cleaner as we use it."
        let cleaned = "The tool has proper logging for us to improve upon and dynamically adjust our profiles and various prompts to make it a lot cleaner as we use it."
        #expect(problem(raw, cleaned, general) == "Left out \"help me understand if this\"")
    }

    @Test func aDroppedSentenceIsRejected() {
        let raw = "Let's do a general check on where we are with this. I want Dot to be a location of where we can host all of our Agentic conversation from and easily be able to fork it and start it on a new machine to get all of the skills and agents that are necessary for us to run."
        let cleaned = "I want Dot to be a location of where we can host all of our Agentic conversation from and easily be able to fork it and start it on a new machine to get all of the skills and agents that are necessary for us to run"
        #expect(problem(raw, cleaned, coding)?.hasPrefix("Left out") == true)
    }

    @Test func aShortFalseStartMayGo() {
        let raw = "Send it to Tom, no wait I mean send it to Sarah before the meeting starts tomorrow."
        #expect(problem(raw, "Send it to Sarah before the meeting starts tomorrow.", general) == nil)
    }

    // Clean-ups that do their job.

    @Test func spokenSymbolsAndDictionaryWordsAreFine() {
        #expect(problem("cd today slash projects", "cd ~/projects", coding) == nil)
        #expect(problem("cd tilde slash projects slash whisper", "cd ~/projects/whisper", coding) == nil)
    }

    @Test func removingFillersAndAFalseStartIsFine() {
        let raw = "Um so I think we should, uh, you know, move the meeting to Thursday afternoon if that works for everyone."
        let cleaned = "I think we should move the meeting to Thursday afternoon if that works for everyone."
        #expect(problem(raw, cleaned, general) == nil)
    }

    @Test func punctuationAndCapitalsAreFine() {
        #expect(problem("this is a test of the new profile settings", "This is a test of the new profile settings.", general) == nil)
    }

    @Test func polishedMayRewordMore() {
        var polished = general
        polished.correctness = .polished
        let raw = "so basically what I wanted to say is that the report is going to be late because we are still waiting on the numbers"
        let cleaned = "The report will be late because we are still waiting on the numbers."
        #expect(problem(raw, cleaned, polished) == nil)
        #expect(problem(raw, cleaned, general) != nil)
    }

    @Test func addedWordsAreRejected() {
        let raw = "what time is the meeting tomorrow"
        let cleaned = "The meeting tomorrow is at 3 pm in the main conference room, as scheduled by the team."
        #expect(problem(raw, cleaned, general) != nil)
    }

    @Test func shortDictationsAreNotJudgedOnWordCounts() {
        #expect(problem("Testing, testing.", "Testing", coding) == nil)
    }
}
