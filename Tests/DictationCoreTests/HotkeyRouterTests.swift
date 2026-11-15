import Testing
@testable import DictationCore

@Suite struct HotkeyRouterTests {
    private func routed(_ router: inout HotkeyRouter, _ input: KeyInput) -> [String] {
        router.handle(input).matches.map { "\($0.index):\($0.match)" }
    }

    @Test func rightCommandGoesToTheFixHotkeyOnly() {
        var router = HotkeyRouter(bindings: [.rightOption, .rightCommand, nil])
        #expect(routed(&router, .flagsChanged(keyCode: 54, flags: 0x100000 | 0x10)) == ["1:bindingDown"])
        #expect(routed(&router, .flagsChanged(keyCode: 54, flags: 0)) == ["1:bindingUp"])
        #expect(routed(&router, .flagsChanged(keyCode: 61, flags: 0x80000 | 0x40)) == ["0:bindingDown"])
    }

    @Test func commandCIsAnotherKeyToBoth() {
        var router = HotkeyRouter(bindings: [.rightOption, .rightCommand, nil])
        _ = router.handle(.flagsChanged(keyCode: 54, flags: 0x100000 | 0x10))
        #expect(routed(&router, .keyDown(keyCode: 8, flags: 0x100000 | 0x10, isRepeat: false)) == ["0:otherKey", "1:otherKey"])
    }

    @Test func aCombinationHotkeyIsNotTypingToTheOthers() {
        let review = HotkeyBinding(keyCode: 15, modifiers: 0x40000 | 0x80000)
        var router = HotkeyRouter(bindings: [.rightOption, .rightCommand, review])
        let result = router.handle(.keyDown(keyCode: 15, flags: 0x40000 | 0x80000, isRepeat: false))
        #expect(result.matches.map { "\($0.index):\($0.match)" } == ["2:bindingDown"])
        #expect(result.swallow)
    }
}
