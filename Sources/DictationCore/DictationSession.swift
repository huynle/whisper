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
    /// Why it was discarded, failed, or not corrected.
    public var detail: String?
    /// The text typed in the end.
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
    /// The transcript waiting for clean-up (when the profile waits for it) or for an earlier dictation.
    public var waitSeconds: Double?
    /// Typing the text.
    public var typingSeconds: Double?
    /// The request's own breakdown (connection, upload, provider, download).
    public var request: RequestTiming?
    /// The saved recording (developer mode), a file name in the recordings folder.
    public var audioFile: String?
    public var profile: String?
    /// The speech model's text, after the dictionary's exact replacements.
    public var rawText: String?
    public var cleanupModel: String?
    public var cleanup: RequestTiming?
    public var cleanupError: String?
    /// Raw-then-fix: whether the raw text was corrected in place.
    public var revised: Bool?
    /// What the clean-up model answered, whether or not it was typed.
    public var cleanedText: String?
    /// Why the clean-up was not typed: it strayed from what was said (`CleanupGuard`).
    public var cleanupRejected: String?
    /// The bundle identifier of the app it was dictated into.
    public var app: String?
    /// A fix or a rewrite: the id of the dictation it replaced.
    public var fixes: String?
    /// A rewrite: the instruction it followed.
    public var instruction: String?
}

/// Runs dictations from hotkey actions: records, drops presses without speech, transcribes, cleans up per the
/// profile, and types each result into the focused field. A new dictation may start while earlier ones are
/// still in flight; their text is typed strictly in the order they were spoken.
@MainActor
public final class DictationSession {
    public enum Status: Equatable {
        case idle
        case recording(locked: Bool)
        case transcribing
        /// The last dictation failed; cleared by the next one.
        case failed(String)
    }

    private enum CleanupState {
        case none, running, done(Result<Transcription, Error>)
    }

    private struct Pending {
        let id: Int
        let finishedAt: Double
        let context: DictationContext
        var purpose = DictationPurpose.dictate
        var record: DictationRecord
        /// The raw text, or why there is none; nil until the transcript arrives.
        var transcript: Result<String, Error>?
        var transcribedAt: Double?
        /// The clean-up, or for a rewrite the rewrite.
        var cleanup = CleanupState.none
        /// A rewrite: the dictation it rewrites (its position in `lastTyped`).
        var rewriteBase: Int?

        /// Ready to type: transcribed, and not waiting for a clean-up the profile waits for.
        var isReady: Bool {
            guard transcript != nil else { return false }
            if case .running = cleanup, purpose == .rewrite { return false }
            if case .running = cleanup, context.profile.typing == .waitForClean { return false }
            return true
        }
    }

    /// A raw-then-fix dictation already typed, whose clean-up is still running.
    private struct AwaitingRevision {
        var record: DictationRecord
        let typer: LiveTyper
        let trailingSpace: Bool
    }

    private let recorder: AudioRecorder
    private let transcriber: () -> Transcriber
    private let keyboard: Keyboard
    private let now: () -> Double
    private let onRecord: (DictationRecord) -> Void
    private let context: () -> DictationContext

    private var recordingSince: Double?
    private var recordingContext: DictationContext?
    private var locked = false
    private var lastFailure: String?
    private var nextID = 0
    private var queue: [Pending] = []
    private var awaitingRevision: [Int: AwaitingRevision] = [:]
    /// The dictation typed last, the only one that can still be corrected in place; `record.text` is what the
    /// field holds now.
    private var lastTyped: (id: Int, typer: LiveTyper, record: DictationRecord, trailingSpace: Bool)?
    private var recordingPurpose = DictationPurpose.dictate
    private var tasks: [Task<Void, Never>] = []
    /// Transcripts received so far, typed or still waiting.
    private(set) var resultsReceived = 0

    public var onStatusChange: ((Status) -> Void)?

    /// A fix of the last dictation, said again or typed: what was typed and what the user meant.
    public var onCorrection: ((Feedback) -> Void)?

