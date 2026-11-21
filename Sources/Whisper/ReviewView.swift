import DictationCore
import SwiftUI

/// Runs a review and lets the user pick which suggested changes to keep.
@MainActor
final class ReviewModel: ObservableObject {
    enum State {
        case running
        case failed(String)
        case ready(Reviewer.Outcome)
        case applied(Int)
    }

    @Published var state = State.running
    @Published var chosen: Set<UUID> = []

    private let settings: AppSettings
    private let store: ProfileStore

    init(settings: AppSettings, store: ProfileStore) {
        self.settings = settings
        self.store = store
    }

    /// Shows suggestions a background review already made.
    func show(_ outcome: Reviewer.Outcome) {
        chosen = []
        state = .ready(outcome)
    }

    func start(all: Bool = false) {
        state = .running
        let since = all ? nil : UserDefaults.standard.object(forKey: Reviewer.lastReviewKey) as? Date
        let base = settings.baseURL, model = settings.reviewModel
        let apiKey = settings.apiKey
        let profiles = store.profiles, dictionary = store.dictionary
        Task {
            do {
                let outcome = try await Reviewer.run(base: base, apiKey: await Task.detached { apiKey.value() }.value, model: model, since: since, profiles: profiles, dictionary: dictionary)
                chosen = []
                state = .ready(outcome)
            } catch {
                state = .failed((error as? Reviewer.Failure)?.description
                    ?? (error as? TranscriptionError)?.description
                    ?? "The review failed: \(error.localizedDescription)")
            }
        }
    }

    /// Saves the chosen changes, and marks everything reviewed so far as done.
    func apply(_ proposals: [ReviewProposal]) {
        var set = store.profileSet
        var dictionary = store.userDictionary
        let picked = proposals.filter { chosen.contains($0.id) }
        for proposal in picked { proposal.change.apply(to: &set, dictionary: &dictionary) }
        if set != store.profileSet { store.profileSet = set }
        if dictionary != store.userDictionary { store.userDictionary = dictionary }
        UserDefaults.standard.set(Date(), forKey: Reviewer.lastReviewKey)
        state = .applied(picked.count)
    }
}

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.state {
            case .running:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading your recent dictations…")
                }
                Spacer()
            case .failed(let message):
                Text(message)
                Spacer()
                HStack {
                    Button("Review Everything Again") { model.start(all: true) }
                    Spacer()
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            case .ready(let outcome):
                Text("Looked at \(outcome.evidence.count) dictations. Tick the changes to keep; nothing changes until you save.")
                    .foregroundStyle(.secondary)
                if outcome.proposals.isEmpty {
                    Text("No changes suggested.")
                    Spacer()
                } else {
                    List(outcome.proposals) { proposal in
                        Toggle(isOn: Binding(
                            get: { model.chosen.contains(proposal.id) },
                            set: { if $0 { model.chosen.insert(proposal.id) } else { model.chosen.remove(proposal.id) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(proposal.change.summary).textSelection(.enabled)
                                Text(proposal.reason + " (\(proposal.evidence.count) dictation\(proposal.evidence.count == 1 ? "" : "s"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
                HStack {
                    Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save \(model.chosen.count) Change\(model.chosen.count == 1 ? "" : "s")") { model.apply(outcome.proposals) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(outcome.proposals.isEmpty == false && model.chosen.isEmpty)
                }
            case .applied(let count):
                Text(count == 0
                     ? "Nothing changed. The next review starts from here."
                     : "Saved \(count) change\(count == 1 ? "" : "s"). They apply from your next dictation, and can be edited in Settings.")
                Spacer()
                HStack {
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .frame(width: 620, height: 460)
    }
}
