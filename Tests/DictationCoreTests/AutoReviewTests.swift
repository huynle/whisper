import Foundation
import Testing
@testable import DictationCore

@Suite struct AutoReviewTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    private func ago(hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    @Test func fiveNewCorrectionsMakeAReviewDue() {
        #expect(AutoReview.isDue(newFeedback: 5, evidence: 5, lastAttempt: ago(hours: 2), now: now))
        #expect(!AutoReview.isDue(newFeedback: 4, evidence: 4, lastAttempt: ago(hours: 2), now: now))
    }

    @Test func otherwiseOnceADayWhenThereIsSomethingToLookAt() {
        #expect(AutoReview.isDue(newFeedback: 0, evidence: 3, lastAttempt: ago(hours: 25), now: now))
        #expect(AutoReview.isDue(newFeedback: 0, evidence: 3, lastAttempt: nil, now: now))
        #expect(!AutoReview.isDue(newFeedback: 0, evidence: 2, lastAttempt: ago(hours: 25), now: now))
        #expect(!AutoReview.isDue(newFeedback: 0, evidence: 30, lastAttempt: ago(hours: 5), now: now))
    }

    @Test func neverTwiceWithinAnHour() {
        #expect(!AutoReview.isDue(newFeedback: 50, evidence: 50, lastAttempt: ago(hours: 0.5), now: now))
    }
}
