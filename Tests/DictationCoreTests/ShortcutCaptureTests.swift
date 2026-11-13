import Testing
@testable import DictationCore

@Suite struct ShortcutCaptureTests {
    private let option: UInt64 = 0x80000
    private let control: UInt64 = 0x40000
    private let shift: UInt64 = 0x20000

    @Test func pressingAndReleasingAModifierAloneBindsIt() {
        var c = ShortcutCapture()
        #expect(c.handle(.flagsChanged(keyCode: 61, flags: option | 0x40)) == .listening)
        #expect(c.handle(.flagsChanged(keyCode: 61, flags: 0)) == .bound(.rightOption))
    }

    @Test func aKeyWithModifiersBindsTheCombination() {
        var c = ShortcutCapture()
        _ = c.handle(.flagsChanged(keyCode: 59, flags: control | 0x01))
        #expect(c.handle(.keyDown(keyCode: 49, flags: control | 0x01, isRepeat: false)) == .bound(HotkeyBinding(keyCode: 49, modifiers: control)))
    }

    @Test func aModifierUsedWithAKeyIsNotBoundAlone() {
        var c = ShortcutCapture()
        _ = c.handle(.flagsChanged(keyCode: 59, flags: control | 0x01))
        _ = c.handle(.keyDown(keyCode: 49, flags: control | 0x01, isRepeat: false))
        #expect(c.handle(.flagsChanged(keyCode: 59, flags: 0)) == .listening)
    }

    @Test func aFunctionKeyAloneIsAllowed() {
        var c = ShortcutCapture()
        #expect(c.handle(.keyDown(keyCode: 111, flags: 0, isRepeat: false)) == .bound(HotkeyBinding(keyCode: 111, modifiers: 0)))
    }

    @Test func aPlainKeyIsRejectedAndListeningContinues() {
        var c = ShortcutCapture()
        #expect(c.handle(.keyDown(keyCode: 0, flags: 0, isRepeat: false)) == .rejected(ShortcutCapture.plainKeyMessage))
        #expect(c.handle(.keyDown(keyCode: 0, flags: option, isRepeat: false)) == .bound(HotkeyBinding(keyCode: 0, modifiers: option)))
    }

    @Test func shiftAloneIsRejected() {
        var c = ShortcutCapture()
        _ = c.handle(.flagsChanged(keyCode: 56, flags: shift | 0x02))
        #expect(c.handle(.flagsChanged(keyCode: 56, flags: 0)) == .rejected(ShortcutCapture.shiftMessage))
    }

    @Test func escapeCancels() {
        var c = ShortcutCapture()
        #expect(c.handle(.keyDown(keyCode: 53, flags: 0, isRepeat: false)) == .cancelled)
    }
}
