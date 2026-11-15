/// The modifier keys pressed and released during one press of the hotkeys, with milliseconds since the first,
/// for developer mode: it shows which keys macOS reported when a combination did not do what was meant.
/// Only modifier keys are recorded, never what is typed.
public struct KeyTrace: Sendable {
    public private(set) var entries: [String] = []
    private var start: Double?
    private var anyDown = false

    public init() {}

    public mutating func add(keyCode: UInt16, flags: UInt64, at time: Double) {
        guard let key = ModifierKey.named[keyCode] else { return }
        // A press that begins with every modifier up starts a new trace.
        if !anyDown {
            entries = []
            start = time
        }
        let down = flags & key.deviceBit != 0
        entries.append("\(Int(((time - (start ?? time)) * 1000).rounded())) \(down ? "+" : "-")\(key.name)")
        anyDown = ModifierKey.named.values.contains { flags & $0.deviceBit != 0 }
    }
}
