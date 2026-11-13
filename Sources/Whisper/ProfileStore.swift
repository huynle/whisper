import Combine
import DictationCore
import Foundation

/// profiles.json and dictionary.json in ~/Library/Application Support/Whisper, created with the defaults on first
/// use. Settings edits them here and every change is saved at once; edits made to the files by hand are picked up
/// before the next dictation.
@MainActor
final class ProfileStore: ObservableObject {
    static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Whisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    let profilesURL = folder.appendingPathComponent("profiles.json")
    let dictionaryURL = folder.appendingPathComponent("dictionary.json")

    @Published var profileSet: ProfileSet {
        didSet { if !reloading { profilesModified = write(profileSet, to: profilesURL) } }
    }

    @Published var userDictionary: UserDictionary {
        didSet { if !reloading { dictionaryModified = write(userDictionary, to: dictionaryURL) } }
    }

    /// Why a file could not be read or written, shown in the menu; the last good values are used meanwhile.
    @Published private(set) var problem: String?

    private var profilesModified: Date?
    private var dictionaryModified: Date?
    private var reloading = false

    init() {
        profileSet = .defaults
        userDictionary = .defaults
        if !FileManager.default.fileExists(atPath: profilesURL.path) { profilesModified = write(ProfileSet.defaults, to: profilesURL) }
        if !FileManager.default.fileExists(atPath: dictionaryURL.path) { dictionaryModified = write(UserDictionary.defaults, to: dictionaryURL) }
        refresh()
    }

    /// The profiles, re-read first if the file was changed by hand.
    var profiles: ProfileSet {
        refresh()
        return profileSet
    }

    var dictionary: UserDictionary {
        refresh()
        return userDictionary
    }

    /// Loads either file again when it changed on disk since it was last read or written here.
    func refresh() {
        reloading = true
        defer { reloading = false }
        if let (value, modified) = readIfChanged(ProfileSet.self, from: profilesURL, since: profilesModified) {
            profileSet = value
            profilesModified = modified
        }
        if let (value, modified) = readIfChanged(UserDictionary.self, from: dictionaryURL, since: dictionaryModified) {
            userDictionary = value
            dictionaryModified = modified
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    private func readIfChanged<T: Decodable>(_ type: T.Type, from url: URL, since: Date?) -> (T, Date)? {
        guard let modified = modificationDate(url), modified != since else { return nil }
        do {
            let value = try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
            problem = nil
            return (value, modified)
        } catch {
            problem = "\(url.lastPathComponent) could not be read, so the last good version is used: \(error.localizedDescription)"
            return nil
        }
    }

    /// Writes `value` as readable JSON; returns the file's new modification date.
    private func write<T: Encodable>(_ value: T, to url: URL) -> Date? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
            return modificationDate(url)
        } catch {
            problem = "\(url.lastPathComponent) could not be saved: \(error.localizedDescription)"
            return nil
        }
    }
}
