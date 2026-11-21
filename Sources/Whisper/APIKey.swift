import Foundation

/// The API key, read from the Keychain once on a background thread. The Keychain can stall or show a password
/// prompt (a rebuilt app is a new program to it), so it is never read on the main thread: the menu bar and
/// hotkeys come up at once, and a request made before the key is loaded waits for it.
final class APIKey: @unchecked Sendable {
    private let condition = NSCondition()
    private var loaded = false
    private var key: String?

    /// Starts reading; `done` runs on the main thread with the key, or nil when there is none.
    func load(account: String, done: @escaping @MainActor (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Keychain.read(account: account)
            self.set(value)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(value) } }
        }
    }

    func set(_ value: String?) {
        condition.lock()
        key = value
        loaded = true
        condition.broadcast()
        condition.unlock()
    }

    var isLoaded: Bool {
        condition.lock()
        defer { condition.unlock() }
        return loaded
    }

    /// The key, waiting up to `timeout` seconds for the Keychain (never call on the main thread).
    func value(timeout: TimeInterval = 60) -> String? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !loaded, condition.wait(until: deadline) {}
        return key
    }
}
