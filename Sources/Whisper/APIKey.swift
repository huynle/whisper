import DictationCore
import Foundation

/// The provider's API key, in ~/Library/Application Support/Whisper/api-key (owner-only, see `KeyFile`).
final class APIKey: @unchecked Sendable {
    static let file = KeyFile(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Whisper", isDirectory: true).appendingPathComponent("api-key"))

    private let lock = NSLock()
    private var key: String? = APIKey.file.read()

    /// The key as saved now.
    func value() -> String? { lock.withLock { key } }

    /// Saves the key (an empty one removes it).
    func save(_ value: String) throws {
        try Self.file.write(value)
        let stored = Self.file.read()
        lock.withLock { key = stored }
    }
}
