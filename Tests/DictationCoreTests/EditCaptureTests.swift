import Foundation
import Testing
@testable import DictationCore

@Suite struct EditCaptureTests {
    private func correction(_ before: String, _ after: String, typed: String) -> String? {
        let end = (before as NSString).length
        return EditCapture.correction(before: before, after: after, typed: typed, typedEnd: end)
    }

    @Test func aWordFixedInsideTheDictationIsACorrection() {
        #expect(correction("Notes: cd to projects", "Notes: cd ~/projects", typed: "cd to projects") == "cd ~/projects")
    }

    @Test func aFixInTheMiddleOfTheFieldIsACorrection() {
        let before = "Hi Sam, that is a good pattern and see you"
        let after = "Hi Sam, is that a good pattern? and see you"
        let typedEnd = ("Hi Sam, that is a good pattern" as NSString).length
        #expect(EditCapture.correction(before: before, after: after, typed: "that is a good pattern", typedEnd: typedEnd) == "is that a good pattern?")
    }

    @Test func nothingChangedIsNoCorrection() {
        #expect(correction("Hello there", "Hello there", typed: "Hello there") == nil)
    }

    @Test func typingOnAfterTheDictationIsNotACorrection() {
        #expect(correction("Hello there", "Hello there, how are you", typed: "Hello there") == nil)
    }

    @Test func editsElsewhereInTheFieldAreNotACorrection() {
        #expect(correction("Dear Sam, Hello there", "Dear Samantha, Hello there", typed: "Hello there") == nil)
    }

    @Test func deletingTheWholeDictationIsNotACorrection() {
        #expect(correction("Notes: Hello there", "Notes: ", typed: "Hello there") == nil)
    }

    @Test func replacingItWithSomethingUnrelatedIsNotACorrection() {
        #expect(correction("Hello there friend", "Completely different words", typed: "Hello there friend") == nil)
    }

    @Test func theFieldMustHoldWhatWasTyped() {
        #expect(EditCapture.startsWatching(fieldValue: "abc Hello", typed: "Hello", cursor: 9))
        #expect(!EditCapture.startsWatching(fieldValue: "abc Hello", typed: "Hello", cursor: 3))
        #expect(!EditCapture.startsWatching(fieldValue: "", typed: "Hello", cursor: 0))
    }

    @Test func worksWithEmojiAndAccents() {
        #expect(correction("👋 café is grate", "👋 café is great", typed: "café is grate") == "café is great")
    }
}
