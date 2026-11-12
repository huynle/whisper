// Build step 1: does typing a phrase and revising it in place work in a given app?
// Run it, focus the field to test during the countdown, and compare the result with the expected text.
import ApplicationServices
import DictationCore
import Foundation

/// One dictation as the pipeline would render it: a fast pass, a revision, more speech, a final revision.
let scenario = [
    "cd today/projects",
    "cd ~/projects",
    "cd ~/projects/whisper and run the tests",
    "cd ~/projects/whisper, then run the tests",
]

let usage = """
    usage: keyboard-prototype [--check] [--dry-run] [--echo-test] [--countdown <seconds>] [--pause-ms <ms>] [--delay-ms <ms>]
      --check       report whether Accessibility permission is granted, then exit
      --dry-run     print the key presses instead of sending them
      --echo-test   type into this terminal pane and report which key presses arrive
      --countdown   seconds to focus the target field before typing starts (default 5)
      --pause-ms    wait between revisions (default 1200)
      --delay-ms    wait after each key press (default 2)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var check = false
var dryRun = false
var echoTest = false
var countdown = 5
var pauseMs = 1200
var delayMs = 2

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    func number() -> Int {
        guard let value = arguments.popFirst().flatMap({ Int($0) }), value >= 0 else { fail("\(argument) needs a number\n\(usage)") }
        return value
    }
    switch argument {
    case "--check": check = true
    case "--dry-run": dryRun = true
    case "--echo-test": echoTest = true
    case "--countdown": countdown = number()
    case "--pause-ms": pauseMs = number()
    case "--delay-ms": delayMs = number()
    case "--help", "-h":
        print(usage)
        exit(0)
    default: fail("unknown option \(argument)\n\(usage)")
    }
}

let trusted = AXIsProcessTrusted()
if check {
    print(trusted ? "Accessibility permission: granted" : "Accessibility permission: not granted")
    exit(trusted ? 0 : 1)
}

if dryRun {
    let keyboard = PrintingKeyboard()
    let typer = LiveTyper(keyboard: keyboard)
    for (index, text) in scenario.enumerated() {
        print("step \(index + 1): \"\(text)\"")
        typer.render(text)
        print("  field: \"\(keyboard.field)\"")
    }
    exit(keyboard.field == scenario.last ? 0 : 1)
}

guard trusted else {
    fail("""
        Accessibility permission is not granted, so key presses would be ignored.
        Grant it to the app this was launched from (your terminal) in
        System Settings > Privacy & Security > Accessibility, then run this again.
        """)
}

if echoTest {
    exit(runEchoTest(scenario: scenario))
}

for remaining in stride(from: countdown, to: 0, by: -1) {
    FileHandle.standardError.write(Data("Focus the field to test: typing starts in \(remaining)...\n".utf8))
    Thread.sleep(forTimeInterval: 1)
}

let typer = LiveTyper(keyboard: SystemKeyboard(delay: Double(delayMs) / 1000))
for text in scenario {
    typer.render(text)
    Thread.sleep(forTimeInterval: Double(pauseMs) / 1000)
}
print("Done. The field should read: \(scenario.last!)")
