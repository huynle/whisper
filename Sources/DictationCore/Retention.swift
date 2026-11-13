import Foundation

/// Developer-mode recordings are deleted after a set number of days.
public enum Retention {
    /// The names of recordings (.wav) last modified more than `days` days before `now`.
    public static func expired(_ files: [(name: String, modified: Date)], now: Date, days: Double) -> [String] {
        let cutoff = now.addingTimeInterval(-days * 86_400)
        return files.filter { $0.name.hasSuffix(".wav") && $0.modified < cutoff }.map(\.name)
    }
}
