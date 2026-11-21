import AppKit
import Foundation

// `Whisper --store-key` saves the API key read from standard input (see `APIKey`) and exits.
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
// `Whisper --register-agent` registers the launch agent again for this build and exits. macOS ties the agent
// to the app's signature at registration, and a self-signed rebuild has a new one (Launch Constraint
// Violation), so install.sh runs this after every install.
if arguments.count >= 2, arguments[1] == "--register-agent" {
    if let problem = LoginItem.reregister() {
        FileHandle.standardError.write(Data("Could not register the launch agent: \(problem)\n".utf8))
        exit(1)
    }
    print("Launch agent registered for this build" + (LoginItem.needsApproval ? "; approve Whisper in System Settings → Login Items" : ""))
    exit(0)
}
if arguments.count >= 2, arguments[1] == "--store-key" {
    let key = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
        FileHandle.standardError.write(Data("No key on standard input.\n".utf8))
        exit(2)
    }
    do {
        try APIKey.file.write(key)
        print("Stored the key in \(APIKey.file.url.path) (\(key.count) characters, readable only by you).")
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
