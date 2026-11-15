import Testing
@testable import DictationCore

@Suite struct KeyTraceTests {
    @Test func namesEachModifierGoingDownAndUp() {
        var trace = KeyTrace()
        trace.add(keyCode: 61, flags: 0x80000 | 0x40, at: 10)
        trace.add(keyCode: 55, flags: 0x80000 | 0x40 | 0x100000 | 0x08, at: 10.42)
        trace.add(keyCode: 61, flags: 0x100000 | 0x08, at: 12)
        #expect(trace.entries == ["0 +Right Option", "420 +Left Command", "2000 -Right Option"])
    }

    @Test func aNewPressStartsANewTrace() {
        var trace = KeyTrace()
        trace.add(keyCode: 61, flags: 0x80000 | 0x40, at: 10)
        trace.add(keyCode: 61, flags: 0, at: 11)
        trace.add(keyCode: 54, flags: 0x100000 | 0x10, at: 20)
        #expect(trace.entries == ["0 +Right Command"])
    }

    @Test func otherKeysAreNotRecorded() {
        var trace = KeyTrace()
        trace.add(keyCode: 0, flags: 0, at: 1)
        #expect(trace.entries.isEmpty)
    }
}
