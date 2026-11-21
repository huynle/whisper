import DictationCore
import Foundation
@preconcurrency import UserNotifications

/// Runs the review in the background when it is due (`AutoReview`), and posts a notification when it has
/// suggestions. Nothing is changed until the user opens the suggestions and saves some.
@MainActor
final class AutoReviewer {
    static let lastAttemptKey = "lastAutoReview"
    static let notificationID = "whisper.review"

    /// Suggestions waiting to be looked at.
    private(set) var pending: Reviewer.Outcome?
    private var running = false
    private var timer: Timer?
    private let settings: AppSettings
    private let store: ProfileStore

    init(settings: AppSettings, store: ProfileStore) {
        self.settings = settings
        self.store = store
    }

    /// Checks shortly after launch, then every hour.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.check() }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    /// The suggestions were opened; they are no longer pending.
    func taken() -> Reviewer.Outcome? {
        defer { pending = nil }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        return pending
    }

    func check() {
        guard settings.autoReview, !running, pending == nil else { return }
        let defaults = UserDefaults.standard
        let lastAttempt = defaults.object(forKey: Self.lastAttemptKey) as? Date
        let lastReview = defaults.object(forKey: Reviewer.lastReviewKey) as? Date
        let newFeedback = DictationLog(fileName: "feedback.jsonl").readAll(Feedback.self)
            .filter { lastAttempt.map($0.date.isAfter) ?? true }.count
        let evidence = Reviewer.evidence(since: lastReview).count
        guard AutoReview.isDue(newFeedback: newFeedback, evidence: evidence, lastAttempt: lastAttempt, now: Date()) else { return }

        running = true
        defaults.set(Date(), forKey: Self.lastAttemptKey)
        let base = settings.baseURL, model = settings.reviewModel
        let apiKey = settings.apiKey
        let profiles = store.profiles, dictionary = store.dictionary
        Task {
            defer { running = false }
            guard let outcome = try? await Reviewer.run(
                base: base, apiKey: await Task.detached { apiKey.value() }.value, model: model, since: lastReview, profiles: profiles, dictionary: dictionary)
            else { return }
            if outcome.proposals.isEmpty {
                // Nothing to change: the next review starts from here.
                defaults.set(Date(), forKey: Reviewer.lastReviewKey)
            } else {
                pending = outcome
                notify(outcome)
            }
        }
    }

    private func notify(_ outcome: Reviewer.Outcome) {
        let count = outcome.proposals.count
        let title = "Whisper has \(count) suggestion\(count == 1 ? "" : "s")"
        let body = (outcome.proposals.first?.change.summary ?? "") + (count > 1 ? " …" : "")
        let id = Self.notificationID
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}

private extension Date {
    func isAfter(_ other: Date) -> Bool { self > other }
}
