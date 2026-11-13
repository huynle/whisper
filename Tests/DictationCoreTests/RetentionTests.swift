import Foundation
import Testing
@testable import DictationCore

@Suite struct RetentionTests {
    private let now = Date(timeIntervalSince1970: 1_000_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func recordingsOlderThanTheLimitExpire() {
        let files = [
            (name: "old.wav", modified: daysAgo(31)),
            (name: "new.wav", modified: daysAgo(2)),
            (name: "edge.wav", modified: daysAgo(30)),
        ]
        #expect(Retention.expired(files, now: now, days: 30) == ["old.wav"])
    }

    @Test func onlyRecordingsAreEverDeleted() {
        let files = [(name: "notes.txt", modified: daysAgo(400)), (name: "a.wav", modified: daysAgo(400))]
        #expect(Retention.expired(files, now: now, days: 30) == ["a.wav"])
    }
}
