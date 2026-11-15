import Foundation
import Testing
@testable import DictationCore

@Suite struct FeedbackTests {
    private let record: DictationRecord = {
        var record = DictationRecord(outcome: .typed)
        record.text = "The tool has proper logging."
        record.rawText = "Now help me understand if this tool has proper logging."
        record.profile = "General"
        record.app = "com.googlecode.iterm2"
        return record
    }()

    @Test func aCorrectionKeepsWhatWasSaidTypedAndMeant() {
        let feedback = Feedback(flagging: record, correction: "Now help me understand if this tool has proper logging?")
        #expect(feedback.dictationID == record.id)
        #expect(feedback.typedText == "The tool has proper logging.")
        #expect(feedback.rawText == "Now help me understand if this tool has proper logging.")
        #expect(feedback.correctedText == "Now help me understand if this tool has proper logging?")
        #expect(feedback.profile == "General")
        #expect(feedback.app == "com.googlecode.iterm2")
        #expect(feedback.source == .flagged)
    }

    @Test func leavingTheTextAsTypedOnlyFlagsIt() {
        #expect(Feedback(flagging: record, correction: "The tool has proper logging.").correctedText == nil)
        #expect(Feedback(flagging: record, correction: "  ").correctedText == nil)
    }

    @Test func itIsOneJSONLine() throws {
        let data = try JSONEncoder().encode(Feedback(flagging: record, correction: "x"))
        #expect(!data.contains(0x0A))
        #expect(try JSONDecoder().decode(Feedback.self, from: data).correctedText == "x")
    }
}
