import AppKit
import Foundation

// `Whisper --store-key <account>` saves the key read from standard input in the Keychain and exits.
// The app stores it itself, so the Keychain lets it read the key later without asking.
let arguments = CommandLine.arguments
if arguments.count >= 2, arguments[1] == "--bench" {
    exit(Bench.run(Array(arguments.dropFirst(2))))
}
if arguments.count >= 2, arguments[1] == "--edit-watch-test" {
    MainActor.assumeIsolated { EditWatcherTest.run() }
}
if arguments.count >= 2, arguments[1] == "--rewrite" {
    exit(RewriteCommand.run(Array(arguments.dropFirst(2))))
}
if arguments.count >= 2, arguments[1] == "--review" {
    exit(Reviewer.command(Array(arguments.dropFirst(2))))
}
if arguments.count >= 2, arguments[1] == "--store-key" {
    let account = arguments.count >= 3 ? arguments[2] : Keychain.omniRoute
    let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
        FileHandle.standardError.write(Data("No key on standard input.\n".utf8))
        exit(2)
    }
    do {
        try Keychain.write(key, account: account)
        print("Stored the key for \"\(account)\" in the Keychain (\(key.count) characters).")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Could not store the key: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
