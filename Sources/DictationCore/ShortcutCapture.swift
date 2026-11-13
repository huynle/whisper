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
    public static let shiftMessage = "Shift alone is pressed too often while typing. Choose another key."

    private static let escape: UInt16 = 53
    private static let functionKeys: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    private static let shiftKeys: Set<UInt16> = [56, 60]

    /// The modifier pressed first, while it may still become a binding on its own.
    private var candidate: UInt16?

    public init() {}

    public mutating func handle(_ input: KeyInput) -> Result {
        switch input {
        case .flagsChanged(let keyCode, let flags):
            guard let bit = ModifierKey.named[keyCode]?.deviceBit else { return .listening }
            if flags & bit != 0 {
                if candidate == nil { candidate = keyCode }
                return .listening
            }
            guard candidate == keyCode else { return .listening }
            candidate = nil
            if Self.shiftKeys.contains(keyCode) { return .rejected(Self.shiftMessage) }
            return .bound(HotkeyBinding(keyCode: keyCode, modifiers: 0))
        case .keyDown(let keyCode, let flags, _):
            candidate = nil
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
