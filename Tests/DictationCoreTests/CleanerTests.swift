import Foundation
import Testing
@testable import DictationCore

@Suite struct CleanerTests {
    private let base = URL(string: "https://api.ai.huynle.com/v1")!

    private func cleaner(_ transport: FakeTransport, key: String? = "secret") -> OpenAIChatCleaner {
        OpenAIChatCleaner(baseURL: base, model: "openrouter/meta-llama/llama-3.3-70b-instruct", apiKey: { key }, transport: transport)
    }

    private func answer(_ content: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(content), encoding: .utf8)!
        return #"{"choices":[{"message":{"role":"assistant","content":"# + escaped + "}}]}"
    }

    @Test func postsTheInstructionsAndTheTranscriptToChatCompletions() async throws {
        let transport = FakeTransport(body: answer("cd ~/projects"))
        _ = try await cleaner(transport).clean("cd today slash projects", instructions: "Format it.")
        let request = try #require(transport.request)
        #expect(request.url?.absoluteString == "https://api.ai.huynle.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "openrouter/meta-llama/llama-3.3-70b-instruct")
        #expect(body["temperature"] as? Double == 0)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Format it."], ["role": "user", "content": "cd today slash projects"]])
    }

    @Test func returnsTheCleanedTextAndTiming() async throws {
        let timing = RequestTiming(totalMs: 600)
        let transport = FakeTransport(body: answer("  cd ~/projects\n"), timing: timing)
        let result = try await cleaner(transport).clean("x", instructions: "y")
        #expect(result.text == "cd ~/projects")
        #expect(result.timing == timing)
    }

    @Test func removesQuotesOrACodeFenceWrappedAroundTheWholeAnswer() async throws {
        #expect(try await cleaner(FakeTransport(body: answer("\"cd ~/projects\""))).clean("x", instructions: "y").text == "cd ~/projects")
        #expect(try await cleaner(FakeTransport(body: answer("```\ncd ~/projects\n```"))).clean("x", instructions: "y").text == "cd ~/projects")
        #expect(try await cleaner(FakeTransport(body: answer("say \"hi\" to her"))).clean("x", instructions: "y").text == "say \"hi\" to her")
    }

    @Test func anEmptyAnswerIsAFailure() async {
        await #expect(throws: TranscriptionError.unreadableAnswer) {
            try await cleaner(FakeTransport(body: answer("   "))).clean("x", instructions: "y")
        }
        await #expect(throws: TranscriptionError.unreadableAnswer) {
            try await cleaner(FakeTransport(body: #"{"choices":[{"message":{"content":null}}]}"#)).clean("x", instructions: "y")
        }
    }

    @Test func reportsTheProvidersError() async {
        let transport = FakeTransport(status: 429, body: #"{"error":{"message":"rate limited"}}"#)
        await #expect(throws: TranscriptionError.http(status: 429, message: "rate limited")) {
            try await cleaner(transport).clean("x", instructions: "y")
        }
    }

    @Test func failsWithoutAKey() async {
        let transport = FakeTransport(body: "")
        await #expect(throws: TranscriptionError.noAPIKey) {
            try await cleaner(transport, key: nil).clean("x", instructions: "y")
        }
        #expect(transport.request == nil)
    }
}
