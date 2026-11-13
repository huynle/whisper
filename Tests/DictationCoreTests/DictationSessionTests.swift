import Foundation
import Testing
@testable import DictationCore

/// Hands back whatever samples the test set, and counts what the session asked of it. The first sample of
/// recording n (from 0) carries n, so a fake transcriber can tell which dictation a request belongs to.
final class FakeRecorder: AudioRecorder {
    var samples: [Float] = Array(repeating: 0.2, count: 16_000)
    var micStartSeconds: Double?
    private(set) var begun = 0
    private(set) var discarded = 0
    private var ended = 0

    func begin() { begun += 1 }

    func end() -> Recording {
        var audio = samples
        if !audio.isEmpty { audio[0] = Float(ended) / 32_767 }
        ended += 1
        return Recording(samples: audio, sampleRate: 16_000, micStartSeconds: micStartSeconds)
    }

    /// The recording number carried by a WAV made from `end()`.
    static func number(of wav: Data) -> Int {
        Int(Int16(bitPattern: UInt16(wav[44]) | UInt16(wav[45]) << 8))
    }

    func discard() { discarded += 1 }
}

/// Holds every transcription until the test answers it, so the order of answers is up to the test. Requests
/// are known by their recording's number (FakeRecorder), not by arrival: the session sends them concurrently.
final class ManualTranscriber: Transcriber, @unchecked Sendable {
    let model = "test-model"
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<String, Error>] = [:]
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    var timing: RequestTiming?

    func transcribe(wav: Data) async throws -> Transcription {
        let number = FakeRecorder.number(of: wav)
        let text: String = try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                calls += 1
                waiting[number] = continuation
            }
        }
        return Transcription(text: text, timing: timing)
    }

    /// Gives up after 2 seconds, so a session that never calls fails its test instead of hanging the run.
    func waitForCalls(_ count: Int) async {
        let start = Date()
        while callCount < count, Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func answer(_ index: Int, with result: Result<String, Error>) {
        let continuation = lock.withLock { waiting.removeValue(forKey: index) }
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
    let saved = Box<[(Data, String)]>([])

    private func session(keepAudio: Bool = false) -> DictationSession {
        let clock = clock
        let records = records
        let saved = saved
        let s = DictationSession(
            recorder: recorder, transcriber: { [transcriber] in transcriber }, keyboard: field,
            now: { clock.now }, onRecord: { records.value.append($0) })
        if keepAudio {
            s.saveAudio = { wav, id in
                saved.value.append((wav, id))
                return "\(id).wav"
            }
        }
        return s
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
        #expect(abs((record.transcribeSeconds ?? 0) - 0.9) < 0.000_001)
    }

    @Test func recordsTheRequestTimingAndHowLongTheResultWaitedForAnEarlierOne() async throws {
        transcriber.timing = RequestTiming(totalMs: 700, uploadMs: 30, waitMs: 650, reusedConnection: false, requestBytes: 32_044)
        let s = session()
        clock.now = 100
        s.handle(.start)
        s.handle(.finish)
        clock.now = 101
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(2)
        clock.now = 102
        transcriber.answer(1, with: .success("second"))
        await waitUntil { s.resultsReceived == 1 }
        clock.now = 103
        transcriber.answer(0, with: .success("first"))
        await s.settle()
        let second = try #require(records.value.last)
        #expect(second.request == transcriber.timing)
        #expect(second.transcribeSeconds == 1)
        #expect(second.waitSeconds == 1)
        #expect(records.value.first?.waitSeconds == 0)
    }

    @Test func keepsTheAudioOnlyWhenAskedTo() async throws {
        let s = session(keepAudio: true)
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .success("hi"))
        await s.settle()
        let record = try #require(records.value.first)
        #expect(saved.value.count == 1)
        #expect(saved.value.first?.0.prefix(4) == Data("RIFF".utf8))
        #expect(record.audioFile == "\(record.id).wav")
    }

    @Test func keepsNoAudioByDefault() async throws {
        let s = session()
        s.handle(.start)
        s.handle(.finish)
        await transcriber.waitForCalls(1)
        transcriber.answer(0, with: .success("hi"))
        await s.settle()
        #expect(records.value.first?.audioFile == nil)
    }

    @Test func keepsTheAudioOfDiscardedDictationsToo() async {
        recorder.samples = Array(repeating: 0.0001, count: 16_000)
        let s = session(keepAudio: true)
        s.handle(.start)
        s.handle(.finish)
        await s.settle()
        #expect(saved.value.count == 1)
        #expect(records.value.first?.outcome == .discarded)
        #expect(records.value.first?.audioFile != nil)
    }
}

/// Waits for `condition`, giving up after 2 seconds so a broken session fails its test instead of hanging.
@MainActor
func waitUntil(_ condition: () -> Bool) async {
    let start = Date()
    while !condition(), Date().timeIntervalSince(start) < 2 { try? await Task.sleep(for: .milliseconds(1)) }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
