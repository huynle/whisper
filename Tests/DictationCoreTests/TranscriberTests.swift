import Foundation
import Testing
@testable import DictationCore

/// Answers every request with a fixed status and body, and keeps the request it was given.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    let status: Int
    let body: String
    private(set) var request: URLRequest?

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@Suite struct TranscriberTests {
    private let base = URL(string: "https://api.ai.huynle.com/v1")!

    private func transcriber(_ transport: FakeTransport, key: String? = "secret", model: String = "openrouter/openai/gpt-4o-mini-transcribe") -> OpenAITranscriber {
        OpenAITranscriber(baseURL: base, model: model, language: "en", apiKey: { key }, transport: transport)
    }

    @Test func postsToTheTranscriptionEndpointWithTheKey() async throws {
        let transport = FakeTransport(body: #"{"text":"hello"}"#)
        _ = try await transcriber(transport).transcribe(wav: Data("RIFF".utf8))
        let request = try #require(transport.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.ai.huynle.com/v1/audio/transcriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
    }

    @Test func sendsTheAudioModelAndLanguageAsFormFields() async throws {
        let transport = FakeTransport(body: #"{"text":"hello"}"#)
        _ = try await transcriber(transport).transcribe(wav: Data("RIFFaudio".utf8))
        let body = String(decoding: try #require(transport.request?.httpBody), as: UTF8.self)
        #expect(body.contains(#"Content-Disposition: form-data; name="file"; filename="audio.wav""#))
        #expect(body.contains("Content-Type: audio/wav\r\n\r\nRIFFaudio\r\n"))
        #expect(body.contains("name=\"model\"\r\n\r\nopenrouter/openai/gpt-4o-mini-transcribe\r\n"))
        #expect(body.contains("name=\"language\"\r\n\r\nen\r\n"))
    }

    @Test func returnsTheTextTrimmed() async throws {
        let transport = FakeTransport(body: #"{"text":"  cd ~/projects/whisper, then run the tests.\n"}"#)
        #expect(try await transcriber(transport).transcribe(wav: Data()) == "cd ~/projects/whisper, then run the tests.")
    }

    @Test func asksWhisperModelsForSegmentsAndDropsTheNonSpeechOnes() async throws {
        let transport = FakeTransport(body: #"""
            {"text":"run the tests Thank you.","segments":[
              {"text":" run the tests","no_speech_prob":0.1},
              {"text":" Thank you.","no_speech_prob":0.9}]}
            """#)
        let text = try await transcriber(transport, model: "openrouter/openai/whisper-large-v3-turbo").transcribe(wav: Data())
        #expect(text == "run the tests")
        let body = String(decoding: try #require(transport.request?.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
    }

    @Test func doesNotAskOtherModelsForSegments() async throws {
        let transport = FakeTransport(body: #"{"text":"hello"}"#)
        _ = try await transcriber(transport).transcribe(wav: Data())
        let body = String(decoding: try #require(transport.request?.httpBody), as: UTF8.self)
        #expect(!body.contains("response_format"))
    }

    @Test func failsWithoutAKeyAndSendsNothing() async {
        let transport = FakeTransport(body: "")
        await #expect(throws: TranscriptionError.noAPIKey) {
            try await transcriber(transport, key: nil).transcribe(wav: Data())
        }
        #expect(transport.request == nil)
    }

    @Test func reportsTheProvidersErrorMessage() async {
        let transport = FakeTransport(status: 401, body: #"{"error":{"message":"invalid key"}}"#)
        await #expect(throws: TranscriptionError.http(status: 401, message: "invalid key")) {
            try await transcriber(transport).transcribe(wav: Data())
        }
    }

    @Test func reportsAnUnreadableAnswer() async {
        let transport = FakeTransport(body: "<html>gateway</html>")
        await #expect(throws: TranscriptionError.unreadableAnswer) {
            try await transcriber(transport).transcribe(wav: Data())
        }
    }
}
