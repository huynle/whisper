import DictationCore
import Foundation

/// Developer-mode recordings: ~/Library/Application Support/Whisper/recordings, deleted after 30 days.
enum Recordings {
    static let keepDays: Double = 30

    static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisper/recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Saves one recording; returns its file name, or nil when it could not be written.
    static func save(_ wav: Data, id: String) -> String? {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime])
        let name = "\(stamp)-\(id.prefix(8)).wav"
        do {
            try wav.write(to: folder.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    /// Deletes recordings older than `keepDays`.
    static func purge() {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: folder.path) else { return }
        let files = names.compactMap { name -> (name: String, modified: Date)? in
            let attributes = try? manager.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
            return (attributes?[.modificationDate] as? Date).map { (name, $0) }
        }
        for name in Retention.expired(files, now: Date(), days: keepDays) {
            try? manager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
