import DictationCore
import Foundation

/// `Whisper --bench [--model <id>] [--runs <n>] <file.wav>...` sends recordings to the speech provider one after
/// another (one connection, as the app uses it) and prints where each request's time went.
/// Uses the app's stored API key and provider address, unless `--base <url>` and `--key-env <variable>` are given
/// (to compare providers, e.g. OpenRouter directly against OmniRoute).
enum Bench {
    static func run(_ arguments: [String]) -> Int32 {
        var model = UserDefaults.standard.string(forKey: "model") ?? "openrouter/openai/gpt-4o-mini-transcribe"
        var runs = 1
        var base = UserDefaults.standard.string(forKey: "baseURL") ?? "https://api.ai.huynle.com/v1"
        var key = Keychain.read(account: Keychain.omniRoute)
        var files: [String] = []
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--model": model = rest.popFirst() ?? model
            case "--runs": runs = rest.popFirst().flatMap { Int($0) } ?? runs
            case "--base": base = rest.popFirst() ?? base
            case "--key-env":
                guard let name = rest.popFirst(), let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
                    print("--key-env needs the name of a set environment variable")
                    return 2
                }
                key = value
            default: files.append(argument)
            }
        }
        guard !files.isEmpty else {
            print("usage: Whisper --bench [--model <id>] [--runs <n>] [--base <url> --key-env <variable>] <file.wav>...")
            return 2
        }
        let language = UserDefaults.standard.string(forKey: "language") ?? "en"
        let apiKey = key
        let transcriber = OpenAITranscriber(
            baseURL: URL(string: base)!, model: model, language: language.isEmpty ? nil : language,
            apiKey: { apiKey }, transport: URLSessionTransport())

        print("model \(model) at \(base), \(runs) run(s) per file")
        print("run  total   dns  conn   tls  upload  wait  down  reused proto  bytes   text")
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            for file in files {
                guard let wav = FileManager.default.contents(atPath: file) else {
                    print("cannot read \(file)")
                    status = 1
                    continue
                }
                print("# \((file as NSString).lastPathComponent)")
                for run in 1...max(1, runs) {
                    let started = Date()
                    do {
                        let result = try await transcriber.transcribe(wav: wav)
                        print(row(run, result.timing, wall: Date().timeIntervalSince(started), text: result.text))
                    } catch {
                        print("\(run)  failed: \(error)")
                        status = 1
                    }
                }
            }
            done.signal()
        }
        done.wait()
        return status
    }

    private static func row(_ run: Int, _ t: RequestTiming?, wall: Double, text: String) -> String {
        func f(_ v: Double?) -> String { v.map { String(format: "%5.0f", $0) } ?? "    -" }
        let total = t?.totalMs ?? wall * 1_000
        let reused = t?.reusedConnection.map { $0 ? "yes" : "no" } ?? "-"
        return String(format: "%3d", run) + " " + String(format: "%6.0f", total) + " " + f(t?.dnsMs) + " " + f(t?.connectMs)
            + " " + f(t?.tlsMs) + "  " + f(t?.uploadMs) + " " + f(t?.waitMs) + " " + f(t?.downloadMs) + "  "
            + reused.padding(toLength: 6, withPad: " ", startingAt: 0) + " " + (t?.protocolName ?? "-").padding(toLength: 6, withPad: " ", startingAt: 0)
            + String(format: "%6d", t?.requestBytes ?? 0) + "   " + text
    }
}
