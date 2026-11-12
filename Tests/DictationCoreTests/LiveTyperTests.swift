import Testing
@testable import DictationCore

/// A stand-in text field: typing appends, backspace removes the last visible character.
final class FakeField: Keyboard {
    var text = ""
    var calls = 0

    func type(_ text: String) {
        calls += 1
        self.text += text
    }

    func backspace(_ count: Int) {
        calls += 1
        text.removeLast(count)
    }
}

@Suite struct LiveTyperTests {
    @Test func typesTheFirstPhrase() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("cd today/projects")

        #expect(field.text == "cd today/projects")
    }

    @Test func revisesWhatItTypedInPlace() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("cd today/projects")
        typer.render("cd ~/projects/whisper")

        #expect(field.text == "cd ~/projects/whisper")
    }

    @Test func sendsNoKeysWhenNothingChanged() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("cd ~/projects")
        let calls = field.calls
        typer.render("cd ~/projects")

        #expect(field.calls == calls)
    }

    @Test func neverTypesEnterOrTab() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("rm -rf build\nls\tsrc\r\n")

        #expect(field.text == "rm -rf build ls src ")
    }

    @Test func dropsOtherControlCharacters() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("stop\u{03}here\u{1B}[A")

        #expect(field.text == "stophere[A")
    }

    @Test func stopsTypingOnceTheUserInterferes() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("cd today/projects")
        typer.userInterfered()
        let result = typer.render("cd ~/projects")

        #expect(field.text == "cd today/projects")
        #expect(result == .blocked(corrected: "cd ~/projects"))
    }

    @Test func reportsTheEditItMade() {
        let field = FakeField()
        let typer = LiveTyper(keyboard: field)

        typer.render("cd today/projects")
        let result = typer.render("cd ~/projects")

        #expect(result == .typed(Edit(backspaces: 14, text: "~/projects")))
    }
}
