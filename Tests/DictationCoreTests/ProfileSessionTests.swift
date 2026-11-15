import Foundation
import Testing
@testable import DictationCore

/// Holds each clean-up until the test answers it, keyed by the text it was given.
final class ManualCleaner: Cleaner, @unchecked Sendable {
    let model = "test-cleaner"
    private let lock = NSLock()
    private var waiting: [String: CheckedContinuation<String, Error>] = [:]
    /// Answers given before their request arrived; delivered when it does, so no answer is ever lost.
    private var early: [String: Result<String, Error>] = [:]
    private(set) var instructionsSeen: [String] = []

    var calls: Int { lock.withLock { waiting.count + answered } }
    private var answered = 0

    func clean(_ text: String, instructions: String) async throws -> Transcription {
        let cleaned: String = try await withCheckedThrowingContinuation { continuation in
            let answer: Result<String, Error>? = lock.withLock {
                instructionsSeen.append(instructions)
                if let answer = early.removeValue(forKey: text) { return answer }
                waiting[text] = continuation
                return nil
            }
            if let answer { continuation.resume(with: answer) }
        }
        return Transcription(text: cleaned, timing: RequestTiming(totalMs: 600))
    }

    func waitFor(_ text: String) async {
        let start = Date()
        while lock.withLock({ waiting[text] == nil }), Date().timeIntervalSince(start) < 2 {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func answer(_ text: String, with result: Result<String, Error>) {
        let continuation: CheckedContinuation<String, Error>? = lock.withLock {
            answered += 1
            if let continuation = waiting.removeValue(forKey: text) { return continuation }
            early[text] = result
            return nil
        }
        continuation?.resume(with: result)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProfileSessionTests {
    let recorder = FakeRecorder()
    let transcriber = ManualTranscriber()
    let cleaner = ManualCleaner()
    let field = FakeField()
    let records = Box<[DictationRecord]>([])

    private func profile(_ typing: Profile.Typing, trailingSpace: Bool = false) -> Profile {
        var p = Profile.fallback
        p.name = "Test"
        p.typing = typing
        p.trailingSpace = trailingSpace
        return p
    }

    private func session(_ profile: Profile, dictionary: UserDictionary = UserDictionary(entries: []), cleanupTimeout: Double = 2) -> DictationSession {
        let records = records
        let context = DictationContext(profile: profile, dictionary: dictionary, cleaner: cleaner)
        let s = DictationSession(
            recorder: recorder, transcriber: { [transcriber] in transcriber }, keyboard: field,
            now: { 0 }, onRecord: { records.value.append($0) }, context: { context })
        s.cleanupTimeout = cleanupTimeout
        return s
    }

    private func dictate(_ s: DictationSession, number: Int, says text: String) async {
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(number + 1)
        transcriber.answer(number, with: .success(text))
    }

    @Test func waitingForCleanTypesOnlyTheCleanText() async throws {
        let s = session(profile(.waitForClean))
        await dictate(s, number: 0, says: "cd today slash projects")
        await cleaner.waitFor("cd today slash projects")
        #expect(field.text == "")
        cleaner.answer("cd today slash projects", with: .success("cd ~/projects"))
        await s.settle()
        #expect(field.text == "cd ~/projects")
        let record = try #require(records.value.first)
        #expect(record.rawText == "cd today slash projects")
        #expect(record.text == "cd ~/projects")
        #expect(record.profile == "Test")
        #expect(record.cleanupModel == "test-cleaner")
        #expect(record.cleanup == RequestTiming(totalMs: 600))
    }

    @Test func theCleanupIsToldTheProfilesInstructions() async {
        let s = session(profile(.waitForClean))
        await dictate(s, number: 0, says: "hello")
        await cleaner.waitFor("hello")
        cleaner.answer("hello", with: .success("Hello."))
        await s.settle()
        #expect(cleaner.instructionsSeen == [CleanupPrompt.system(for: profile(.waitForClean), dictionary: UserDictionary(entries: []))])
    }

    @Test func rawThenFixTypesAtOnceThenCorrectsInPlace() async throws {
        let s = session(profile(.rawThenFix))
        await dictate(s, number: 0, says: "cd today slash projects")
        await cleaner.waitFor("cd today slash projects")
        await waitUntil { field.text == "cd today slash projects" }
        #expect(field.text == "cd today slash projects")
        cleaner.answer("cd today slash projects", with: .success("cd ~/projects"))
        await s.settle()
        #expect(field.text == "cd ~/projects")
        #expect(records.value.first?.revised == true)
        #expect(records.value.first?.text == "cd ~/projects")
    }

    @Test func rawThenFixLeavesTheTextAloneOnceTheUserTyped() async throws {
        let s = session(profile(.rawThenFix))
        await dictate(s, number: 0, says: "hello there")
        await cleaner.waitFor("hello there")
        await waitUntil { field.text == "hello there" }
        s.userInput()
        cleaner.answer("hello there", with: .success("Hello there."))
        await s.settle()
        #expect(field.text == "hello there")
        let record = try #require(records.value.first)
        #expect(record.revised == false)
        #expect(record.text == "hello there")
        #expect(record.detail == "Not corrected: you typed or clicked after it was typed")
    }

    @Test func rawThenFixDoesNotCorrectTextThatALaterDictationFollows() async throws {
        let s = session(profile(.rawThenFix))
        await dictate(s, number: 0, says: "first")
        await cleaner.waitFor("first")
        await dictate(s, number: 1, says: "second")
        await cleaner.waitFor("second")
        await waitUntil { field.text == "firstsecond" }
        cleaner.answer("first", with: .success("First."))
        cleaner.answer("second", with: .success("Second."))
        await s.settle()
        #expect(field.text == "firstSecond.")
        #expect(records.value.first { $0.rawText == "first" }?.revised == false)
    }

    @Test func aFailedCleanupTypesTheRawText() async throws {
        let s = session(profile(.waitForClean))
        await dictate(s, number: 0, says: "cd today")
        await cleaner.waitFor("cd today")
        cleaner.answer("cd today", with: .failure(TranscriptionError.unreadableAnswer))
        await s.settle()
        #expect(field.text == "cd today")
        #expect(records.value.first?.cleanupError == "The provider's answer could not be read")
        #expect(records.value.first?.outcome == .typed)
    }

    @Test func aSlowCleanupGivesWayToTheRawText() async throws {
        let s = session(profile(.waitForClean), cleanupTimeout: 0.05)
        await dictate(s, number: 0, says: "cd today")
        await waitUntil { field.text == "cd today" }
        #expect(field.text == "cd today")
        cleaner.answer("cd today", with: .success("cd ~"))
        await s.settle()
        #expect(field.text == "cd today")
        #expect(records.value.first?.cleanupError == "Clean-up took longer than 0.05 s")
    }

    @Test func alwaysEntriesAreAppliedBeforeAnythingIsTyped() async throws {
        let dictionary = UserDictionary(entries: [DictionaryEntry(written: "Wispr Flow", spoken: [], misheard: ["whisper flow"], kind: .always, profiles: nil)])
        let s = session(profile(.waitForClean), dictionary: dictionary)
        await dictate(s, number: 0, says: "I like whisper flow")
        await cleaner.waitFor("I like Wispr Flow")
        cleaner.answer("I like Wispr Flow", with: .success("I like Wispr Flow."))
        await s.settle()
        #expect(field.text == "I like Wispr Flow.")
    }

    @Test func aTrailingSpaceFollowsTheText() async throws {
        let s = session(profile(.rawThenFix, trailingSpace: true))
        await dictate(s, number: 0, says: "hello")
        await cleaner.waitFor("hello")
        await waitUntil { field.text == "hello " }
        #expect(field.text == "hello ")
        cleaner.answer("hello", with: .success("Hello."))
        await s.settle()
        #expect(field.text == "Hello. ")
    }

    @Test func noCleanerTypesTheRawText() async {
        let records = records
        let s = DictationSession(
            recorder: recorder, transcriber: { [transcriber] in transcriber }, keyboard: field,
            now: { 0 }, onRecord: { records.value.append($0) },
            context: { DictationContext(profile: Profile.fallback, dictionary: UserDictionary(entries: []), cleaner: nil) })
        await dictate(s, number: 0, says: "hello")
        await s.settle()
        #expect(field.text == "hello ")
        #expect(records.value.first?.cleanupModel == nil)
    }

    @Test func aCleanupThatChangesTheMeaningIsNotTyped() async throws {
        let s = session(profile(.waitForClean))
        let said = "can you move the meeting to Thursday please?"
        await dictate(s, number: 0, says: said)
        await cleaner.waitFor(said)
        cleaner.answer(said, with: .success("Sure, I moved the meeting to Thursday."))
        await s.settle()
        #expect(field.text == said)
        let record = try #require(records.value.first)
        #expect(record.text == said)
        #expect(record.cleanedText == "Sure, I moved the meeting to Thursday.")
        #expect(record.cleanupRejected?.hasPrefix("Dropped") == true)
    }

    @Test func rawThenFixKeepsTheSpokenWordsWhenTheCleanupStrays() async throws {
        let s = session(profile(.rawThenFix))
        let said = "can you move the meeting to Thursday please?"
        await dictate(s, number: 0, says: said)
        await cleaner.waitFor(said)
        await waitUntil { field.text == said }
        cleaner.answer(said, with: .success("Sure, I moved the meeting to Thursday."))
        await s.settle()
        #expect(field.text == said)
        let record = try #require(records.value.first)
        #expect(record.revised == false)
        #expect(record.cleanedText == "Sure, I moved the meeting to Thursday.")
        #expect(record.cleanupRejected?.hasPrefix("Dropped") == true)
    }

    @Test func theCleanedTextIsLoggedWhenItIsUsed() async throws {
        let s = session(profile(.waitForClean))
        await dictate(s, number: 0, says: "hello")
        await cleaner.waitFor("hello")
        cleaner.answer("hello", with: .success("Hello."))
        await s.settle()
        #expect(records.value.first?.cleanedText == "Hello.")
        #expect(records.value.first?.cleanupRejected == nil)
    }

    @Test func aDroppedQuestionMarkIsPutBack() async throws {
        let s = session(profile(.waitForClean))
        await dictate(s, number: 0, says: "Is that a good pattern?")
        await cleaner.waitFor("Is that a good pattern?")
        cleaner.answer("Is that a good pattern?", with: .success("is that a good pattern"))
        await s.settle()
        #expect(field.text == "is that a good pattern?")
        #expect(records.value.first?.cleanupRejected == nil)
    }
}