    /// Developer mode: keeps each recording. Given the WAV and the record's id, returns the saved file's name.
    public var saveAudio: ((Data, String) -> String?)?

    /// The longest a waiting profile waits for clean-up before typing the raw text.
    public var cleanupTimeout: Double = 2.5
    /// The longest a rewrite may take.
    public var rewriteTimeout: Double = 8
    /// The longest a raw-then-fix correction may arrive after the raw text.
    public var revisionTimeout: Double = 8

    public private(set) var status = Status.idle {
        didSet { if status != oldValue { onStatusChange?(status) } }
    }

    /// `transcriber` and `context` are asked for each dictation, so changed settings apply to the next one.
    /// `context` is taken when the hotkey is pressed, from the app in front at that moment.
    public init(
        recorder: AudioRecorder, transcriber: @escaping () -> Transcriber, keyboard: Keyboard,
        now: @escaping () -> Double, onRecord: @escaping (DictationRecord) -> Void,
        context: @escaping () -> DictationContext = { .plain }
    ) {
        self.recorder = recorder
        self.transcriber = transcriber
        self.keyboard = keyboard
        self.now = now
        self.onRecord = onRecord
        self.context = context
    }

    /// `purpose` (when starting): what the recording is for; a fix or an instruction acts on the last dictation.
    public func handle(_ action: GestureAction, purpose: DictationPurpose = .dictate) {
        switch action {
        case .start:
            guard recordingSince == nil else { return }
            recordingPurpose = purpose
            lastFailure = nil
            recordingSince = now()
            recordingContext = context()
            locked = false
            recorder.begin()
        case .lock:
            guard recordingSince != nil else { return }
            locked = true
        case .cancel:
            guard let since = recordingSince else { return }
            recordingSince = nil
            recorder.discard()
            onRecord(DictationRecord(outcome: .cancelled, recordingSeconds: now() - since, profile: recordingContext?.profile.name))
        case .finish:
            guard let since = recordingSince else { return }
            recordingSince = nil
            finish(recording: recorder.end(), since: since, context: recordingContext ?? context(), purpose: recordingPurpose)
        }
        updateStatus()
    }

    /// The recording running now replaces the last dictation instead of adding to it (Right Shift was added).
    public func mark(_ purpose: DictationPurpose) {
        if recordingSince != nil { recordingPurpose = purpose }
    }

    /// Rewrites the last dictation by an instruction the user typed.
    public func rewriteLast(_ instruction: String) {
        let context = context()
        let id = nextID
        nextID += 1
        var record = DictationRecord(outcome: .typed, profile: context.profile.name)
        record.app = context.app
        record.rawText = instruction
        let at = now()
        var pending = Pending(id: id, finishedAt: at, context: context, purpose: .rewrite, record: record)
        pending.transcript = .success(instruction)
        pending.transcribedAt = at
        queue.append(pending)
        startRewrite(id: id, instruction: instruction)
        flush()
    }

    /// True while a recording is running.
    public var isRecording: Bool { recordingSince != nil }

    /// Replaces the last dictation with `text` typed by the user, if it is still untouched in the field.
    @discardableResult
    public func correctLast(_ text: String) -> Bool {
        guard let last = lastTyped else { return false }
        dropRevision(of: last.id, because: "Replaced by a typed correction")
        guard case .typed = last.typer.render(text + (last.trailingSpace ? " " : "")) else { return false }
        lastTyped?.record.text = text
        return true
    }

    /// A raw-then-fix correction still on its way would undo a fix; it is dropped, and its record written.
    private func dropRevision(of id: Int, because reason: String) {
        guard var waiting = awaitingRevision.removeValue(forKey: id) else { return }
        waiting.record.revised = false
        waiting.record.detail = reason
        onRecord(waiting.record)
    }

    /// The user typed or clicked: what is in the field is no longer known, so nothing typed so far is corrected.
    public func userInput() {
        lastTyped?.typer.userInterfered()
    }

