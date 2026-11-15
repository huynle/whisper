/// Combines the dictation hotkey and the fix hotkey into what to do. The fix hotkey is either a key of its own
/// (hold to say it again, tap to type it, `FixGesture`) or the dictation key with one more modifier, such as
/// Right Option + Right Shift. In that case the dictation starts the moment Right Option goes down, and adding
/// Right Shift turns the running recording into a fix, so nothing said is lost; tapping both opens the box.
public final class HotkeyPad {
    public enum Action: Equatable, Sendable {
        case dictation(GestureAction)
        /// Start recording a fix (a separate fix key, held).
        case fixStart
        /// The dictation recording running now is a fix.
        case fixFromDictation
        case fixFinish
        /// Throw the fix away, with the cancel sound.
        case fixCancel
        /// Throw the recording away quietly: the press was a tap.
        case fixDiscard
        case openBox
    }

    public var fixSharesDictationKey: Bool
    private let gesture: HotkeyGesture
    private let fixGesture: FixGesture
    private let tapMax: Double
    /// When the current press of the dictation key started.
    private var pressStart: Double?
    /// The current press became a fix.
    private var upgraded = false

    public init(fixSharesDictationKey: Bool, timings: HotkeyGesture.Timings = .standard) {
        self.fixSharesDictationKey = fixSharesDictationKey
        gesture = HotkeyGesture(timings: timings)
        fixGesture = FixGesture(tapMax: timings.tapMax)
        tapMax = timings.tapMax
    }

    public var deadline: Double? {
        [gesture.deadline, fixGesture.deadline].compactMap { $0 }.min()
    }

    public func tick(at time: Double) -> [Action] {
        gesture.tick(at: time).map(Action.dictation) + fixGesture.tick(at: time).map(Self.action)
    }

    /// `index` 0: the dictation hotkey, 1: the fix hotkey.
    public func handle(_ index: Int, _ match: KeyMatch, at time: Double) -> [Action] {
        index == 0 ? dictationKey(match, at: time) : fixKey(match, at: time)
    }

    private func dictationKey(_ match: KeyMatch, at time: Double) -> [Action] {
        if upgraded {
            switch match {
            case .bindingUp:
                // The fix key's release, in the same event, finishes the fix.
                gesture.abandonPress(keyStillDown: false)
                return []
            case .otherKey:
                upgraded = false
                return gesture.otherKey(at: time).map(Action.dictation)
            case .bindingDown, .ignore:
                return []
            }
        }
        switch match {
        case .bindingDown:
            if !gesture.isHolding { pressStart = time }
            return gesture.keyDown(at: time).map(Action.dictation)
        case .bindingUp: return gesture.keyUp(at: time).map(Action.dictation)
        case .otherKey: return gesture.otherKey(at: time).map(Action.dictation)
        case .ignore: return []
        }
    }

    private func fixKey(_ match: KeyMatch, at time: Double) -> [Action] {
        guard fixSharesDictationKey else {
            switch match {
            case .bindingDown: return fixGesture.keyDown(at: time).map(Self.action)
            case .bindingUp: return fixGesture.keyUp(at: time).map(Self.action)
            case .otherKey: return fixGesture.otherKey(at: time).map(Self.action)
            case .ignore: return []
            }
        }
        switch match {
        case .bindingDown:
            guard gesture.isHolding, !upgraded else { return [] }
            upgraded = true
            return [.fixFromDictation]
        case .bindingUp:
            guard upgraded else { return [] }
            upgraded = false
            if gesture.isHolding { gesture.abandonPress(keyStillDown: true) }
            let tapped = time - (pressStart ?? time) < tapMax
            return tapped ? [.fixDiscard, .openBox] : [.fixFinish]
        case .otherKey, .ignore:
            return []
        }
    }

    private static func action(_ fix: FixAction) -> Action {
        switch fix {
        case .start: .fixStart
        case .finish: .fixFinish
        case .cancel: .fixCancel
        case .openBox: .openBox
        }
    }
}
