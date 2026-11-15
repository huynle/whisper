/// The user's dictation hotkey: a modifier key on its own (`modifiers` 0, e.g. Right Option) or a key with
/// modifiers (e.g. Control-Space). Key codes and flag bits are macOS's.
public struct HotkeyBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    /// Device-independent modifier flags that must be held with the key (Command, Option, Control, Shift).
    public var modifiers: UInt64
    /// A second modifier key held together with the first (e.g. Right Option + Right Shift); nil for one key.
    public var secondKeyCode: UInt16?

    public init(keyCode: UInt16, modifiers: UInt64, secondKeyCode: UInt16? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.secondKeyCode = secondKeyCode
    }

    /// The modifier keys that make up a modifier-only binding.
    var keys: [UInt16] { [keyCode] + (secondKeyCode.map { [$0] } ?? []) }

    /// The first-run default. Wispr Flow defaults to Fn, so this avoids a clash while both run.
    public static let rightOption = HotkeyBinding(keyCode: 61, modifiers: 0)
    public static let rightCommand = HotkeyBinding(keyCode: 54, modifiers: 0)
    /// The fix hotkey's default: the dictation key with Right Shift added.
    public static let rightOptionRightShift = HotkeyBinding(keyCode: 61, modifiers: 0, secondKeyCode: 60)
    /// The rewrite hotkey's default.
    public static let rightOptionRightCommand = HotkeyBinding(keyCode: 61, modifiers: 0, secondKeyCode: 54)

    /// True when this binding is `other` (a single modifier key) with one more modifier key held.
    public func extends(_ other: HotkeyBinding) -> Bool {
        isModifierOnly && other.isModifierOnly && other.secondKeyCode == nil && secondKeyCode != nil && keys.contains(other.keyCode)
    }

    /// True for a modifier key used on its own.
    public var isModifierOnly: Bool {
        modifiers == 0 && keys.allSatisfy { ModifierKey.named[$0] != nil }
    }

    public var displayName: String {
        if isModifierOnly, let first = ModifierKey.named[keyCode]?.name {
            // The added key counts on either side, so it is named without one.
            guard let second = secondKeyCode.flatMap({ ModifierKey.named[$0]?.name }) else { return first }
            return first + " + " + second.replacingOccurrences(of: "Left ", with: "").replacingOccurrences(of: "Right ", with: "")
        }
        let symbols = ModifierKey.symbols.filter { modifiers & $0.flag != 0 }.map(\.symbol).joined()
        return symbols + (KeyNames.name(for: keyCode) ?? "Key \(keyCode)")
    }
}

/// Modifier keys that can be a hotkey on their own, with the flag bit that says which side is down.
enum ModifierKey {
    struct Info {
        let name: String
        let deviceBit: UInt64
    }

    static let named: [UInt16: Info] = [
        54: Info(name: "Right Command", deviceBit: 0x10),
        55: Info(name: "Left Command", deviceBit: 0x08),
        56: Info(name: "Left Shift", deviceBit: 0x02),
        60: Info(name: "Right Shift", deviceBit: 0x04),
        58: Info(name: "Left Option", deviceBit: 0x20),
        61: Info(name: "Right Option", deviceBit: 0x40),
        59: Info(name: "Left Control", deviceBit: 0x01),
        62: Info(name: "Right Control", deviceBit: 0x2000),
        63: Info(name: "Fn", deviceBit: 0x80_0000),
    ]

    /// The device-independent modifiers a combination may require, in the order macOS shows them.
    static let symbols: [(flag: UInt64, symbol: String)] = [
        (0x40000, "⌃"), (0x80000, "⌥"), (0x20000, "⇧"), (0x100000, "⌘"),
    ]

    /// The key and its twin on the other side (Left and Right Command); Fn has no twin.
    static func bothSides(_ keyCode: UInt16) -> [UInt16] {
        let pairs: [[UInt16]] = [[54, 55], [56, 60], [58, 61], [59, 62]]
        return pairs.first { $0.contains(keyCode) } ?? [keyCode]
    }

