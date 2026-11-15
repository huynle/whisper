public enum GestureAction: Equatable, Sendable {
    /// Start recording.
    case start
    /// Stop recording and transcribe.
    case finish
    /// Stop recording and throw the audio away.
    case cancel
    /// Keep recording after the key is released, until it is pressed again.
    case lock
}

/// Turns presses of the dictation hotkey into actions: hold to talk, double-tap to lock, tap again to finish.
/// Recording starts on the first press, so nothing is lost while it is still unclear which gesture it is.
/// Times are in seconds on any steady clock.
public final class HotkeyGesture {
    public struct Timings: Sendable {
        /// A press shorter than this is a tap.
        public var tapMax: Double
        /// After a tap, a second press must start within this time to lock.
        public var doubleTapWindow: Double

        public init(tapMax: Double, doubleTapWindow: Double) {
            self.tapMax = tapMax
            self.doubleTapWindow = doubleTapWindow
        }

        public static let standard = Timings(tapMax: 0.3, doubleTapWindow: 0.4)
    }

    private enum State: Equatable {
        case idle
        case holding(since: Double)
        case waitingForSecondTap(until: Double)
        /// Locked; `pressed` while the press that locked it, or the one that finishes it, is still down.
        case locked(pressed: Bool)
        /// The key is still down after an action that ended the dictation; its release does nothing.
        case ignoringRelease
    }

    private let timings: Timings
    private var state = State.idle

    public init(timings: Timings = .standard) {
        self.timings = timings
    }

    /// True while the key is held at the start of a dictation (not locked).
    public var isHolding: Bool {
        if case .holding = state { return true }
        return false
    }

    /// The press was taken over (it became a fix): forget it, ignoring the key's release if it is still down.
    public func abandonPress(keyStillDown: Bool) {
        state = keyStillDown ? .ignoringRelease : .idle
    }

    /// When `tick` must be called next, or nil when no timer is needed.
    public var deadline: Double? {
        if case .waitingForSecondTap(let until) = state { return until }
        return nil
    }

    public func keyDown(at time: Double) -> [GestureAction] {
        switch state {
        case .idle:
            state = .holding(since: time)
            return [.start]
        case .waitingForSecondTap:
            state = .locked(pressed: true)
            return [.lock]
        case .locked(pressed: false):
            state = .ignoringRelease
            return [.finish]
        case .holding, .locked(pressed: true), .ignoringRelease:
            return []
        }
    }

    public func keyUp(at time: Double) -> [GestureAction] {
        switch state {
        case .holding(let since):
            if time - since >= timings.tapMax {
                state = .idle
                return [.finish]
            }
            state = .waitingForSecondTap(until: time + timings.doubleTapWindow)
            return []
        case .locked(pressed: true):
            state = .locked(pressed: false)
            return []
        case .ignoringRelease:
            state = .idle
            return []
        case .idle, .waitingForSecondTap, .locked(pressed: false):
            return []
        }
    }

    /// Another key was pressed. While the hotkey is held or a second tap is awaited, the user is using the hotkey
    /// as part of a shortcut, so the dictation is cancelled. A locked dictation carries on.
    public func otherKey(at time: Double) -> [GestureAction] {
        switch state {
        case .holding:
            state = .ignoringRelease
            return [.cancel]
        case .waitingForSecondTap:
            state = .idle
            return [.cancel]
        case .idle, .locked, .ignoringRelease:
            return []
        }
    }

    public func tick(at time: Double) -> [GestureAction] {
        if case .waitingForSecondTap(let until) = state, time >= until {
            state = .idle
            return [.cancel]
        }
        return []
    }
}
