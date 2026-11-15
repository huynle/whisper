import Foundation

/// Turns a raw transcript into the text the profile wants, with a text model.
public protocol Cleaner: Sendable {
    var model: String { get }
    func clean(_ text: String, instructions: String) async throws -> Transcription
}

/// Clean-up through the OpenAI-style `POST {base}/chat/completions`, which OmniRoute and OpenRouter accept.
public struct OpenAIChatCleaner: Cleaner {
    public let baseURL: URL
    public let model: String
    private let apiKey: @Sendable () -> String?
    private let transport: HTTPTransport
    /// The answer's length limit; nil sizes it to the text, for clean-up.
    public var maxTokens: Int?

    public init(baseURL: URL, model: String, apiKey: @escaping @Sendable () -> String?, transport: HTTPTransport, maxTokens: Int? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.transport = transport
        self.maxTokens = maxTokens
    }

    public func clean(_ text: String, instructions: String) async throws -> Transcription {
        guard let key = apiKey(), !key.isEmpty else { throw TranscriptionError.noAPIKey }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            // Room for the cleaned text, with a margin for symbols and lists, but no room to ramble.
            "max_tokens": maxTokens ?? max(64, text.count),
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": text],
            ],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result = try await transport.send(request)
        guard (200..<300).contains(result.response.statusCode) else {
            throw TranscriptionError.http(status: result.response.statusCode, message: OpenAITranscriber.errorMessage(result.data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: result.data),
              let content = answer.choices.first?.message.content
        else { throw TranscriptionError.unreadableAnswer }
        let cleaned = Self.unwrap(content)
        // An empty answer means the model refused or misunderstood; the raw transcript is better than nothing.
        guard !cleaned.isEmpty else { throw TranscriptionError.unreadableAnswer }
        return Transcription(text: cleaned, timing: result.timing)
    }

    private struct Answer: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    /// Removes a code fence or quotes the model put around the whole answer.
    static func unwrap(_ content: String) -> String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count >= 2, text.first == "\"", text.last == "\"", !text.dropFirst().dropLast().contains("\"") {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}
