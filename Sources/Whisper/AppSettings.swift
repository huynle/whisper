import Combine
import DictationCore
import Foundation

/// Settings kept in UserDefaults; the API key in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    static let defaultBaseURL = "https://api.ai.huynle.com/v1"
    static let defaultModel = "openrouter/openai/gpt-4o-mini-transcribe"

    /// Speech models OmniRoute listed on 2026-11-12; any other model id can be typed in.
    static let knownModels = [
        "openrouter/openai/gpt-4o-mini-transcribe",
        "openrouter/openai/gpt-4o-transcribe",
        "openrouter/openai/whisper-large-v3-turbo",
        "openrouter/openai/whisper-large-v3",
        "openrouter/deepgram/nova-3",
        "openrouter/mistralai/voxtral-mini-transcribe",
        "openrouter/nvidia/parakeet-tdt-0.6b-v3",
    ]

    /// Choices for keeping the microphone ready, in seconds (infinity: always).
    static let warmChoices: [(label: String, seconds: Double)] = [
        ("Off", 0), ("10 seconds", 10), ("1 minute", 60), ("5 minutes", 300), ("Always", .infinity),
    ]

    private let defaults = UserDefaults.standard
    private let transport = URLSessionTransport()

    @Published var binding: HotkeyBinding { didSet { save(binding, "binding") } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// Stored as -1 for "always", because UserDefaults cannot hold infinity.
    @Published var warmSeconds: Double { didSet { defaults.set(warmSeconds.isInfinite ? -1 : warmSeconds, forKey: "warmSeconds") } }
    /// True while Settings is recording a new shortcut, so the hotkey does not fire meanwhile.
    @Published var capturingShortcut = false
    @Published private(set) var hasAPIKey: Bool

    private var apiKey: String?

    init() {
        binding = (defaults.data(forKey: "binding")).flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) } ?? .rightOption
        baseURL = defaults.string(forKey: "baseURL") ?? Self.defaultBaseURL
        model = defaults.string(forKey: "model") ?? Self.defaultModel
        language = defaults.string(forKey: "language") ?? "en"
        let warm = defaults.object(forKey: "warmSeconds") as? Double ?? 60
        warmSeconds = warm < 0 ? .infinity : warm
        apiKey = Keychain.read(account: Keychain.omniRoute)
        hasAPIKey = apiKey != nil
    }

    func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.write(trimmed, account: Keychain.omniRoute)
        apiKey = trimmed
        hasAPIKey = true
    }

    /// The transcriber for the next dictation, from the settings as they are now.
    func makeTranscriber() -> Transcriber {
        let key = apiKey
        return OpenAITranscriber(
            baseURL: URL(string: baseURL) ?? URL(string: Self.defaultBaseURL)!,
            model: model,
            language: language.isEmpty ? nil : language,
            apiKey: { key },
            transport: transport)
    }

    private func save(_ value: HotkeyBinding, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
