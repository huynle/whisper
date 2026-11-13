import Foundation

public struct Recording: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    /// How long the microphone took to deliver audio after `begin`, when it had to start cold.
    public var micStartSeconds: Double?

    public init(samples: [Float], sampleRate: Int, micStartSeconds: Double?) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.micStartSeconds = micStartSeconds
    }
}

/// The microphone, as the session needs it.
public protocol AudioRecorder: AnyObject {
    func begin()
    func end() -> Recording
    func discard()
}

/// What happened to one dictation and how long each step took, for the log and developer mode.
public struct DictationRecord: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case typed, empty, discarded, failed, cancelled }

    public var id = UUID().uuidString
    public var date = Date()
    public var outcome: Outcome
    /// Why it was discarded or failed.
    public var detail: String?
    public var text: String?
    public var model: String?
    /// From the press to the finish.
    public var recordingSeconds: Double?
    public var audioSeconds: Double?
    public var micStartSeconds: Double?
    /// From the finish to the text being typed: the wait the user feels.
    public var finishToTypedSeconds: Double?
    /// From the finish to the transcript arriving.
    public var transcribeSeconds: Double?
    /// The transcript waiting for an earlier dictation to be typed first.
    public var waitSeconds: Double?
    /// Typing the text.
    public var typingSeconds: Double?
    /// The request's own breakdown (connection, upload, provider, download).
    public var request: RequestTiming?
    /// The saved recording (developer mode), a file name in the recordings folder.
    public var audioFile: String?
}

/// Runs dictations from hotkey actions: records, drops presses without speech, transcribes, and types each
/// result into the focused field. A new dictation may start while earlier ones are still being transcribed;
/// their text is typed strictly in the order they were spoken.
@MainActor
public final class DictationSession {
    public enum Status: Equatable {
        case idle
        case recording(locked: Bool)
        case transcribing
        /// The last dictation failed; cleared by the next one.
        case failed(String)
    }

    private struct Pending {
        let id: Int
        let model: String
        let finishedAt: Double
        var record: DictationRecord
        var result: Result<Transcription, Error>?
        var transcribedAt: Double?
    }

    private let recorder: AudioRecorder
    private let transcriber: () -> Transcriber
    private let keyboard: Keyboard
    private let now: () -> Double
    private let onRecord: (DictationRecord) -> Void

    private var recordingSince: Double?
    private var locked = false
    private var lastFailure: String?
    private var nextID = 0
    private var queue: [Pending] = []
    private var tasks: [Task<Void, Never>] = []
    /// Transcripts received so far, typed or still waiting for an earlier dictation.
    private(set) var resultsReceived = 0

    public var onStatusChange: ((Status) -> Void)?

    /// Developer mode: keeps each recording. Given the WAV and the record's id, returns the saved file's name.
    public var saveAudio: ((Data, String) -> String?)?

    public private(set) var status = Status.idle {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// `transcriber` is asked for each dictation, so a changed setting applies to the next one.
    public init(
        recorder: AudioRecorder, transcriber: @escaping () -> Transcriber, keyboard: Keyboard,
        now: @escaping () -> Double, onRecord: @escaping (DictationRecord) -> Void
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.keyboard = keyboard
        self.now = now
        self.onRecord = onRecord
    }

    public func handle(_ action: GestureAction) {
        switch action {
        case .start:
            guard recordingSince == nil else { return }
            lastFailure = nil
            recordingSince = now()
            locked = false
            recorder.begin()
        case .lock:
            guard recordingSince != nil else { return }
            locked = true
        case .cancel:
            guard let since = recordingSince else { return }
            recordingSince = nil
            recorder.discard()
            onRecord(DictationRecord(outcome: .cancelled, recordingSeconds: now() - since))
        case .finish:
            guard let since = recordingSince else { return }
            recordingSince = nil
            finish(recording: recorder.end(), since: since)
        }
        updateStatus()
    }

    /// Waits until every dictation in flight has been typed or has failed.
    public func settle() async {
        while !tasks.isEmpty {
            let running = tasks
            tasks.removeAll()
            for task in running { await task.value }
        }
    }

    private func finish(recording: Recording, since: Double) {
        let finishedAt = now()
        var record = DictationRecord(
            outcome: .typed,
            recordingSeconds: finishedAt - since,
            audioSeconds: Double(recording.samples.count) / Double(recording.sampleRate),
            micStartSeconds: recording.micStartSeconds)

        let wav = WAV.encode(recording.samples, sampleRate: recording.sampleRate)
        if let saveAudio { record.audioFile = saveAudio(wav, record.id) }

        if let reason = AudioCheck.discardReason(recording.samples, sampleRate: recording.sampleRate) {
            record.outcome = .discarded
            record.detail = reason
            onRecord(record)
            return
        }

        let engine = transcriber()
        record.model = engine.model
        let id = nextID
        nextID += 1
        queue.append(Pending(id: id, model: engine.model, finishedAt: finishedAt, record: record))

        tasks.append(Task {
            let result: Result<Transcription, Error>
            do { result = .success(try await engine.transcribe(wav: wav)) } catch { result = .failure(error) }
            self.deliver(result, for: id)
        })
    }

    private func deliver(_ result: Result<Transcription, Error>, for id: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[index].result = result
        queue[index].transcribedAt = now()
        resultsReceived += 1
        while let first = queue.first, let result = first.result {
            queue.removeFirst()
            complete(first, result)
        }
        updateStatus()
    }

    private func complete(_ pending: Pending, _ result: Result<Transcription, Error>) {
        var record = pending.record
        let start = now()
        if let transcribedAt = pending.transcribedAt {
            record.transcribeSeconds = transcribedAt - pending.finishedAt
            record.waitSeconds = start - transcribedAt
        }
        switch result {
        case .success(let transcription) where transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            record.outcome = .empty
            record.request = transcription.timing
        case .success(let transcription):
            record.request = transcription.timing
            LiveTyper(keyboard: keyboard).render(transcription.text)
            let end = now()
            record.text = transcription.text
            record.typingSeconds = end - start
            record.finishToTypedSeconds = end - pending.finishedAt
        case .failure(let error):
            let message = (error as? TranscriptionError)?.description ?? error.localizedDescription
            record.outcome = .failed
            record.detail = message
            lastFailure = message
        }
        onRecord(record)
    }

    private func updateStatus() {
        if recordingSince != nil {
            status = .recording(locked: locked)
        } else if !queue.isEmpty {
            status = .transcribing
        } else if let lastFailure {
            status = .failed(lastFailure)
        } else {
            status = .idle
        }
    }
}
