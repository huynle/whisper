/// What a press of the fix hotkey asks for.
public enum FixAction: Equatable, Sendable {
    /// Held: record the corrected wording.
    case start
    /// Released after holding: replace the last dictation with what was said.
    case finish
    /// Part of a shortcut after all: throw the recording away.
    case cancel
    /// Tapped: open the box to type the correction.
    case openBox
}

/// Turns presses of the fix hotkey into actions: hold to say the dictation again, tap to type the correction.
/// Recording starts only once the press is clearly a hold, so a shortcut using the key (Command-C with Right
/// Command) never turns the microphone on; the microphone's pre-roll keeps the first words.
public final class FixGesture {
    private enum State: Equatable {
        case idle
        case pressed(since: Double)
        case recording
        /// Another key was pressed with it; its release does nothing.
        case ignoringRelease
    }

    private let tapMax: Double
    private var state = State.idle

    public init(tapMax: Double = HotkeyGesture.Timings.standard.tapMax) {
        self.tapMax = tapMax
    }

    /// When `tick` must be called next, or nil when no timer is needed.
    public var deadline: Double? {
        if case .pressed(let since) = state { return since + tapMax }
        return nil
    }

    public func keyDown(at time: Double) -> [FixAction] {
        if state == .idle { state = .pressed(since: time) }
        return []
    }

    public func tick(at time: Double) -> [FixAction] {
        guard case .pressed(let since) = state, time >= since + tapMax else { return [] }
        state = .recording
        return [.start]
    }

    public func keyUp(at time: Double) -> [FixAction] {
        defer { state = .idle }
        switch state {
        case .pressed: return [.openBox]
        case .recording: return [.finish]
        case .idle, .ignoringRelease: return []
        }
    }

    public func otherKey(at time: Double) -> [FixAction] {
        switch state {
        case .pressed:
            state = .ignoringRelease
            return []
        case .recording:
            state = .ignoringRelease
            return [.cancel]
        case .idle, .ignoringRelease:
            return []
        }
    }
}
