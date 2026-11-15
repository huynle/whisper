import DictationCore
import Foundation

/// One JSON line per entry in ~/Library/Application Support/Whisper, kept only on this Mac: dictations.jsonl
/// for each dictation (text and timings, never audio), feedback.jsonl for the user's corrections.
struct DictationLog {
    let url: URL

    init(fileName: String = "dictations.jsonl") {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(fileName)
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The last typed dictation in the log, so it can still be flagged after a restart.
    func lastTyped() -> DictationRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in data.split(separator: 0x0A).reversed() {
            if let record = try? decoder.decode(DictationRecord.self, from: Data(line)), record.outcome == .typed { return record }
        }
        return nil
    }

    func append<Entry: Encodable>(_ record: Entry) {
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }
}
