/// What a recording is for.
public enum DictationPurpose: Equatable, Sendable {
    /// Typed where the cursor is.
    case dictate
    /// Said again: replaces the last dictation.
    case fix
    /// An instruction ("make it more formal"): a model rewrites the last dictation by it.
    case rewrite
}

/// Combines the dictation hotkey with the fix and rewrite hotkeys into what to do. Each of those is either a key
/// of its own (hold to talk, tap to type, `FixGesture`) or the dictation key with one more modifier, such as
/// Right Option + Right Shift. Then the dictation starts the moment Right Option goes down, and the added key
/// turns the running recording into a fix or an instruction, so nothing said is lost; tapping both opens a box.
public final class HotkeyPad {
    public enum Action: Equatable, Sendable {
        case dictation(GestureAction)
        /// Start recording (a separate key, held).
        case start(DictationPurpose)
        /// The dictation recording running now is for this.
        case upgrade(DictationPurpose)
        case finish(DictationPurpose)
        /// Throw the recording away, with the cancel sound.
        case cancel(DictationPurpose)
        /// Throw the recording away quietly: the press was a tap.
        case discard(DictationPurpose)
        /// Open the box to type the fix or the instruction.
        case openBox(DictationPurpose)
    }

    /// Hotkey positions: 1 fixes, 3 rewrites (2 is the review hotkey, which is not a gesture).
    public static let purposes: [Int: DictationPurpose] = [1: .fix, 3: .rewrite]

    /// By position: whether that hotkey is the dictation key with one more modifier.
    public var extendsDictationKey: [Int: Bool]
    private let gesture: HotkeyGesture
    private var separate: [Int: FixGesture] = [:]
    private let tapMax: Double
    private var pressStart: Double?
    /// The hotkey whose added key turned the current press into a fix or an instruction.
    private var upgradedBy: Int?

    public init(extendsDictationKey: [Int: Bool], timings: HotkeyGesture.Timings = .standard) {
        self.extendsDictationKey = extendsDictationKey
        gesture = HotkeyGesture(timings: timings)
        tapMax = timings.tapMax
        for index in Self.purposes.keys { separate[index] = FixGesture(tapMax: timings.tapMax) }
    }

    public var deadline: Double? {
        ([gesture.deadline] + separate.values.map(\.deadline)).compactMap { $0 }.min()
    }

    public func tick(at time: Double) -> [Action] {
        var actions = gesture.tick(at: time).map(Action.dictation)
        for (index, fixGesture) in separate.sorted(by: { $0.key < $1.key }) {
            actions += fixGesture.tick(at: time).map { Self.action($0, Self.purposes[index]!) }
        }
        return actions
    }

    /// `index` 0: the dictation hotkey; 1: fix; 3: rewrite.
    public func handle(_ index: Int, _ match: KeyMatch, at time: Double) -> [Action] {
        guard index != 0 else { return dictationKey(match, at: time) }
        guard let purpose = Self.purposes[index] else { return [] }
        return extendsDictationKey[index] == true ? addedKey(index, purpose, match, at: time) : separateKey(index, purpose, match, at: time)
    }

    private func dictationKey(_ match: KeyMatch, at time: Double) -> [Action] {
        if upgradedBy != nil {
            switch match {
            case .bindingUp:
                // The added key's release, in the same event, finishes the press.
                gesture.abandonPress(keyStillDown: false)
                return []
            case .otherKey:
                upgradedBy = nil
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

    private func addedKey(_ index: Int, _ purpose: DictationPurpose, _ match: KeyMatch, at time: Double) -> [Action] {
        switch match {
        case .bindingDown:
            guard gesture.isHolding, upgradedBy == nil else { return [] }
            upgradedBy = index
            return [.upgrade(purpose)]
        case .bindingUp:
            guard upgradedBy == index else { return [] }
            upgradedBy = nil
            if gesture.isHolding { gesture.abandonPress(keyStillDown: true) }
            let tapped = time - (pressStart ?? time) < tapMax
            return tapped ? [.discard(purpose), .openBox(purpose)] : [.finish(purpose)]
        case .otherKey, .ignore:
            return []
        }
    }

    private func separateKey(_ index: Int, _ purpose: DictationPurpose, _ match: KeyMatch, at time: Double) -> [Action] {
        guard let fixGesture = separate[index] else { return [] }
        let actions: [FixAction]
        switch match {
        case .bindingDown: actions = fixGesture.keyDown(at: time)
        case .bindingUp: actions = fixGesture.keyUp(at: time)
        case .otherKey: actions = fixGesture.otherKey(at: time)
        case .ignore: actions = []
        }
        return actions.map { Self.action($0, purpose) }
    }

    private static func action(_ fix: FixAction, _ purpose: DictationPurpose) -> Action {
        switch fix {
        case .start: .start(purpose)
        case .finish: .finish(purpose)
        case .cancel: .cancel(purpose)
        case .openBox: .openBox(purpose)
        }
    }
}
