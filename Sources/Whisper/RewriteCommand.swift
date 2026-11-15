import DictationCore
import Foundation

/// `Whisper --rewrite [--profile <name>] [--model <id>] <text> <instruction>` prints the rewrite the fix keys
/// would type, and how long it took.
enum RewriteCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var profileName = "General"
        var model: String?
        var words: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--profile": profileName = rest.popFirst() ?? profileName
            case "--model": model = rest.popFirst()
            default: words.append(argument)
            }
        }
        guard words.count == 2 else {
            print("usage: Whisper --rewrite [--profile <name>] [--model <id>] <text> <instruction>")
            return 2
        }
        let store = MainActor.assumeIsolated { ProfileStore() }
        let profiles = MainActor.assumeIsolated { store.profiles }
        let profile = profiles.profiles.first { $0.name == profileName } ?? .fallback
        let base = UserDefaults.standard.string(forKey: "baseURL") ?? AppSettings.defaultBaseURL
        let key = Keychain.read(account: Keychain.omniRoute)
        let client = OpenAIChatCleaner(
            baseURL: URL(string: base)!, model: model ?? profile.cleanupModel ?? Profile.defaultCleanupModel,
            apiKey: { key }, transport: URLSessionTransport())
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            let started = Date()
            do {
                let result = try await client.clean(
                    RewritePrompt.user(text: words[0], instruction: words[1]), instructions: RewritePrompt.system(for: profile))
                print(String(format: "%.0f ms  ", Date().timeIntervalSince(started) * 1000) + result.text)
            } catch {
                print("failed: \(error)")
                status = 1
            }
            done.signal()
        }
        done.wait()
        return status
    }
}
