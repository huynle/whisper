import Foundation

/// 16-bit mono PCM WAV, the plainest format every transcription endpoint accepts.
public enum WAV {
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        let dataSize = UInt32(samples.count * 2)
        append("RIFF")
        append32(36 + dataSize)
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        append("data")
        append32(dataSize)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            append16(UInt16(bitPattern: Int16((clipped * 32_767).rounded())))
        }
        return data
    }
}

/// Decides whether a recording is worth uploading, so presses with no speech cost no network call.
public enum AudioCheck {
    /// Shorter recordings are a tap, not speech.
    public static let minimumSeconds = 0.3
    /// A recording whose loudest sample stays below this (dBFS) has no speech in it.
    public static let silencePeakDB: Float = -50

    public static func discardReason(_ samples: [Float], sampleRate: Int) -> String? {
        if Double(samples.count) < minimumSeconds * Double(sampleRate) { return "too short" }
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        if 20 * log10(max(peak, 1e-9)) < silencePeakDB { return "silent" }
        return nil
    }
}
