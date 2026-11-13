import AVFoundation
import DictationCore
import Foundation

/// The microphone as 16 kHz mono audio. It stays running ("warm") for a while after each dictation so the
/// next press records at once, and keeps the last 0.3 s heard while warm so a first word started slightly
/// before the press is not clipped.
final class MicRecorder: AudioRecorder {
    static let sampleRate = 16_000
    private static let prerollSamples = 4_800

    /// Seconds the microphone stays on after a dictation: 0 stops it at once, infinity never.
    var warmSeconds: Double = 60

    private let engine = AVAudioEngine()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var stopTimer: Timer?

    private let lock = NSLock()
    private var recording = false
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var beganAt: Double = 0
    private var firstAudioAt: Double?
    private var coldStart = false

    private(set) var lastError: String?

    init() {
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            // A microphone was plugged in or removed: start again with the new format on the next press.
            self?.stopEngine()
        }
    }

    func begin() {
        stopTimer?.invalidate()
        lock.withLock {
            samples = preroll
            preroll = []
            recording = true
            firstAudioAt = nil
        }
        beganAt = ProcessInfo.processInfo.systemUptime
        coldStart = !engine.isRunning
        if coldStart { startEngine() }
    }

    func end() -> Recording {
        let (audio, firstAt) = stopRecording()
        keepWarm()
        let micStart = coldStart ? firstAt.map { $0 - beganAt } : nil
        return Recording(samples: audio, sampleRate: Self.sampleRate, micStartSeconds: micStart)
    }

    func discard() {
        _ = stopRecording()
        keepWarm()
    }

    private func stopRecording() -> ([Float], Double?) {
        lock.withLock {
            recording = false
            let audio = samples
            samples = []
            return (audio, firstAudioAt)
        }
    }

    private func startEngine() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let converter = AVAudioConverter(from: format, to: target) else {
            lastError = "No microphone input is available"
            return
        }
        self.converter = converter
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            lastError = nil
        } catch {
            lastError = "The microphone could not start: \(error.localizedDescription)"
        }
    }

    private func stopEngine() {
        stopTimer?.invalidate()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { preroll = [] }
    }

    private func keepWarm() {
        stopTimer?.invalidate()
        if warmSeconds.isInfinite { return }
        if warmSeconds <= 0 {
            stopEngine()
            return
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: warmSeconds, repeats: false) { [weak self] _ in
            guard let self, !self.lock.withLock({ self.recording }) else { return }
            self.stopEngine()
        }
    }

    /// Runs on the audio thread.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return }
        let converted = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if recording {
                if firstAudioAt == nil { firstAudioAt = now }
                samples += converted
            } else {
                preroll += converted
                if preroll.count > Self.prerollSamples { preroll.removeFirst(preroll.count - Self.prerollSamples) }
            }
        }
    }
}
