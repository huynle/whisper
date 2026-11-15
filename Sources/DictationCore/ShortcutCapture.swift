/// Records a new hotkey from the keys the user presses in Settings: a modifier pressed and released on its
/// own, a key with modifiers, or a function key. Keys that would get in the way of normal typing are refused.
public struct ShortcutCapture {
    public enum Result: Equatable {
        case listening
        case bound(HotkeyBinding)
        /// Not usable; listening continues.
        case rejected(String)
        case cancelled
    }

    public static let plainKeyMessage = "Use a modifier key alone, a function key, or a key with ⌃, ⌥, ⇧ or ⌘."
    public static let tooManyMessage = "Use one or two modifier keys together."
    public static let shiftMessage = "Shift alone is pressed too often while typing. Choose another key."

    private static let escape: UInt16 = 53
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let shiftKeys: Set<UInt16> = [56, 60]

    /// The modifier keys down now, and the most held together during this press, in the order pressed.
    private var held: [UInt16] = []
    private var peak: [UInt16] = []

    public init() {}

    public mutating func handle(_ input: KeyInput) -> Result {
        switch input {
        case .flagsChanged(let keyCode, let flags):
            guard let bit = ModifierKey.named[keyCode]?.deviceBit else { return .listening }
            if flags & bit != 0 {
                if !held.contains(keyCode) { held.append(keyCode) }
                if held.count > peak.count { peak = held }
                return .listening
            }
            guard held.contains(keyCode) else { return .listening }
            held.removeAll { $0 == keyCode }
            guard held.isEmpty, !peak.isEmpty else { return .listening }
            let keys = peak
            peak = []
            switch keys.count {
            case 1:
                if Self.shiftKeys.contains(keys[0]) { return .rejected(Self.shiftMessage) }
                return .bound(HotkeyBinding(keyCode: keys[0], modifiers: 0))
            case 2:
                return .bound(HotkeyBinding(keyCode: keys[0], modifiers: 0, secondKeyCode: keys[1]))
            default:
                return .rejected(Self.tooManyMessage)
            }
        case .keyDown(let keyCode, let flags, _):
            held = []
            peak = []
            let modifiers = flags & ModifierKey.comboMask
            if modifiers != 0 { return .bound(HotkeyBinding(keyCode: keyCode, modifiers: modifiers)) }
            if keyCode == Self.escape { return .cancelled }
            if Self.functionKeys.contains(keyCode) { return .bound(HotkeyBinding(keyCode: keyCode, modifiers: 0)) }
            return .rejected(Self.plainKeyMessage)
        case .keyUp:
            return .listening
        }
    }
}
