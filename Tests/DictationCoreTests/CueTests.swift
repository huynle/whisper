import Testing
@testable import DictationCore

@Suite struct CueTests {
    @Test func everyGestureActionHasItsCue() {
        #expect(Cue.for(.start) == .microphoneOn)
        #expect(Cue.for(.lock) == .locked)
        #expect(Cue.for(.finish) == .microphoneOff)
        #expect(Cue.for(.cancel) == .cancelled)
    }

    @Test func aFailureHasItsCueAndOtherStatusesHaveNone() {
        #expect(Cue.for(.failed("offline")) == .failed)
        #expect(Cue.for(.idle) == nil)
        #expect(Cue.for(.transcribing) == nil)
        #expect(Cue.for(.recording(locked: false)) == nil)
    }

    @Test func cuesAreShort() {
        for cue in Cue.allCases {
            let samples = cue.render(sampleRate: 44_100, volume: 1)
            #expect(samples.count <= 44_100 * 2 / 10, "\(cue) is longer than 0.2 s")
            #expect(!samples.isEmpty)
        }
    }

    @Test func volumeSetsTheLoudestSample() {
        let samples = Cue.microphoneOn.render(sampleRate: 44_100, volume: 0.15)
        let peak = samples.map(abs).max() ?? 0
        #expect(peak <= 0.15)
        #expect(peak > 0.14)
    }

    @Test func cuesStartAndEndSilentSoTheyDoNotPop() {
        for cue in Cue.allCases {
            let samples = cue.render(sampleRate: 44_100, volume: 1)
            #expect(abs(samples.first ?? 1) < 0.01)
            #expect(abs(samples.last ?? 1) < 0.01)
        }
    }

    @Test func lockedSoundsDifferentFromMicrophoneOn() {
        let on = Cue.microphoneOn.render(sampleRate: 44_100, volume: 1)
        let locked = Cue.locked.render(sampleRate: 44_100, volume: 1)
        #expect(on != locked)
        #expect(locked.count > on.count)
    }
}
