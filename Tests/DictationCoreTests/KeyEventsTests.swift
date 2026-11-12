import CoreGraphics
import Testing
@testable import DictationCore

@Suite struct KeyEventsTests {
    /// Real key presses carry this mark; iTerm2 in the kitty keyboard mode drops a Delete without it.
    private let realKeyMark = CGEventFlags.maskNonCoalesced

    @Test func deleteIsTheDeleteKeyGoingDownThenUp() throws {
        let events = try #require(KeyEvents.delete())
        #expect(events.map { $0.type } == [.keyDown, .keyUp])
        #expect(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 51 })
    }

    @Test func deleteCarriesTheRealKeyMark() throws {
        let events = try #require(KeyEvents.delete())
        #expect(events.allSatisfy { $0.flags == realKeyMark })
    }

    /// With the mark, iTerm2's kitty keyboard mode reports a release of the A key (the key text is sent on) after
    /// every character; without it, text arrives as plain characters there, in plain iTerm2 and in Herdr.
    @Test func textCarriesNoFlags() throws {
        let events = try #require(KeyEvents.text("~"))
        #expect(events.allSatisfy { $0.flags.isEmpty })
    }

    @Test func textCarriesItsCharacter() throws {
        let events = try #require(KeyEvents.text("~"))
        for event in events {
            var length = 0
            var units = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &length, unicodeString: &units)
            #expect(Array(units.prefix(length)) == Array("~".utf16))
        }
    }
}