    static let comboMask: UInt64 = symbols.reduce(0) { $0 | $1.flag }
}

enum KeyNames {
    private static let names: [UInt16: String] = {
        var table: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        let ansi: [(UInt16, String)] = [
            (0, "A"), (1, "S"), (2, "D"), (3, "F"), (4, "H"), (5, "G"), (6, "Z"), (7, "X"), (8, "C"), (9, "V"),
            (11, "B"), (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (16, "Y"), (17, "T"), (18, "1"), (19, "2"),
            (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"), (26, "7"), (27, "-"), (28, "8"),
            (29, "0"), (30, "]"), (31, "O"), (32, "U"), (33, "["), (34, "I"), (35, "P"), (37, "L"), (38, "J"),
            (39, "'"), (40, "K"), (41, ";"), (42, "\\"), (43, ","), (44, "/"), (45, "N"), (46, "M"), (47, "."),
            (50, "`"),
        ]
        for (code, name) in ansi { table[code] = name }
        return table
    }()

    static func name(for keyCode: UInt16) -> String? { names[keyCode] }
}

/// A key event as the hotkey listener sees it.
public enum KeyInput: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    case keyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool)
    case keyUp(keyCode: UInt16, flags: UInt64)
}

public enum KeyMatch: Equatable, Sendable {
    case bindingDown, bindingUp, otherKey, ignore
}

/// Turns raw key events into presses and releases of the binding, and other key presses.
public struct BindingMatcher {
    public let binding: HotkeyBinding
    private var isDown = false
    private var lastInput: KeyInput?
    private var lastSwallowed = false

    public init(binding: HotkeyBinding) {
        self.binding = binding
    }

    public mutating func handle(_ input: KeyInput) -> KeyMatch {
        let match = binding.isModifierOnly ? matchModifier(input) : matchCombo(input)
        lastInput = input
        lastSwallowed = !binding.isModifierOnly && (match == .bindingDown || match == .bindingUp || isRepeatOfBinding(input))
        return match
    }

    /// Whether `input`, just handled, must be kept from the focused app. A combination is swallowed so the app
    /// never acts on it (Control-Space would type a NUL in a terminal); a modifier on its own does nothing there.
    public func swallows(_ input: KeyInput) -> Bool {
        lastInput == input && lastSwallowed
    }

    private mutating func matchModifier(_ input: KeyInput) -> KeyMatch {
        switch input {
        case .flagsChanged(let keyCode, let flags):
            // The first key is matched on its side; an added second key on either side (Right Option with the
            // left or right Command), since the two are easy to mix up.
            let first = binding.keyCode
            let second = binding.secondKeyCode.map(ModifierKey.bothSides) ?? []
            guard keyCode == first || second.contains(keyCode) else { return .ignore }
            let isHeld = { (key: UInt16) in ModifierKey.named[key].map { flags & $0.deviceBit != 0 } ?? false }
            let down = isHeld(first) && (second.isEmpty || second.contains(where: isHeld))
            if down == isDown { return .ignore }
            isDown = down
            return down ? .bindingDown : .bindingUp
        case .keyDown:
            return .otherKey
        case .keyUp:
            return .ignore
        }
    }

    private mutating func matchCombo(_ input: KeyInput) -> KeyMatch {
        switch input {
        case .keyDown(let keyCode, let flags, let isRepeat):
            if isRepeatOfBinding(input) { return .ignore }
            if keyCode == binding.keyCode, !isRepeat, flags & ModifierKey.comboMask == binding.modifiers {
                isDown = true
                return .bindingDown
            }
            return .otherKey
        case .keyUp(let keyCode, _):
            guard keyCode == binding.keyCode, isDown else { return .ignore }
            isDown = false
            return .bindingUp
        case .flagsChanged:
            return .ignore
        }
    }

    private func isRepeatOfBinding(_ input: KeyInput) -> Bool {
        if case .keyDown(let keyCode, _, true) = input { return isDown && keyCode == binding.keyCode }
        return false
    }
}
