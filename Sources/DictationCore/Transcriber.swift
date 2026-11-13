import Foundation

/// Where the time of one HTTP request went, in milliseconds, as macOS measured it.
public struct RequestTiming: Codable, Equatable, Sendable {
    public var totalMs: Double
    public var dnsMs: Double?
    public var connectMs: Double?
    public var tlsMs: Double?
    /// Sending the request and its audio.
    public var uploadMs: Double?
    /// From the request being sent to the first byte of the answer: the provider's own time.
    public var waitMs: Double?
    public var downloadMs: Double?
    /// True when an open connection was used, so there was no name lookup, connection or TLS handshake.
    public var reusedConnection: Bool?
    public var protocolName: String?
    public var requestBytes: Int?
    public var responseBytes: Int?

    public init(
        totalMs: Double, dnsMs: Double? = nil, connectMs: Double? = nil, tlsMs: Double? = nil, uploadMs: Double? = nil,
        waitMs: Double? = nil, downloadMs: Double? = nil, reusedConnection: Bool? = nil, protocolName: String? = nil,
        requestBytes: Int? = nil, responseBytes: Int? = nil
    ) {
        self.totalMs = totalMs
        self.dnsMs = dnsMs
        self.connectMs = connectMs
        self.tlsMs = tlsMs
        self.uploadMs = uploadMs
        self.waitMs = waitMs
        self.downloadMs = downloadMs
        self.reusedConnection = reusedConnection
        self.protocolName = protocolName
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
    }
}

public struct HTTPResult: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
    public let timing: RequestTiming?

    public init(data: Data, response: HTTPURLResponse, timing: RequestTiming?) {
        self.data = data
        self.response = response
        self.timing = timing
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

/// The real network, through one shared session so connections are reused between dictations.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResult {
        let collector = MetricsCollector()
        let (data, response) = try await session.data(for: request, delegate: collector)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.unreadableAnswer }
        // The metrics usually arrive before the answer; allow them a moment when they do not.
        for _ in 0..<20 where collector.metrics == nil { try? await Task.sleep(for: .milliseconds(5)) }
        return HTTPResult(data: data, response: http, timing: collector.metrics.map(Self.timing))
    }

    static func timing(_ metrics: URLSessionTaskMetrics) -> RequestTiming {
        func ms(_ from: Date?, _ to: Date?) -> Double? {
            guard let from, let to else { return nil }
            return (to.timeIntervalSince(from) * 1_000).rounded()
        }
        let t = metrics.transactionMetrics.last
        return RequestTiming(
            totalMs: (metrics.taskInterval.duration * 1_000).rounded(),
            dnsMs: ms(t?.domainLookupStartDate, t?.domainLookupEndDate),
            connectMs: ms(t?.connectStartDate, t?.connectEndDate),
            tlsMs: ms(t?.secureConnectionStartDate, t?.secureConnectionEndDate),
            uploadMs: ms(t?.requestStartDate, t?.requestEndDate),
            waitMs: ms(t?.requestEndDate, t?.responseStartDate),
            downloadMs: ms(t?.responseStartDate, t?.responseEndDate),
            reusedConnection: t?.isReusedConnection,
            protocolName: t?.networkProtocolName,
            requestBytes: t.map { Int($0.countOfRequestBodyBytesSent) },
            responseBytes: t.map { Int($0.countOfResponseBodyBytesReceived) })
    }
}

private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: URLSessionTaskMetrics?

    var metrics: URLSessionTaskMetrics? { lock.withLock { collected } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.withLock { collected = metrics }
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

public struct Transcription: Sendable {
    public var text: String
    public var timing: RequestTiming?

    public init(text: String, timing: RequestTiming?) {
        self.text = text
        self.timing = timing
    }
}

public protocol Transcriber: Sendable {
    /// The model's name, for the dictation record.
    var model: String { get }
    func transcribe(wav: Data) async throws -> Transcription
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

    public func transcribe(wav: Data) async throws -> Transcription {
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

        let result = try await transport.send(request)
        guard (200..<300).contains(result.response.statusCode) else {
            throw TranscriptionError.http(status: result.response.statusCode, message: Self.errorMessage(result.data))
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: result.data) else { throw TranscriptionError.unreadableAnswer }
        return Transcription(text: answer.speech(noSpeechMax: Self.noSpeechMax), timing: result.timing)
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
