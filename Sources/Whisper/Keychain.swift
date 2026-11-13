import Foundation
import Security

/// API keys, kept as generic passwords under the app's own service name.
enum Keychain {
    static let service = "com.huynle.whisper"
    static let omniRoute = "omniroute"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)" }
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ value: String, account: String) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(match as CFDictionary)
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "Whisper: \(account) API key"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }
}
