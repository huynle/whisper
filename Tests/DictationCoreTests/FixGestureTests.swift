import Testing
@testable import DictationCore

@Suite struct FixGestureTests {
    @Test func holdingStartsRecordingOnceItIsClearlyAHold() {
        let g = FixGesture()
        #expect(g.keyDown(at: 0) == [])
        #expect(g.deadline == 0.3)
        #expect(g.tick(at: 0.1) == [])
        #expect(g.tick(at: 0.3) == [.start])
        #expect(g.deadline == nil)
        #expect(g.keyUp(at: 2) == [.finish])
    }

    @Test func aTapOpensTheCorrectionBox() {
        let g = FixGesture()
        _ = g.keyDown(at: 0)
        #expect(g.keyUp(at: 0.15) == [.openBox])
        #expect(g.deadline == nil)
    }

    @Test func aShortcutDoesNothing() {
        let g = FixGesture()
        _ = g.keyDown(at: 0)
        #expect(g.otherKey(at: 0.1) == [])
        #expect(g.tick(at: 0.5) == [])
        #expect(g.keyUp(at: 0.6) == [])
    }

    @Test func aShortcutAfterRecordingStartedCancelsIt() {
        let g = FixGesture()
        _ = g.keyDown(at: 0)
        _ = g.tick(at: 0.3)
        #expect(g.otherKey(at: 0.5) == [.cancel])
        #expect(g.keyUp(at: 0.6) == [])
    }

    @Test func theNextPressStartsAfresh() {
        let g = FixGesture()
        _ = g.keyDown(at: 0)
        _ = g.otherKey(at: 0.1)
        _ = g.keyUp(at: 0.2)
        _ = g.keyDown(at: 1)
        #expect(g.keyUp(at: 1.1) == [.openBox])
    }
}
