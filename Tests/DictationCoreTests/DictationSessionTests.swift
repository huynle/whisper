import Foundation
import Testing
@testable import DictationCore

/// Hands back whatever samples the test set, and counts what the session asked of it.
final class FakeRecorder: AudioRecorder {
    var samples: [Float] = Array(repeating: 0.2, count: 16_000)
    var micStartSeconds: Double?
    private(set) var begun = 0
    private(set) var discarded = 0

    func begin() { begun += 1 }

    func end() -> Recording {
        Recording(samples: samples, sampleRate: 16_000, micStartSeconds: micStartSeconds)
    }

    func discard() { discarded += 1 }
}

/// Holds every transcription until the test answers it, so the order of answers is up to the test.
final class ManualTranscriber: Transcriber, @unchecked Sendable {
    let model = "test-model"
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<String, Error>] = []
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func transcribe(wav: Data) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                calls += 1
                waiting.append(continuation)
            }
        }
    }

    /// Gives up after 2 seconds, so a session that never calls fails its test instead of hanging the run.
    func waitForCalls(_ count: Int) async {
        let start = Date()
        while callCount < count, Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func answer(_ index: Int, with result: Result<String, Error>) {
        let continuation = lock.withLock { index < waiting.count ? waiting[index] : nil }
        continuation?.resume(with: result)
    }

}

final class Clock: @unchecked Sendable {
    var now: Double = 100
}

@MainActor
@Suite struct DictationSessionTests {
    let recorder = FakeRecorder()
    let transcriber = ManualTranscriber()
    let field = FakeField()
    let clock = Clock()
    let records = Box<[DictationRecord]>([])

    private func session() -> DictationSession {
        let clock = clock
        let records = records
        return DictationSession(
            recorder: recorder, transcriber: { [transcriber] in transcriber }, keyboard: field,
            now: { clock.now }, onRecord: { records.value.append($0) })
    }

    @Test func aHeldDictationIsTranscribedAndTyped() async {
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .success("cd ~/projects"))
        await s.settle()
        #expect(field.text == "cd ~/projects")
        #expect(records.value.map(\.outcome) == [.typed])
    }

    @Test func aLockedDictationWorksTheSame() async {
        let s = session()
        s.handle(.start)
        s.handle(.lock)
        #expect(s.status == .recording(locked: true))
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .success("hello"))
        await s.settle()
        #expect(field.text == "hello")
    }

    @Test func aCancelledDictationThrowsTheAudioAway() async {
        let s = session()
        s.handle(.start)
        s.handle(.cancel)
        await s.settle()
        #expect(recorder.discarded == 1)
        #expect(transcriber.callCount == 0)
        #expect(records.value.map(\.outcome) == [.cancelled])
        #expect(s.status == .idle)
    }

    @Test func audioWithoutSpeechIsNeverUploaded() async {
        recorder.samples = Array(repeating: 0.2, count: 1_000)
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        await s.settle()
        #expect(transcriber.callCount == 0)
        #expect(field.text == "")
        #expect(records.value.first?.outcome == .discarded)
        #expect(records.value.first?.detail == "too short")
    }

    @Test func aFailedTranscriptionTypesNothingAndSaysWhy() async {
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .failure(TranscriptionError.http(status: 401, message: "invalid key")))
        await s.settle()
        #expect(field.text == "")
        #expect(records.value.first?.outcome == .failed)
        #expect(records.value.first?.detail == "The provider answered 401: invalid key")
        #expect(s.status == .failed("The provider answered 401: invalid key"))
    }

    @Test func anEmptyTranscriptTypesNothing() async {
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .success("   "))
        await s.settle()
        #expect(field.calls == 0)
        #expect(records.value.first?.outcome == .empty)
    }

    @Test func dictationsAreTypedInTheOrderTheyWereSpoken() async {
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(2)
        transcriber.answer(1, with: .success(" second"))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(field.text == "")
        transcriber.answer(0, with: .success("first"))
        await s.settle()
        #expect(field.text == "first second")
    }

    @Test func aFailureDoesNotHoldBackTheNextDictation() async {
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(2)
        transcriber.answer(0, with: .failure(TranscriptionError.unreadableAnswer))
        transcriber.answer(1, with: .success("second"))
        await s.settle()
        #expect(field.text == "second")
    }

    @Test func showsWhatItIsDoing() async {
        let s = session()
        #expect(s.status == .idle)
        s.handle(.start)
        #expect(s.status == .recording(locked: false))
        s.handle(.finish)
        #expect(s.status == .transcribing)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .success("hi"))
        await s.settle()
        #expect(s.status == .idle)
    }

    @Test func recordsHowLongEachStepTook() async throws {
        recorder.micStartSeconds = 0.12
        let s = session()
        clock.now = 100
        s.handle(.start)
        clock.now = 102.5
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        clock.now = 103.4
        transcriber.answer(0, with: .success("hi"))
        await s.settle()
        let record = try #require(records.value.first)
        #expect(record.model == "test-model")
        #expect(record.text == "hi")
        #expect(record.recordingSeconds == 2.5)
        #expect(record.audioSeconds == 1)
        #expect(record.micStartSeconds == 0.12)
        #expect(abs((record.finishToTypedSeconds ?? 0) - 0.9) < 0.000_001)
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
