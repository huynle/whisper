import DictationCore
import Foundation

/// profiles.json and dictionary.json in ~/Library/Application Support/Whisper, created with the defaults on first
/// use. They are read again whenever they change, so edits apply to the next dictation.
@MainActor
final class ProfileStore {
    static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    let profilesURL = folder.appendingPathComponent("profiles.json")
    let dictionaryURL = folder.appendingPathComponent("dictionary.json")

    private var profilesCache: (modified: Date, value: ProfileSet)?
    private var dictionaryCache: (modified: Date, value: UserDictionary)?
    /// Why a file could not be read, shown in the menu; the defaults are used meanwhile.
    private(set) var problem: String?

    init() {
        seed(profilesURL, ProfileSet.defaults)
        seed(dictionaryURL, UserDictionary.defaults)
    }

    var profiles: ProfileSet {
        load(profilesURL, cache: &profilesCache, fallback: .defaults)
    }

    var dictionary: UserDictionary {
        load(dictionaryURL, cache: &dictionaryCache, fallback: .defaults)
    }

    private func seed<T: Encodable>(_ url: URL, _ value: T) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(value).write(to: url)
    }

    private func load<T: Decodable>(_ url: URL, cache: inout (modified: Date, value: T)?, fallback: T) -> T {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        if let cache, cache.modified == modified { return cache.value }
        do {
            let value = try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            cache = (modified, value)
            problem = nil
            return value
        } catch {
            problem = "\(url.lastPathComponent) could not be read, so the defaults are used: \(error.localizedDescription)"
            return cache?.value ?? fallback
        }
    }
}
