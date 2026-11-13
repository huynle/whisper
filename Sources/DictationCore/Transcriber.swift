import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The real network, through one shared session so connections are reused between dictations.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.unreadableAnswer }
        return (data, http)
    }
}

public enum TranscriptionError: Error, Equatable, CustomStringConvertible {
    case noAPIKey
    case http(status: Int, message: String)
    case unreadableAnswer

    public var description: String {
        switch self {
        case .noAPIKey: "No API key: add one in Settings"
        case .http(let status, let message): "The provider answered \(status): \(message)"
        case .unreadableAnswer: "The provider's answer could not be read"
        }
    }
}

public protocol Transcriber: Sendable {
    func transcribe(wav: Data) async throws -> String
}

/// Speech to text through the OpenAI-style `POST {base}/audio/transcriptions`, which OmniRoute, OpenRouter and
/// OpenAI all accept (the same request Hub's speech providers send).
public struct OpenAITranscriber: Transcriber {
    /// Whisper segments rated more likely than this to hold no speech are dropped (Whisper's own threshold, as Hub).
    static let noSpeechMax = 0.6

    public let baseURL: URL
    public let model: String
    public let language: String?
    private let apiKey: @Sendable () -> String?
    private let transport: HTTPTransport

    public init(baseURL: URL, model: String, language: String?, apiKey: @escaping @Sendable () -> String?, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.model = model
        self.language = language
        self.apiKey = apiKey
        self.transport = transport
    }

    /// Only Whisper models report how likely each segment is to be noise.
    private var wantsSegments: Bool { model.lowercased().contains("whisper") }

    public func transcribe(wav: Data) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw TranscriptionError.noAPIKey }

        let boundary = "whisper-\(UUID().uuidString)"
        var form = MultipartForm(boundary: boundary)
        form.addFile(name: "file", filename: "audio.wav", type: "audio/wav", data: wav)
        form.addField(name: "model", value: model)
        if let language { form.addField(name: "language", value: language) }
        if wantsSegments { form.addField(name: "response_format", value: "verbose_json") }

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finish()

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw TranscriptionError.http(status: response.statusCode, message: Self.errorMessage(data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else { throw TranscriptionError.unreadableAnswer }
        return answer.speech(noSpeechMax: Self.noSpeechMax)
    }

    private struct Answer: Decodable {
        struct Segment: Decodable {
            let text: String?
            let no_speech_prob: Double?
        }

        let text: String?
        let segments: [Segment]?

        func speech(noSpeechMax: Double) -> String {
            if let segments, segments.contains(where: { $0.no_speech_prob != nil }) {
                return segments
                    .filter { ($0.no_speech_prob ?? 0) <= noSpeechMax }
                    .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            return (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The JSON `error.message` (or `error` / `message`) when present, else the body, capped.
    static func errorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return String(message.prefix(300)) }
            if let error = object["error"] as? String { return String(error.prefix(300)) }
            if let message = object["message"] as? String { return String(message.prefix(300)) }
        }
        return String(String(decoding: data, as: UTF8.self).prefix(300))
    }
}

struct MultipartForm {
    let boundary: String
    private var body = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, type: String, data: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(type)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    mutating func finish() -> Data {
        append("--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ text: String) {
        body.append(contentsOf: Array(text.utf8))
    }
}
