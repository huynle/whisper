import Testing
@testable import DictationCore

@Suite struct TerminalLineTests {
    @Test func appendsPrintableText() {
        #expect(TerminalLine.text(after: Array("cd ~/projects".utf8)) == "cd ~/projects")
    }

    @Test func delRemovesTheLastCharacter() {
        #expect(TerminalLine.text(after: Array("abc".utf8) + [0x7F, 0x7F] + Array("d".utf8)) == "ad")
    }

    @Test func bsRemovesTheLastCharacter() {
        #expect(TerminalLine.text(after: Array("abc".utf8) + [0x08]) == "ab")
    }

    @Test func removesAWholeAccentedCharacter() {
        #expect(TerminalLine.text(after: Array("café".utf8) + [0x7F]) == "caf")
    }

    @Test func deletingAnEmptyLineDoesNothing() {
        #expect(TerminalLine.text(after: [0x7F, 0x7F] + Array("a".utf8)) == "a")
    }

    @Test func isUnknownWhenOtherControlBytesArrive() {
        #expect(TerminalLine.text(after: [0x1B] + Array("[200~abc".utf8)) == nil)
    }
}
