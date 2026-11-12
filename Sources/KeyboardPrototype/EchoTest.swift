// Diagnostic: types into the terminal pane this runs in and reports, for each small batch of key presses,
// what macOS saw and what arrived in the pane, so it shows at which point simulated key presses are lost.
import CoreGraphics
import DictationCore
import Foundation

nonisolated(unsafe) private var savedTerminal = termios()
nonisolated(unsafe) private var keysSeenBySystem: [Int64] = []
private let keysSeenLock = NSLock()

private func restoreTerminal() {
    // Bracketed paste off again, then the settings the shell had.
    FileHandle.standardOutput.write(Data("\u{1B}[?2004l".utf8))
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTerminal)
}

/// Reads keys as they arrive (no line editing, no echo), the way a shell prompt or an agent prompt does,
/// with bracketed paste on as they have it.
private func readKeysDirectly() -> Bool {
    guard isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &savedTerminal) == 0 else { return false }
    var direct = savedTerminal
    direct.c_lflag &= ~tcflag_t(ICANON | ECHO)
    withUnsafeMutableBytes(of: &direct.c_cc) { controls in
        controls[Int(VMIN)] = 0
        controls[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &direct)
    signal(SIGINT) { _ in
        restoreTerminal()
        exit(130)
    }
    FileHandle.standardOutput.write(Data("\u{1B}[?2004h".utf8))
    return true
}

/// Watches key presses as they pass through macOS on their way to the focused app, without changing them.
/// False when macOS does not allow it.
private func watchSystemKeys() -> Bool {
    let keyDown = CGEventMask(1 << CGEventType.keyDown.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap, eventsOfInterest: keyDown,
        callback: { _, _, event, _ in
            keysSeenLock.lock()
            keysSeenBySystem.append(event.getIntegerValueField(.keyboardEventKeycode))
            keysSeenLock.unlock()
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
    else { return false }
    nonisolated(unsafe) let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    nonisolated(unsafe) let port = tap
    Thread {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
    }.start()
    return true
}

private func arrived() -> [UInt8] {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { break }
        bytes.append(contentsOf: buffer[0..<count])
    }
    return bytes
}

private func shown(_ bytes: [UInt8]) -> String {
    bytes.isEmpty ? "nothing" : bytes.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : String(format: "<%02x>", $0) }.joined()
}

/// t = a text key, D = the Delete key, otherwise the key's number.
private func shown(keys: [Int64]) -> String {
    keys.isEmpty ? "nothing" : keys.map { $0 == 0 ? "t" : $0 == 51 ? "D" : "(\($0))" }.joined()
}

private func column(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

/// Sends one batch of keys, then listens for 1.2 seconds and prints one row of the report.
private func probe(_ name: String, sent: String, watching: Bool, _ keys: () -> Void) {
    let late = arrived()
    keysSeenLock.lock()
    keysSeenBySystem.removeAll()
    keysSeenLock.unlock()

    let start = Date()
    keys()
    var bytes: [UInt8] = []
    var first: Int?
    var last = 0
    while Date().timeIntervalSince(start) < 1.2 {
        let chunk = arrived()
        if !chunk.isEmpty {
            last = Int(Date().timeIntervalSince(start) * 1000)
            first = first ?? last
            bytes += chunk
        }
        Thread.sleep(forTimeInterval: 0.005)
    }
    keysSeenLock.lock()
    let seen = keysSeenBySystem
    keysSeenLock.unlock()

    let timing = first.map { "\($0)-\(last)ms" } ?? "-"
    let stray = late.isEmpty ? "" : "  (arrived late from the row above: \(shown(late)))"
    print(column(name, 30) + column(sent, 14) + column(watching ? shown(keys: seen) : "n/a", 12) + column(shown(bytes), 24) + timing + stray)
}

func runEchoTest() -> Int32 {
    guard readKeysDirectly() else {
        FileHandle.standardError.write(Data("--echo-test must run in a terminal pane.\n".utf8))
        return 2
    }
    defer { restoreTerminal() }

    let watching = watchSystemKeys()
    print("Keep this pane focused and do not touch the keyboard or mouse (about 25 seconds).")
    if !watching { print("macOS did not allow watching key presses, so the \"macOS saw\" column is n/a.") }
    Thread.sleep(forTimeInterval: 3)

    print("\n" + column("batch", 30) + column("sent", 14) + column("macOS saw", 12) + column("pane received", 24) + "when")
    let fast = 0.002
    let slow = 0.03
    func text(_ name: String) {
        probe(name, sent: "abc", watching: watching) { SystemKeyboard(delay: fast).type("abc") }
    }
    func deletes(_ method: DeleteMethod) {
        probe(method.rawValue, sent: "delete x3", watching: watching) { SystemKeyboard(delay: slow, delete: method).backspace(3) }
    }
    func mixed(_ name: String, _ method: DeleteMethod, delay: TimeInterval) {
        probe(name, sent: "abc del x3 d", watching: watching) {
            let keyboard = SystemKeyboard(delay: delay, delete: method)
            keyboard.type("abc")
            keyboard.backspace(3)
            keyboard.type("d")
        }
    }

    text("text, 1st time")
    text("text, 2nd time")
    for method in DeleteMethod.allCases { deletes(method) }
    text("text after deletes")
    mixed("mixed, fast", .keyModifiersLeft, delay: fast)
    mixed("mixed, slow", .keyModifiersLeft, delay: slow)
    mixed("mixed, delete held", .keyHeld, delay: slow)
    text("text, last time")

    print("\nt = text key, D = Delete key. A working delete shows as <7f> in \"pane received\".")
    return 0
}
