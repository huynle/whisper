/// Several hotkeys at once (dictate, fix, review): passes each key event to every binding's matcher and says
/// which hotkeys it concerns, by position, and whether to keep it from the focused app.
public struct HotkeyRouter {
    private var matchers: [BindingMatcher?]

    public init(bindings: [HotkeyBinding?]) {
        matchers = bindings.map { $0.map(BindingMatcher.init) }
    }

    public mutating func handle(_ input: KeyInput) -> (matches: [(index: Int, match: KeyMatch)], swallow: Bool) {
        var matches: [(index: Int, match: KeyMatch)] = []
        var swallow = false
        for index in matchers.indices {
            guard var matcher = matchers[index] else { continue }
            matches.append((index, matcher.handle(input)))
            swallow = swallow || matcher.swallows(input)
            matchers[index] = matcher
        }
        // A key that is one hotkey is not "another key" to the others (a fix combination must not count as typing).
        if matches.contains(where: { $0.match == .bindingDown || $0.match == .bindingUp }) {
            matches = matches.filter { $0.match != .otherKey }
        }
        return (matches.filter { $0.match != .ignore }, swallow)
    }
}
