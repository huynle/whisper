import DictationCore
import Foundation

/// Asks a model to suggest profile and dictionary changes from the dictation log and the user's feedback.
enum Reviewer {
    static let defaultModel = "claude/claude-sonnet-5-5"
    /// When the last review's suggestions were applied; the next review looks at what came after.
    static let lastReviewKey = "lastReview"

    struct Outcome {
        var evidence: [ReviewEvidence.Item]
        var proposals: [ReviewProposal]
        var seconds: Double
    }

    enum Failure: Error, CustomStringConvertible {
        case nothingToReview
        case noAPIKey
        var description: String {
            switch self {
            case .nothingToReview: "Nothing new to review: no dictation was cleaned, rejected or flagged since the last review."
            case .noAPIKey: "No API key is stored."
            }
        }
    }

    static func evidence(since: Date?) -> [ReviewEvidence.Item] {
        let records = DictationLog().readAll(DictationRecord.self)
        let feedback = DictationLog(fileName: "feedback.jsonl").readAll(Feedback.self)
        return ReviewEvidence.items(records: records, feedback: feedback, since: since)
    }

    static func run(base: String, apiKey: String?, model: String, since: Date?, profiles: ProfileSet, dictionary: UserDictionary) async throws -> Outcome {
        let items = evidence(since: since)
        guard !items.isEmpty else { throw Failure.nothingToReview }
        guard let apiKey, !apiKey.isEmpty else { throw Failure.noAPIKey }
        let client = OpenAIChatCleaner(
            baseURL: URL(string: base) ?? URL(string: AppSettings.defaultBaseURL)!, model: model, apiKey: { apiKey },
            transport: URLSessionTransport(), maxTokens: 4000)
        let started = Date()
        let answer = try await client.clean(
            ReviewPrompt.user(profiles: profiles, dictionary: dictionary, evidence: items), instructions: ReviewPrompt.system)
        let proposals = ReviewProposal.parse(answer.text, profiles: profiles, dictionary: dictionary)
        return Outcome(evidence: items, proposals: proposals, seconds: Date().timeIntervalSince(started))
    }

    /// `Whisper --review [--model <id>] [--all]` prints what a review would suggest, without changing anything.
    static func command(_ arguments: [String]) -> Int32 {
        var model = UserDefaults.standard.string(forKey: "reviewModel") ?? defaultModel
        var since = UserDefaults.standard.object(forKey: lastReviewKey) as? Date
        var rest = arguments[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--model": model = rest.popFirst() ?? model
            case "--all": since = nil
            default:
                print("usage: Whisper --review [--model <id>] [--all]")
                return 2
            }
        }
        let base = UserDefaults.standard.string(forKey: "baseURL") ?? AppSettings.defaultBaseURL
        let key = Keychain.read(account: Keychain.omniRoute)
        let store = MainActor.assumeIsolated { ProfileStore() }
        let profiles = MainActor.assumeIsolated { store.profiles }
        let dictionary = MainActor.assumeIsolated { store.dictionary }

        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            do {
                let outcome = try await run(base: base, apiKey: key, model: model, since: since, profiles: profiles, dictionary: dictionary)
                print("reviewed \(outcome.evidence.count) dictations with \(model) in \(String(format: "%.1f", outcome.seconds)) s")
                if outcome.proposals.isEmpty { print("no suggestions") }
                for (i, proposal) in outcome.proposals.enumerated() {
                    print("\(i + 1). \(proposal.change.summary)")
                    print("   why: \(proposal.reason)  [\(proposal.evidence.count) dictation(s)]")
                }
            } catch {
                print("review failed: \(error)")
                status = 1
            }
            done.signal()
        }
        done.wait()
        return status
    }
}
