import Testing
@testable import DictationCore

private let option: UInt64 = 0x80000
private let shift: UInt64 = 0x20000
private let rightOptionBit: UInt64 = 0x40
private let rightShiftBit: UInt64 = 0x04
private let both = option | shift | rightOptionBit | rightShiftBit

@Suite struct ChordBindingTests {
    @Test func itIsNamedByBothKeys() {
        #expect(HotkeyBinding.rightOptionRightShift.displayName == "Right Option + Right Shift")
        #expect(HotkeyBinding.rightOptionRightShift.isModifierOnly)
    }

    @Test func itIsDownWhileBothKeysAre() {
        var m = BindingMatcher(binding: .rightOptionRightShift)
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: option | rightOptionBit)) == .ignore)
        #expect(m.handle(.flagsChanged(keyCode: 60, flags: both)) == .bindingDown)
        #expect(m.handle(.flagsChanged(keyCode: 60, flags: option | rightOptionBit)) == .bindingUp)
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: 0)) == .ignore)
    }

    @Test func eitherKeyMayGoFirst() {
        var m = BindingMatcher(binding: .rightOptionRightShift)
        #expect(m.handle(.flagsChanged(keyCode: 60, flags: shift | rightShiftBit)) == .ignore)
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: both)) == .bindingDown)
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: shift | rightShiftBit)) == .bindingUp)
    }

    @Test func leftShiftDoesNotCount() {
        var m = BindingMatcher(binding: .rightOptionRightShift)
        #expect(m.handle(.flagsChanged(keyCode: 56, flags: option | shift | rightOptionBit | 0x02)) == .ignore)
    }

    @Test func oldSettingsStillLoad() throws {
        let data = #"{"keyCode":54,"modifiers":0}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == .rightCommand)
    }

    @Test func settingsRecordsTwoModifiersPressedTogether() {
        var c = ShortcutCapture()
        #expect(c.handle(.flagsChanged(keyCode: 61, flags: option | rightOptionBit)) == .listening)
        #expect(c.handle(.flagsChanged(keyCode: 60, flags: both)) == .listening)
        #expect(c.handle(.flagsChanged(keyCode: 60, flags: option | rightOptionBit)) == .listening)
        #expect(c.handle(.flagsChanged(keyCode: 61, flags: 0)) == .bound(.rightOptionRightShift))
    }
}

import Foundation

@Suite struct HotkeyPadTests {
    /// Right Option dictates; Right Option + Right Shift fixes.
    private func pad() -> HotkeyPad { HotkeyPad(fixSharesDictationKey: true) }

    @Test func rightOptionAloneDictatesAsBefore() {
        let p = pad()
        #expect(p.handle(0, .bindingDown, at: 0) == [.dictation(.start)])
        #expect(p.handle(0, .bindingUp, at: 2) == [.dictation(.finish)])
    }

    @Test func addingRightShiftTurnsTheRecordingIntoAFix() {
        let p = pad()
        #expect(p.handle(0, .bindingDown, at: 0) == [.dictation(.start)])
        #expect(p.handle(1, .bindingDown, at: 0.05) == [.fixFromDictation])
        // Releasing Right Option ends both; the fix finishes, the dictation does not.
        #expect(p.handle(0, .bindingUp, at: 2) == [])
        #expect(p.handle(1, .bindingUp, at: 2) == [.fixFinish])
    }

    @Test func releasingRightShiftFirstFinishesTheFixAndRightOptionsReleaseDoesNothing() {
        let p = pad()
        _ = p.handle(0, .bindingDown, at: 0)
        _ = p.handle(1, .bindingDown, at: 0.05)
        #expect(p.handle(1, .bindingUp, at: 2) == [.fixFinish])
        #expect(p.handle(0, .bindingUp, at: 2.1) == [])
        #expect(p.handle(0, .bindingDown, at: 5) == [.dictation(.start)])
    }

    @Test func pressingBothAtOnceWorksInEitherOrder() {
        let p = pad()
        #expect(p.handle(0, .bindingDown, at: 0) + p.handle(1, .bindingDown, at: 0) == [.dictation(.start), .fixFromDictation])
    }

    @Test func tappingBothOpensTheBox() {
        let p = pad()
        _ = p.handle(0, .bindingDown, at: 0)
        _ = p.handle(1, .bindingDown, at: 0.02)
        #expect(p.handle(0, .bindingUp, at: 0.15) + p.handle(1, .bindingUp, at: 0.15) == [.fixDiscard, .openBox])
        #expect(p.deadline == nil)
    }

    @Test func aShortcutWithBothCancels() {
        let p = pad()
        _ = p.handle(0, .bindingDown, at: 0)
        _ = p.handle(1, .bindingDown, at: 0.02)
        #expect(p.handle(0, .otherKey, at: 0.1) == [.dictation(.cancel)])
        #expect(p.handle(1, .bindingUp, at: 0.2) == [])
        #expect(p.handle(0, .bindingUp, at: 0.25) == [])
    }

    @Test func rightShiftDuringALockedDictationIsIgnored() {
        let p = pad()
        _ = p.handle(0, .bindingDown, at: 0)
        _ = p.handle(0, .bindingUp, at: 0.1)
        #expect(p.handle(0, .bindingDown, at: 0.2) == [.dictation(.lock)])
        _ = p.handle(0, .bindingUp, at: 0.3)
        #expect(p.handle(1, .bindingDown, at: 1) == [])
        #expect(p.handle(1, .bindingUp, at: 1.2) == [])
    }

    @Test func aSeparateFixKeyUsesHoldAndTap() {
        let p = HotkeyPad(fixSharesDictationKey: false)
        #expect(p.handle(1, .bindingDown, at: 0) == [])
        #expect(p.tick(at: 0.3) == [.fixStart])
        #expect(p.handle(1, .bindingUp, at: 1) == [.fixFinish])
        _ = p.handle(1, .bindingDown, at: 2)
        #expect(p.handle(1, .bindingUp, at: 2.1) == [.openBox])
    }
}
