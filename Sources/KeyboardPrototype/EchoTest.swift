// Diagnostic: types into the terminal pane this runs in and reports the bytes that actually arrive,
// so it shows which simulated key presses reach a program in the pane and which are lost on the way.
import DictationCore
import Foundation

nonisolated(unsafe) private var savedTerminal = termios()

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
    bytes.map { (0x20...0x7E).contains($0) ? String(UnicodeScalar($0)) : String(format: "<%02x>", $0) }.joined()
}

/// Sends keys, waits for them to travel, and returns what arrived.
private func send(_ keys: () -> Void) -> [UInt8] {
    _ = arrived()
    keys()
    Thread.sleep(forTimeInterval: 0.5)
    return arrived()
}

func runEchoTest(scenario: [String]) -> Int32 {
    guard readKeysDirectly() else {
        FileHandle.standardError.write(Data("--echo-test must run in a terminal pane.\n".utf8))
        return 2
    }
    defer { restoreTerminal() }

    print("Keep this pane focused and do not touch the keyboard or mouse (about 20 seconds).")
    Thread.sleep(forTimeInterval: 3)

    let greeting = send { SystemKeyboard(delay: 0.002).type("abc") }
    guard !greeting.isEmpty else {
        print("No key presses arrived. Is this pane focused?")
        return 1
    }
    print("\ntext \"abc\" arrived as: \(shown(greeting))\n")

    // Each probe is a small revision: type "abc", delete all three, type "d". A working method leaves "d".
    print("delete method                        pace   arrived                          line     verdict")
    var working: (method: DeleteMethod, delay: TimeInterval)?
    for method in DeleteMethod.allCases {
        for delay in [0.002, 0.03] {
            let keyboard = SystemKeyboard(delay: delay, delete: method)
            let bytes = send {
                keyboard.type("abc")
                keyboard.backspace(3)
                keyboard.type("d")
            }
            let line = TerminalLine.text(after: bytes)
            let ok = line == "d"
            if ok, working == nil { working = (method, delay) }
            let name = method.rawValue.padding(toLength: 36, withPad: " ", startingAt: 0)
            let pace = "\(Int(delay * 1000))ms".padding(toLength: 6, withPad: " ", startingAt: 0)
            let seen = shown(bytes).padding(toLength: 32, withPad: " ", startingAt: 0)
            let result = (line.map { "\"\($0)\"" } ?? "unknown").padding(toLength: 8, withPad: " ", startingAt: 0)
            print("\(name) \(pace) \(seen) \(result) \(ok ? "works" : "FAILS")")
        }
    }

    guard let working else {
        print("\nNo delete method worked in this pane.")
        return 1
    }

    print("\nFull dictation with \"\(working.method.rawValue)\" at \(Int(working.delay * 1000))ms:")
    let bytes = send {
        let typer = LiveTyper(keyboard: SystemKeyboard(delay: working.delay, delete: working.method))
        for text in scenario {
            typer.render(text)
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
    let line = TerminalLine.text(after: bytes)
    print("  expected: \(scenario.last!)")
    print("  got:      \(line ?? "unknown: \(shown(bytes))")")
    let passed = line == scenario.last
    print(passed ? "  MATCH" : "  MISMATCH")
    return passed ? 0 : 1
}
