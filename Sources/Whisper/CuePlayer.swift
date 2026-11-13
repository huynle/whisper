import AppKit
import DictationCore

/// Plays the sound cues. Each is rendered once per volume, so playing one costs nothing at the moment it is needed.
@MainActor
final class CuePlayer {
    private static let sampleRate = 44_100
    private var sounds: [Cue: NSSound] = [:]

    /// The loudest sample, 0 to 1; 0 turns the cues off.
    var volume: Float = 0 {
        didSet { if volume != oldValue { render() } }
    }

    func play(_ cue: Cue) {
        guard volume > 0, let sound = sounds[cue] else { return }
        sound.stop()
        sound.play()
    }

    private func render() {
        sounds = [:]
        guard volume > 0 else { return }
        for cue in Cue.allCases {
            let wav = WAV.encode(cue.render(sampleRate: Self.sampleRate, volume: volume), sampleRate: Self.sampleRate)
            sounds[cue] = NSSound(data: wav)
        }
    }
}
