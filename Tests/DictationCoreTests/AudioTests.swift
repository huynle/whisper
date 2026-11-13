import Foundation
import Testing
@testable import DictationCore

@Suite struct WAVTests {
    private func uint32(_ data: Data, _ at: Int) -> UInt32 {
        data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) }
    }

    private func uint16(_ data: Data, _ at: Int) -> UInt16 {
        UInt16(data[at]) | UInt16(data[at + 1]) << 8
    }

    @Test func writesA16BitMonoHeader() {
        let wav = WAV.encode([0, 0.5], sampleRate: 16_000)
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(uint32(wav, 4) == 36 + 4)
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(uint32(wav, 16) == 16)
        #expect(uint16(wav, 20) == 1)
        #expect(uint16(wav, 22) == 1)
        #expect(uint32(wav, 24) == 16_000)
        #expect(uint32(wav, 28) == 32_000)
        #expect(uint16(wav, 32) == 2)
        #expect(uint16(wav, 34) == 16)
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(uint32(wav, 40) == 4)
        #expect(wav.count == 44 + 4)
    }

    @Test func convertsSamplesToSixteenBits() {
        let wav = WAV.encode([0, 1, -1, 0.5], sampleRate: 16_000)
        #expect(Int16(bitPattern: uint16(wav, 44)) == 0)
        #expect(Int16(bitPattern: uint16(wav, 46)) == 32_767)
        #expect(Int16(bitPattern: uint16(wav, 48)) == -32_767)
        #expect(Int16(bitPattern: uint16(wav, 50)) == 16_384)
    }

    @Test func clipsSamplesOutsideTheRange() {
        let wav = WAV.encode([2, -3], sampleRate: 16_000)
        #expect(Int16(bitPattern: uint16(wav, 44)) == 32_767)
        #expect(Int16(bitPattern: uint16(wav, 46)) == -32_767)
    }
}

@Suite struct AudioCheckTests {
    private let rate = 16_000

    private func tone(seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 0.05) }
    }

    @Test func keepsSpeechLikeAudio() {
        #expect(AudioCheck.discardReason(tone(seconds: 1, amplitude: 0.2), sampleRate: rate) == nil)
    }

    @Test func dropsAudioThatIsTooShort() {
        #expect(AudioCheck.discardReason(tone(seconds: 0.2, amplitude: 0.2), sampleRate: rate) == "too short")
    }

    @Test func dropsSilence() {
        #expect(AudioCheck.discardReason(tone(seconds: 1, amplitude: 0.001), sampleRate: rate) == "silent")
    }

    @Test func dropsNothingAtAll() {
        #expect(AudioCheck.discardReason([], sampleRate: rate) == "too short")
    }
}
