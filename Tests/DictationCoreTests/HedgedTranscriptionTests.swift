import Foundation
import Testing
@testable import DictationCore

/// Never answers its first request; answers every later one at once.
final class StuckFirstTranscriber: Transcriber, @unchecked Sendable {
    let model = "stuck-first"
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func transcribe(wav: Data) async throws -> Transcription {
        let n = lock.withLock { count += 1; return count }
        if n == 1 { try await Task.sleep(for: .seconds(30)) }
        return Transcription(text: "hello there", timing: RequestTiming(totalMs: 1))
    }
}

/// Answers every request after `delay` seconds.
final class SlowTranscriber: Transcriber, @unchecked Sendable {
    let model = "slow"
    let delay: Double
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    init(delay: Double) { self.delay = delay }

    func transcribe(wav: Data) async throws -> Transcription {
        lock.withLock { count += 1 }
        try await Task.sleep(for: .seconds(delay))
        return Transcription(text: "hello", timing: RequestTiming(totalMs: 1))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct HedgedTranscriptionTests {
    private func run(_ transcriber: Transcriber, hedge: Double?) async -> FakeField {
        let field = FakeField()
        let s = DictationSession(recorder: FakeRecorder(), transcriber: { transcriber }, keyboard: field, now: { 0 }, onRecord: { _ in })
        s.transcribeHedge = hedge
        s.handle(.start)
        s.handle(.finish)
        await s.settle()
        return field
    }

    @Test func aSecondRequestRescuesAStuckTranscription() async {
        let stuck = StuckFirstTranscriber()
        let field = await run(stuck, hedge: 0.05)
        #expect(field.text == "hello there")
        #expect(stuck.calls == 2)
    }

    @Test func aQuickAnswerSendsNoSecondRequest() async {
        let quick = SlowTranscriber(delay: 0.01)
        _ = await run(quick, hedge: 0.5)
        #expect(quick.calls == 1)
    }
}
