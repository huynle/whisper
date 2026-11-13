import Testing
@testable import DictationCore

@Suite struct HotkeyGestureTests {
    /// A tap is a press shorter than 0.3 s; a second tap must start within 0.4 s of the first one ending.
    private func gesture() -> HotkeyGesture {
        HotkeyGesture(timings: .init(tapMax: 0.3, doubleTapWindow: 0.4))
    }

    @Test func pressStartsRecordingAtOnce() {
        #expect(gesture().keyDown(at: 10) == [.start])
    }

    @Test func releasingAfterAHoldFinishes() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        #expect(g.keyUp(at: 12) == [.finish])
    }

    @Test func aShortPressWaitsForASecondTap() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        #expect(g.keyUp(at: 10.1) == [])
        #expect(g.deadline == 10.5)
    }

    @Test func aSecondTapLocks() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        _ = g.keyUp(at: 10.1)
        #expect(g.keyDown(at: 10.3) == [.lock])
        #expect(g.keyUp(at: 10.35) == [])
        #expect(g.deadline == nil)
    }

    @Test func aSingleTapIsCancelledWhenTheWindowCloses() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        _ = g.keyUp(at: 10.1)
        #expect(g.tick(at: 10.4) == [])
        #expect(g.tick(at: 10.5) == [.cancel])
        #expect(g.deadline == nil)
    }

    @Test func pressingAgainWhileLockedFinishes() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        _ = g.keyUp(at: 10.1)
        _ = g.keyDown(at: 10.3)
        _ = g.keyUp(at: 10.35)
        #expect(g.keyDown(at: 20) == [.finish])
        #expect(g.keyUp(at: 20.1) == [])
    }

    @Test func anotherKeyWhileHoldingCancels() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        #expect(g.otherKey(at: 10.5) == [.cancel])
        #expect(g.keyUp(at: 11) == [])
    }

    @Test func anotherKeyWhileWaitingForTheSecondTapCancels() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        _ = g.keyUp(at: 10.1)
        #expect(g.otherKey(at: 10.2) == [.cancel])
        #expect(g.deadline == nil)
    }

    @Test func anotherKeyWhileLockedKeepsRecording() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        _ = g.keyUp(at: 10.1)
        _ = g.keyDown(at: 10.3)
        _ = g.keyUp(at: 10.35)
        #expect(g.otherKey(at: 11) == [])
        #expect(g.keyDown(at: 12) == [.finish])
    }

    @Test func repeatedPressesWhileHeldAreIgnored() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        #expect(g.keyDown(at: 10.5) == [])
        #expect(g.keyUp(at: 11) == [.finish])
    }

    @Test func aStrayReleaseDoesNothing() {
        #expect(gesture().keyUp(at: 10) == [])
    }

    @Test func aNewDictationCanStartRightAfterFinishing() {
        let g = gesture()
        _ = g.keyDown(at: 10)
        _ = g.keyUp(at: 11)
        #expect(g.keyDown(at: 11.05) == [.start])
    }
}
