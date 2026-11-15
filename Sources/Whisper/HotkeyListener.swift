import CoreGraphics
import DictationCore
import Foundation

/// Watches every key event system-wide and reports presses and releases of the hotkey, and other key presses.
/// A key combination is kept from the focused app; everything else passes through untouched.
/// Needs Accessibility permission (an event tap that may drop events).
final class HotkeyListener {
    /// The hotkeys listened for, by position (dictate, fix, review); nil for one not set.
    var bindings: [HotkeyBinding?] {
        didSet { router = HotkeyRouter(bindings: bindings) }
    }

    /// While true (recording a new shortcut in Settings), events pass through unexamined.
    var paused = false

    private var router: HotkeyRouter
    private var tap: CFMachPort?
    private let onMatch: (Int, KeyMatch, Double) -> Void
    /// A mouse click anywhere: the user may have moved the cursor, so typed text must not be corrected.
    var onClick: (() -> Void)?
    private let ownProcess = Int64(getpid())

    init(bindings: [HotkeyBinding?], onMatch: @escaping (Int, KeyMatch, Double) -> Void) {
        self.bindings = bindings
        self.router = HotkeyRouter(bindings: bindings)
        self.onMatch = onMatch
    }

    var isRunning: Bool { tap != nil }

    /// Starts listening; false when macOS refuses (no Accessibility permission yet).
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                let listener = Unmanaged<HotkeyListener>.fromOpaque(info!).takeUnretainedValue()
                return listener.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off when it is slow or on some user input; switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // The app's own typing is never a hotkey or the user's input.
        if paused || event.getIntegerValueField(.eventSourceUnixProcessID) == ownProcess {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            if let onClick { DispatchQueue.main.async(execute: onClick) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let input: KeyInput
        switch type {
        case .flagsChanged: input = .flagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown: input = .keyDown(keyCode: keyCode, flags: flags, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        case .keyUp: input = .keyUp(keyCode: keyCode, flags: flags)
        default: return Unmanaged.passUnretained(event)
        }

        let (matches, swallow) = router.handle(input)
        if !matches.isEmpty {
            let time = ProcessInfo.processInfo.systemUptime
            // Return to macOS at once; starting the microphone can take long enough for the tap to be switched off.
            DispatchQueue.main.async { for (index, match) in matches { self.onMatch(index, match, time) } }
        }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