    /// Waits until every dictation in flight has been typed, corrected, or has failed.
    public func settle() async {
        while !tasks.isEmpty {
            let running = tasks
            tasks.removeAll()
            for task in running { await task.value }
        }
    }

    // MARK: recording to transcript

    private func finish(recording: Recording, since: Double, context: DictationContext, purpose: DictationPurpose) {
        var context = context
        // A fix replaces text in place, so it is typed once, clean.
        if purpose != .dictate { context.profile.typing = .waitForClean }
        let finishedAt = now()
        var record = DictationRecord(
            outcome: .typed,
            recordingSeconds: finishedAt - since,
            audioSeconds: Double(recording.samples.count) / Double(recording.sampleRate),
            micStartSeconds: recording.micStartSeconds,
            profile: context.profile.name)
        record.app = context.app

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
        queue.append(Pending(id: id, finishedAt: finishedAt, context: context, purpose: purpose, record: record))

        tasks.append(Task {
            let result: Result<Transcription, Error>
            do { result = .success(try await engine.transcribe(wav: wav)) } catch { result = .failure(error) }
            self.transcribed(result, for: id)
        })
    }

    private func transcribed(_ result: Result<Transcription, Error>, for id: Int) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        resultsReceived += 1
        queue[index].transcribedAt = now()
        let context = queue[index].context

