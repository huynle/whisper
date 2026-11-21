import Foundation

/// An API key in a file only the user's own account can read (mode 600), like an SSH key: read instantly, with
/// no Keychain prompts after a rebuild. Any program running as the user can read it.
public struct KeyFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func read() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// Saves `key`; an empty key removes the file.
    public func write(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try remove() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Created with owner-only permissions before the key is written into it.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((trimmed + "\n").utf8))
    }

    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
