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
    let corrections = Box<[Feedback]>([])

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
        let corrections = corrections
        s.onCorrection = { corrections.value.append($0) }
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

    // MARK: fixing the last dictation

    private func typeFirst(_ s: DictationSession, says: String, cleaned: String) async {
        await dictate(s, number: 0, says: says)
        await cleaner.waitFor(says)
        cleaner.answer(says, with: .success(cleaned))
        await s.settle()
    }

    private func fix(_ s: DictationSession, number: Int, says: String) async {
        s.handle(.start, purpose: .fix)
        s.handle(.finish)
        await transcriber.waitForCalls(number + 1)
        transcriber.answer(number, with: .success(says))
    }

    @Test func sayingItAgainReplacesTheLastDictation() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "cd to projects", cleaned: "cd to projects")
        await fix(s, number: 1, says: "cd tilde slash projects")
        await cleaner.waitFor("cd tilde slash projects")
        cleaner.answer("cd tilde slash projects", with: .success("cd ~/projects"))
        await s.settle()
        #expect(field.text == "cd ~/projects")
        let first = try #require(records.value.first)
        let fixRecord = try #require(records.value.last)
        #expect(fixRecord.fixes == first.id)
        #expect(fixRecord.outcome == .typed)
        let correction = try #require(corrections.value.first)
        #expect(correction.source == .resaid)
        #expect(correction.dictationID == first.id)
        #expect(correction.typedText == "cd to projects")
        #expect(correction.correctedText == "cd ~/projects")
    }

    @Test func aFixWaitsForTheCleanTextEvenWhenTheProfileTypesAtOnce() async throws {
        let s = session(profile(.rawThenFix))
        await typeFirst(s, says: "hello", cleaned: "Hello.")
        #expect(field.text == "Hello.")
        await fix(s, number: 1, says: "goodbye")
        await cleaner.waitFor("goodbye")
        #expect(field.text == "Hello.")
        cleaner.answer("goodbye", with: .success("Goodbye."))
        await s.settle()
        #expect(field.text == "Goodbye.")
    }

    @Test func aFixAfterTheUserTypedIsSavedButNotTyped() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "hello", cleaned: "Hello.")
        s.userInput()
        await fix(s, number: 1, says: "goodbye")
        await cleaner.waitFor("goodbye")
        cleaner.answer("goodbye", with: .success("Goodbye."))
        await s.settle()
        #expect(field.text == "Hello.")
        let fixRecord = try #require(records.value.last)
        #expect(fixRecord.outcome == .failed)
        #expect(fixRecord.text == "Goodbye.")
        #expect(fixRecord.detail?.hasPrefix("Not replaced") == true)
        #expect(corrections.value.first?.correctedText == "Goodbye.")
    }

    @Test func aFixWithNothingTypedTypesNothing() async throws {
        let s = session(profile(.waitForClean))
        await fix(s, number: 0, says: "goodbye")
        await cleaner.waitFor("goodbye")
        cleaner.answer("goodbye", with: .success("Goodbye."))
        await s.settle()
        #expect(field.text == "")
        #expect(records.value.last?.detail == "Nothing to fix: no dictation was typed yet")
        #expect(corrections.value.isEmpty)
    }

    @Test func aTypedCorrectionReplacesTheLastDictation() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "cd to projects", cleaned: "cd to projects")
        #expect(s.correctLast("cd ~/projects"))
        #expect(field.text == "cd ~/projects")
        s.userInput()
        #expect(!s.correctLast("cd ~/other"))
        #expect(field.text == "cd ~/projects")
    }

    @Test func aDictationTurnedIntoAFixReplacesTheLastOne() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "cd to projects", cleaned: "cd to projects")
        s.handle(.start)
        s.mark(.fix)
        s.handle(.finish)
        await transcriber.waitForCalls(2)
        transcriber.answer(1, with: .success("cd tilde slash projects"))
        await cleaner.waitFor("cd tilde slash projects")
        cleaner.answer("cd tilde slash projects", with: .success("cd ~/projects"))
        await s.settle()
        #expect(field.text == "cd ~/projects")
        #expect(corrections.value.first?.correctedText == "cd ~/projects")
    }

    // MARK: rewriting the last dictation by an instruction

    private func instruct(_ s: DictationSession, number: Int, says: String) async {
        s.handle(.start, purpose: .rewrite)
        s.handle(.finish)
        await transcriber.waitForCalls(number + 1)
        transcriber.answer(number, with: .success(says))
    }

    @Test func aSpokenInstructionRewritesTheLastDictation() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "yo what's up", cleaned: "Yo, what's up?")
        await instruct(s, number: 1, says: "Make it a little more formal.")
        let request = RewritePrompt.user(text: "Yo, what's up?", instruction: "Make it a little more formal.")
        await cleaner.waitFor(request)
        #expect(cleaner.instructionsSeen.last == RewritePrompt.system(for: profile(.waitForClean)))
        #expect(field.text == "Yo, what's up?")
        cleaner.answer(request, with: .success("Hello, how are you doing?"))
        await s.settle()
        #expect(field.text == "Hello, how are you doing?")
        let first = try #require(records.value.first)
        let rewrite = try #require(records.value.last)
        #expect(rewrite.instruction == "Make it a little more formal.")
        #expect(rewrite.fixes == first.id)
        #expect(rewrite.text == "Hello, how are you doing?")
        let feedback = try #require(corrections.value.first)
        #expect(feedback.source == .rewritten)
        #expect(feedback.instruction == "Make it a little more formal.")
        #expect(feedback.typedText == "Yo, what's up?")
        #expect(feedback.correctedText == "Hello, how are you doing?")
    }

    @Test func instructionsCanBeChained() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "yo what's up", cleaned: "Yo, what's up?")
        await instruct(s, number: 1, says: "more formal")
        let first = RewritePrompt.user(text: "Yo, what's up?", instruction: "more formal")
        await cleaner.waitFor(first)
        cleaner.answer(first, with: .success("Hello, how are you doing?"))
        await s.settle()
        await instruct(s, number: 2, says: "go undercover")
        let second = RewritePrompt.user(text: "Hello, how are you doing?", instruction: "go undercover")
        await cleaner.waitFor(second)
        cleaner.answer(second, with: .success("Hi."))
        await s.settle()
        #expect(field.text == "Hi.")
    }

    @Test func aFailedRewriteLeavesTheTextAndNeverTypesTheInstruction() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "hello", cleaned: "Hello.")
        await instruct(s, number: 1, says: "more formal")
        let request = RewritePrompt.user(text: "Hello.", instruction: "more formal")
        await cleaner.waitFor(request)
        cleaner.answer(request, with: .failure(TranscriptionError.unreadableAnswer))
        await s.settle()
        #expect(field.text == "Hello.")
        #expect(records.value.last?.outcome == .failed)
        #expect(records.value.last?.detail?.hasPrefix("Rewrite failed") == true)
        #expect(corrections.value.isEmpty)
    }

    @Test func anInstructionWithNothingTypedDoesNothing() async throws {
        let s = session(profile(.waitForClean))
        await instruct(s, number: 0, says: "more formal")
        await s.settle()
        #expect(field.text == "")
        #expect(records.value.last?.detail == "Nothing to rewrite: no dictation was typed yet")
    }

    @Test func aTypedInstructionRewritesTheLastDictation() async throws {
        let s = session(profile(.waitForClean))
        await typeFirst(s, says: "yo", cleaned: "Yo")
        s.rewriteLast("more formal")
        let request = RewritePrompt.user(text: "Yo", instruction: "more formal")
        await cleaner.waitFor(request)
        cleaner.answer(request, with: .success("Hello."))
        await s.settle()
        #expect(field.text == "Hello.")
    }
}