        switch result {
        case .failure(let error):
            queue[index].transcript = .failure(error)
        case .success(let transcription):
            queue[index].record.request = transcription.timing
            let raw = context.dictionary.applyAlways(transcription.text, profile: context.profile.name)
            queue[index].record.rawText = raw
            queue[index].transcript = .success(raw)
            if queue[index].purpose == .rewrite {
                startRewrite(id: id, instruction: raw)
            } else if let cleaner = context.cleaner, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                queue[index].record.cleanupModel = cleaner.model
                queue[index].cleanup = .running
                startCleanup(cleaner, raw: raw, context: context, id: id)
            }
        }
        flush()
    }

    // MARK: clean-up

    /// Asks the model to rewrite the last dictation by `instruction`. Without a last dictation or a model the
    /// rewrite stays undone, and finishing it says why.
    private func startRewrite(id: Int, instruction: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let context = queue[index].context
        queue[index].record.instruction = instruction
        guard let last = lastTyped, let text = last.record.text, let rewriter = context.rewriter ?? context.cleaner,
              !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        queue[index].rewriteBase = last.id
        queue[index].record.cleanupModel = rewriter.model
        queue[index].cleanup = .running
        let system = RewritePrompt.system(for: context.profile)
        let request = RewritePrompt.user(text: text, instruction: instruction)
        let limit = rewriteTimeout
        tasks.append(Task {
            let result = await Self.clean(request, with: rewriter, instructions: system, limit: limit)
            self.cleaned(result, for: id)
        })
    }

    private func startCleanup(_ cleaner: Cleaner, raw: String, context: DictationContext, id: Int) {
        let instructions = CleanupPrompt.system(for: context.profile, dictionary: context.dictionary)
        let limit = context.profile.typing == .waitForClean ? cleanupTimeout : revisionTimeout
        tasks.append(Task {
            var result = await Self.clean(raw, with: cleaner, instructions: instructions, limit: limit)
            if case .success(var cleaned) = result {
                let answered = cleaned
                cleaned.text = CleanupGuard.repair(raw: raw, cleaned: cleaned.text, profile: context.profile)
                if let reason = CleanupGuard.problem(raw: raw, cleaned: cleaned.text, profile: context.profile, dictionary: context.dictionary) {
                    result = .failure(CleanupRejected(reason: reason, cleaned: answered))
                } else {
                    result = .success(cleaned)
                }
            }
            self.cleaned(result, for: id)
        })
    }

    /// A clean-up that answered but strayed from what was said; the spoken words are typed instead.
    private struct CleanupRejected: Error {
        let reason: String
        let cleaned: Transcription
    }

    /// Notes a failed or rejected clean-up in the record.
    private static func note(_ error: Error, in record: inout DictationRecord) {
        if let rejected = error as? CleanupRejected {
            record.cleanedText = rejected.cleaned.text
            record.cleanup = rejected.cleaned.timing
            record.cleanupRejected = rejected.reason
        } else {
            record.cleanupError = message(error)
        }
    }

    private struct CleanupTimeout: Error, CustomStringConvertible {
        let limit: Double
        var description: String { "Clean-up took longer than \(String(format: "%g", limit)) s" }
    }

    /// The clean-up, or a timeout error when it takes longer than `limit` seconds. Two separate tasks race, so a
    /// clean-up that never answers cannot hold the dictation up (a task group would wait for it); a late answer
    /// is ignored.
    private nonisolated static func clean(_ raw: String, with cleaner: Cleaner, instructions: String, limit: Double) async -> Result<Transcription, Error> {
        await withCheckedContinuation { continuation in
            let once = Once()
            Task {
                let result: Result<Transcription, Error>
                do { result = .success(try await cleaner.clean(raw, instructions: instructions)) } catch { result = .failure(error) }
                if once.claim() { continuation.resume(returning: result) }
            }
            Task {
                try? await Task.sleep(for: .seconds(limit))
                if once.claim() { continuation.resume(returning: .failure(CleanupTimeout(limit: limit))) }
            }
        }
    }

    private func cleaned(_ result: Result<Transcription, Error>, for id: Int) {
        if let index = queue.firstIndex(where: { $0.id == id }) {
            // Not typed yet: the clean text, or the raw on failure, is what gets typed.
            queue[index].cleanup = .done(result)
            flush()
        } else if let waiting = awaitingRevision.removeValue(forKey: id) {
            revise(waiting, id: id, with: result)
        }
    }

    /// Raw-then-fix: correct the raw text in place, if it is still the last thing typed and untouched.
    private func revise(_ waiting: AwaitingRevision, id: Int, with result: Result<Transcription, Error>) {
        var record = waiting.record
        switch result {
        case .failure(let error):
            Self.note(error, in: &record)
            record.revised = false
        case .success(let transcription):
            record.cleanup = transcription.timing
            record.cleanedText = transcription.text
            let target = transcription.text + (waiting.trailingSpace ? " " : "")
            if lastTyped?.id != id {
                record.revised = false
                record.detail = "Not corrected: a later dictation was typed after it"
            } else if case .typed = waiting.typer.render(target) {
                record.revised = true
                record.text = transcription.text
                lastTyped?.record.text = transcription.text
            } else {
                record.revised = false
                record.detail = "Not corrected: you typed or clicked after it was typed"
            }
        }
        onRecord(record)
    }

    // MARK: typing

    private func flush() {
        while let first = queue.first, first.isReady {
            queue.removeFirst()
            complete(first)
        }
        updateStatus()
    }

    private func complete(_ pending: Pending) {
        var record = pending.record
        let start = now()
        if let transcribedAt = pending.transcribedAt {
            record.transcribeSeconds = transcribedAt - pending.finishedAt
            record.waitSeconds = start - transcribedAt
        }

        let raw: String
        switch pending.transcript {
        case .failure(let error)?:
            let message = Self.message(error)
            record.outcome = .failed
            record.detail = message
            lastFailure = message
            onRecord(record)
            return
        case .success(let text)?:
            raw = text
        case nil:
            return
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            record.outcome = .empty
            onRecord(record)
            return
        }

        if pending.purpose == .rewrite { return completeRewrite(pending, start: start) }

        var text = raw
        var revisionPending = false
        switch pending.cleanup {
        case .none:
            break
        case .running:
            revisionPending = true
        case .done(.success(let transcription)):
            text = transcription.text
            record.cleanup = transcription.timing
            record.cleanedText = transcription.text
        case .done(.failure(let error)):
            Self.note(error, in: &record)
        }

        if pending.purpose == .fix { return completeFix(pending, record: record, text: text, start: start) }

        let trailingSpace = pending.context.profile.trailingSpace
        let typer = LiveTyper(keyboard: keyboard)
        typer.render(text + (trailingSpace ? " " : ""))
        let end = now()
        record.text = text
        lastTyped = (pending.id, typer, record, trailingSpace)
        record.typingSeconds = end - start
        record.finishToTypedSeconds = end - pending.finishedAt

        if revisionPending {
            awaitingRevision[pending.id] = AwaitingRevision(record: record, typer: typer, trailingSpace: trailingSpace)
        } else {
            onRecord(record)
        }
    }

    /// A rewrite: replaces the last dictation with the model's rewrite, if it is still the last thing typed and
    /// untouched. A failed rewrite leaves the text alone; the instruction itself is never typed.
    private func completeRewrite(_ pending: Pending, start: Double) {
        var record = pending.record
        func fail(_ message: String) {
            record.outcome = .failed
            record.detail = message
            lastFailure = message
            onRecord(record)
        }
        guard let base = pending.rewriteBase, case .done(let result) = pending.cleanup else {
            return fail(lastTyped == nil ? "Nothing to rewrite: no dictation was typed yet" : "Nothing to rewrite with: no clean-up model is set")
        }
        let rewritten: Transcription
        switch result {
        case .failure(let error): return fail("Rewrite failed: " + Self.message(error))
        case .success(let transcription): rewritten = transcription
        }
        guard let last = lastTyped, last.id == base else {
            return fail("Not rewritten: another dictation was typed meanwhile")
        }
        dropRevision(of: last.id, because: "Replaced by a rewrite")
        record.cleanup = rewritten.timing
        record.text = rewritten.text
        record.fixes = last.record.id
        onCorrection?(Feedback(source: .rewritten, record: last.record, correctedText: rewritten.text, instruction: pending.record.instruction))
        guard case .typed = last.typer.render(rewritten.text + (last.trailingSpace ? " " : "")) else {
            return fail("Not replaced: you typed or clicked after it was typed. The rewrite was saved.")
        }
        var replaced = last.record
        replaced.text = rewritten.text
        lastTyped = (pending.id, last.typer, replaced, last.trailingSpace)
        let end = now()
        record.typingSeconds = end - start
        record.finishToTypedSeconds = end - pending.finishedAt
        onRecord(record)
    }

    /// A fix: replaces the last dictation in place when the field still holds it as typed. Either way the
    /// correction is reported, since what the user meant is worth keeping even when it cannot be typed.
    private func completeFix(_ pending: Pending, record: DictationRecord, text: String, start: Double) {
        var record = record
        record.text = text
        guard let last = lastTyped else {
            record.outcome = .failed
            record.detail = "Nothing to fix: no dictation was typed yet"
            lastFailure = record.detail
            onRecord(record)
            return
        }
        dropRevision(of: last.id, because: "Replaced by a fix")
        record.fixes = last.record.id
        onCorrection?(Feedback(source: .resaid, record: last.record, correctedText: text))
        if case .typed = last.typer.render(text + (last.trailingSpace ? " " : "")) {
            var replaced = last.record
            replaced.text = text
            lastTyped = (pending.id, last.typer, replaced, last.trailingSpace)
            let end = now()
            record.typingSeconds = end - start
            record.finishToTypedSeconds = end - pending.finishedAt
        } else {
            record.outcome = .failed
            record.detail = "Not replaced: you typed or clicked after it was typed. The correction was saved."
            lastFailure = record.detail
        }
        onRecord(record)
    }

    private static func message(_ error: Error) -> String {
        if let error = error as? TranscriptionError { return error.description }
        if let error = error as? CleanupTimeout { return error.description }
        return error.localizedDescription
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

/// True for the first caller of `claim` only.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

extension DictationRecord {
    /// A record with only its outcome set, for code outside this module (tests, tools).
    public init(outcome: Outcome) {
        self.init(outcome: outcome, detail: nil)
    }
}
