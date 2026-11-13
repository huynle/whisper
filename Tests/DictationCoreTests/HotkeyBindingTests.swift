import Foundation
import Testing
@testable import DictationCore

@Suite struct HotkeyBindingTests {
    // macOS flag bits: device-independent Option and Control, and the per-side Option bits.
    private let option: UInt64 = 0x80000
    private let control: UInt64 = 0x40000
    private let rightOptionBit: UInt64 = 0x40
    private let leftOptionBit: UInt64 = 0x20

    // MARK: a modifier key alone (Right Option)

    @Test func rightOptionGoingDownIsTheBindingDown() {
        var m = BindingMatcher(binding: .rightOption)
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: option | rightOptionBit)) == .bindingDown)
    }

    @Test func rightOptionComingUpIsTheBindingUp() {
        var m = BindingMatcher(binding: .rightOption)
        _ = m.handle(.flagsChanged(keyCode: 61, flags: option | rightOptionBit))
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: 0)) == .bindingUp)
    }

    @Test func rightOptionReleasedWhileLeftOptionIsHeldIsStillUp() {
        var m = BindingMatcher(binding: .rightOption)
        _ = m.handle(.flagsChanged(keyCode: 61, flags: option | rightOptionBit | leftOptionBit))
        #expect(m.handle(.flagsChanged(keyCode: 61, flags: option | leftOptionBit)) == .bindingUp)
    }

    @Test func leftOptionIsNotTheBinding() {
        var m = BindingMatcher(binding: .rightOption)
        #expect(m.handle(.flagsChanged(keyCode: 58, flags: option | leftOptionBit)) == .ignore)
    }

    @Test func aKeyPressedWhileHoldingIsAnotherKey() {
        var m = BindingMatcher(binding: .rightOption)
        _ = m.handle(.flagsChanged(keyCode: 61, flags: option | rightOptionBit))
        #expect(m.handle(.keyDown(keyCode: 0, flags: option | rightOptionBit, isRepeat: false)) == .otherKey)
    }

    @Test func aKeyPressedWhenNotHoldingIsAlsoReported() {
        var m = BindingMatcher(binding: .rightOption)
        #expect(m.handle(.keyDown(keyCode: 0, flags: 0, isRepeat: false)) == .otherKey)
    }

    @Test func modifierOnlyBindingsAreNeverSwallowed() {
        var m = BindingMatcher(binding: .rightOption)
        let event = KeyInput.flagsChanged(keyCode: 61, flags: option | rightOptionBit)
        _ = m.handle(event)
        #expect(m.swallows(event) == false)
    }

    // MARK: a key combination (Control-Space)

    private let controlSpace = HotkeyBinding(keyCode: 49, modifiers: 0x40000)

    @Test func theComboGoingDownIsTheBindingDown() {
        var m = BindingMatcher(binding: controlSpace)
        #expect(m.handle(.keyDown(keyCode: 49, flags: control, isRepeat: false)) == .bindingDown)
    }

    @Test func theKeyWithoutItsModifiersIsAnotherKey() {
        var m = BindingMatcher(binding: controlSpace)
        #expect(m.handle(.keyDown(keyCode: 49, flags: 0, isRepeat: false)) == .otherKey)
    }

    @Test func theKeyWithExtraModifiersIsAnotherKey() {
        var m = BindingMatcher(binding: controlSpace)
        #expect(m.handle(.keyDown(keyCode: 49, flags: control | option, isRepeat: false)) == .otherKey)
    }

    @Test func autoRepeatWhileHoldingTheComboIsIgnored() {
        var m = BindingMatcher(binding: controlSpace)
        _ = m.handle(.keyDown(keyCode: 49, flags: control, isRepeat: false))
        #expect(m.handle(.keyDown(keyCode: 49, flags: control, isRepeat: true)) == .ignore)
    }

    @Test func releasingTheKeyIsTheBindingUpEvenAfterTheModifierWentUp() {
        var m = BindingMatcher(binding: controlSpace)
        _ = m.handle(.keyDown(keyCode: 49, flags: control, isRepeat: false))
        _ = m.handle(.flagsChanged(keyCode: 59, flags: 0))
        #expect(m.handle(.keyUp(keyCode: 49, flags: 0)) == .bindingUp)
    }

    @Test func theComboIsSwallowedSoTheFocusedAppNeverSeesIt() {
        var m = BindingMatcher(binding: controlSpace)
        let down = KeyInput.keyDown(keyCode: 49, flags: control, isRepeat: false)
        _ = m.handle(down)
        #expect(m.swallows(down))
        let up = KeyInput.keyUp(keyCode: 49, flags: control)
        _ = m.handle(up)
        #expect(m.swallows(up))
    }

    @Test func otherKeysAreNeverSwallowed() {
        var m = BindingMatcher(binding: controlSpace)
        let other = KeyInput.keyDown(keyCode: 0, flags: 0, isRepeat: false)
        _ = m.handle(other)
        #expect(m.swallows(other) == false)
    }

    // MARK: names and storage

    @Test func modifierOnlyBindingsHaveReadableNames() {
        #expect(HotkeyBinding.rightOption.displayName == "Right Option")
        #expect(HotkeyBinding(keyCode: 63, modifiers: 0).displayName == "Fn")
    }

    @Test func combosShowTheirModifiersAndKey() {
        #expect(controlSpace.displayName == "⌃Space")
        #expect(HotkeyBinding(keyCode: 2, modifiers: 0x80000 | 0x100000).displayName == "⌥⌘D")
    }

    @Test func aBindingSurvivesBeingStoredAsJSON() throws {
        let data = try JSONEncoder().encode(controlSpace)
        #expect(try JSONDecoder().decode(HotkeyBinding.self, from: data) == controlSpace)
    }
}
