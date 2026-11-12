import Testing
@testable import DictationCore

@Suite struct RevisionTests {
    @Test func typesEverythingWhenNothingWasTyped() {
        #expect(Revision.edit(from: "", to: "cd ~/projects") == Edit(backspaces: 0, text: "cd ~/projects"))
    }

    @Test func appendsWhenTheTypedTextIsUnchanged() {
        #expect(Revision.edit(from: "cd ~/projects", to: "cd ~/projects/whisper") == Edit(backspaces: 0, text: "/whisper"))
    }

    @Test func replacesFromTheFirstDifference() {
        #expect(Revision.edit(from: "cd today/projects", to: "cd ~/projects") == Edit(backspaces: 14, text: "~/projects"))
    }

    @Test func sendsNothingWhenTheTextIsTheSame() {
        #expect(Revision.edit(from: "cd ~/projects", to: "cd ~/projects") == Edit(backspaces: 0, text: ""))
    }

    @Test func onlyDeletesWhenTheNewTextIsShorter() {
        #expect(Revision.edit(from: "run the tests um", to: "run the tests") == Edit(backspaces: 3, text: ""))
    }

    @Test func countsOneBackspacePerVisibleCharacter() {
        #expect(Revision.edit(from: "café 👍🏽 ok", to: "café 👍🏽 done") == Edit(backspaces: 2, text: "done"))
    }
}
