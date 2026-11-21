import Combine
import DictationCore
import Foundation

/// Settings kept in UserDefaults; the API key in its own owner-only file (`APIKey`).
@MainActor
final class AppSettings: ObservableObject {
    nonisolated static let defaultBaseURL = "https://api.ai.huynle.com/v1"
    /// Fastest and steadiest in the 2026-11-21 measurement (Brain 8zw561m7): 0.3–0.8 s through OmniRoute.
    static let defaultModel = "openrouter/deepgram/nova-3"

    /// Speech models OmniRoute listed on 2026-11-12; any other model id can be typed in.
    static let knownModels = [
        "openrouter/deepgram/nova-3",
        "openrouter/mistralai/voxtral-mini-transcribe",
        "openrouter/openai/gpt-4o-mini-transcribe",
        "openrouter/openai/gpt-4o-transcribe",
        "openrouter/openai/whisper-large-v3-turbo",
        "openrouter/openai/whisper-large-v3",
        "openrouter/nvidia/parakeet-tdt-0.6b-v3",
    ]

    /// Choices for keeping the microphone ready, in seconds (infinity: always).
    static let warmChoices: [(label: String, seconds: Double)] = [
        ("Off", 0), ("10 seconds", 10), ("1 minute", 60), ("5 minutes", 300), ("Always", .infinity),
    ]

    /// Sound cue loudness (the loudest sample).
    static let cueChoices: [(label: String, volume: Float)] = [("Off", 0), ("Quiet", 0.15), ("Normal", 0.35)]

    private let defaults = UserDefaults.standard
    private let transport = URLSessionTransport()

    @Published var binding: HotkeyBinding { didSet { save(binding, "binding") } }
    /// Hold to say the last dictation again, tap to type the correction; nil when not set.
    @Published var fixBinding: HotkeyBinding? { didSet { saveOptional(fixBinding, "fixBinding") } }
    /// Hold to give an instruction that rewrites the last dictation, tap to type one; nil when not set.
    @Published var rewriteBinding: HotkeyBinding? { didSet { saveOptional(rewriteBinding, "rewriteBinding") } }
    /// Opens Review Dictations; nil (the default) when not set.
    @Published var reviewBinding: HotkeyBinding? { didSet { saveOptional(reviewBinding, "reviewBinding") } }
    /// Review the log in the background and post a notification when there are suggestions.
    @Published var autoReview: Bool { didSet { defaults.set(autoReview, forKey: "autoReview") } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: "baseURL") } }
    @Published var model: String { didSet { defaults.set(model, forKey: "model") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// Stored as -1 for "always", because UserDefaults cannot hold infinity.
    @Published var warmSeconds: Double { didSet { defaults.set(warmSeconds.isInfinite ? -1 : warmSeconds, forKey: "warmSeconds") } }
    @Published var cueVolume: Float { didSet { defaults.set(cueVolume, forKey: "cueVolume") } }
    /// A profile chosen by hand in the menu; nil picks it from the app in front.
    @Published var profileOverride: String? { didSet { defaults.set(profileOverride, forKey: "profileOverride") } }
    /// Keeps each recording (for 30 days) next to the detailed timings in the log.
    @Published var developerMode: Bool { didSet { defaults.set(developerMode, forKey: "developerMode") } }
    /// The model that rewrites the last dictation by an instruction; empty uses the profile's clean-up model.
    @Published var rewriteModel: String { didSet { defaults.set(rewriteModel, forKey: "rewriteModel") } }
    /// The model that reviews the log and suggests profile and dictionary changes.
    @Published var reviewModel: String { didSet { defaults.set(reviewModel, forKey: "reviewModel") } }
    /// Watch the field after typing and keep the user's own corrections for the review.
    @Published var learnFromEdits: Bool { didSet { defaults.set(learnFromEdits, forKey: "learnFromEdits") } }
    /// The Settings tab shown: "general", "profiles" or "dictionary".
    @Published var settingsTab = "general"
    /// True while Settings is recording a new shortcut, so the hotkey does not fire meanwhile.
    @Published var capturingShortcut = false
    let apiKey = APIKey()
    @Published private(set) var hasAPIKey = false

    init() {
        binding = (defaults.data(forKey: "binding")).flatMap { try? JSONDecoder().decode(HotkeyBinding.self, from: $0) } ?? .rightOption
        fixBinding = Self.optionalBinding(defaults, "fixBinding", default: .rightOptionRightShift)
        reviewBinding = Self.optionalBinding(defaults, "reviewBinding", default: nil)
        rewriteBinding = Self.optionalBinding(defaults, "rewriteBinding", default: .rightOptionRightCommand)
        autoReview = defaults.object(forKey: "autoReview") as? Bool ?? true
        baseURL = defaults.string(forKey: "baseURL") ?? Self.defaultBaseURL
        model = defaults.string(forKey: "model") ?? Self.defaultModel
        language = defaults.string(forKey: "language") ?? "en"
        let warm = defaults.object(forKey: "warmSeconds") as? Double ?? 60
        warmSeconds = warm < 0 ? .infinity : warm
        cueVolume = defaults.object(forKey: "cueVolume") as? Float ?? 0.15
        developerMode = defaults.bool(forKey: "developerMode")
        reviewModel = defaults.string(forKey: "reviewModel") ?? Reviewer.defaultModel
        rewriteModel = defaults.string(forKey: "rewriteModel") ?? ""
        learnFromEdits = defaults.object(forKey: "learnFromEdits") as? Bool ?? true
        profileOverride = defaults.string(forKey: "profileOverride")
        hasAPIKey = apiKey.value() != nil
    }

    func setAPIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try apiKey.save(trimmed)
        hasAPIKey = apiKey.value() != nil
    }

    /// The transcriber for the next dictation, from the settings as they are now.
    func makeTranscriber() -> Transcriber {
        let key = apiKey
        return OpenAITranscriber(
            baseURL: URL(string: baseURL) ?? URL(string: Self.defaultBaseURL)!,
            model: model,
            language: language.isEmpty ? nil : language,
            apiKey: { key.value() },
            transport: transport)
    }

    /// The clean-up engine for `model`, through the same provider and connection as transcription.
    func makeCleaner(model: String) -> Cleaner {
        let key = apiKey
        return OpenAIChatCleaner(baseURL: URL(string: baseURL) ?? URL(string: Self.defaultBaseURL)!, model: model, apiKey: { key.value() }, transport: transport)
    }

    private var lastWarmUp: Date?

    /// Opens (or keeps open) the connection to the provider while the user is still talking, so the
    /// transcription request does not pay for connecting. At most once every 15 s; the answer is ignored.
    func warmConnection() {
        if let lastWarmUp, Date().timeIntervalSince(lastWarmUp) < 15 { return }
        lastWarmUp = Date()
        guard let url = URL(string: baseURL)?.appendingPathComponent("models") else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        if let key = apiKey.value() { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let transport = transport
        Task.detached { _ = try? await transport.send(request) }
    }

    /// Stored as empty data once the user clears it, so the default does not come back.
    private static func optionalBinding(_ defaults: UserDefaults, _ key: String, default value: HotkeyBinding?) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: key) else { return value }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    private func saveOptional(_ value: HotkeyBinding?, _ key: String) {
        defaults.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private func save(_ value: HotkeyBinding, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
