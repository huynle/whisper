import Foundation

/// Short sounds that say what the microphone is doing, since nothing on screen does while the user talks.
public enum Cue: CaseIterable, Sendable {
    case microphoneOn, locked, microphoneOff, cancelled, failed
    /// The recording became a fix (Shift added) or an instruction (Command added).
    case fixMode, instructionMode

    public static func `for`(_ action: GestureAction) -> Cue {
        switch action {
        case .start: .microphoneOn
        case .lock: .locked
        case .finish: .microphoneOff
        case .cancel: .cancelled
        }
    }

    /// A finished dictation needs no sound (the text appearing says it); a failed one does.
    public static func `for`(_ status: DictationSession.Status) -> Cue? {
        if case .failed = status { return .failed }
        return nil
    }

    private enum Part {
        case note(hz: Double, ms: Double)
        case gap(ms: Double)
    }

    private var parts: [Part] {
        switch self {
        case .microphoneOn: [.note(hz: 880, ms: 40)]
        case .locked: [.note(hz: 880, ms: 40), .gap(ms: 30), .note(hz: 1_175, ms: 40)]
        case .microphoneOff: [.note(hz: 660, ms: 50)]
        case .cancelled: [.note(hz: 523, ms: 40), .gap(ms: 30), .note(hz: 392, ms: 40)]
        case .failed: [.note(hz: 294, ms: 150)]
        case .fixMode: [.note(hz: 988, ms: 35), .gap(ms: 25), .note(hz: 988, ms: 35)]
        case .instructionMode: [.note(hz: 784, ms: 35), .gap(ms: 20), .note(hz: 988, ms: 35), .gap(ms: 20), .note(hz: 1_319, ms: 45)]
        }
    }

    /// Fade in and out over this long, so a note never starts or stops with a pop.
    private static let fadeMs = 5.0

    /// The cue as mono samples; `volume` is the loudest sample (0 to 1).
    public func render(sampleRate: Int, volume: Float) -> [Float] {
        let rate = Double(sampleRate)
        var samples: [Float] = []
        for part in parts {
            switch part {
            case .gap(let ms):
                samples += Array(repeating: 0, count: Int(ms / 1_000 * rate))
            case .note(let hz, let ms):
                let count = Int(ms / 1_000 * rate)
                let fade = max(1, Int(Self.fadeMs / 1_000 * rate))
                for i in 0..<count {
                    let edge = Double(min(i, count - 1 - i))
                    let envelope = edge >= Double(fade) ? 1 : 0.5 - 0.5 * cos(Double.pi * edge / Double(fade))
                    samples.append(volume * Float(envelope * sin(2 * Double.pi * hz * Double(i) / rate)))
                }
            }
        }
        return samples
    }
}
