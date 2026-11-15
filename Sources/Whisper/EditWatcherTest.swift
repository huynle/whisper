import AppKit
import DictationCore

/// `Whisper --edit-watch-test`: opens a text window holding a "typed" dictation, edits it the way a user would,
/// and prints what the real EditWatcher reports. Exits 0 when the correction is found.
@MainActor
enum EditWatcherTest {
    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Whisper edit-watch test"
        let view = NSTextView(frame: window.contentView!.bounds)
        view.string = "Notes: cd to projects"
        window.contentView!.addSubview(view)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))

        var record = DictationRecord(outcome: .typed)
        record.text = "cd to projects"
        record.rawText = "cd to projects"
        var result: Feedback?
        let watcher = EditWatcher { result = $0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { watcher.watch(record) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            view.string = "Notes: cd ~/projects"
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            watcher.finish()
            print("trusted: \(AXIsProcessTrusted())")
            print("correction: \(result?.correctedText ?? "none")")
            exit(result?.correctedText == "cd ~/projects" ? 0 : 1)
        }
        app.run()
        exit(1)
    }
}
