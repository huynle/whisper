import Foundation
import ServiceManagement

/// Opening Whisper at login, through macOS's own login items (System Settings → General → Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Needs the user's approval in System Settings before it takes effect.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turns it on or off; returns why it failed, if it did.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True when the app runs from an Applications folder rather than a build folder.
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    /// The first time an installed copy starts, it turns itself on once; after that the user's choice stands.
    static func enableOnFirstInstalledLaunch() {
        let key = "loginItemOffered"
        guard isInstalled, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { set(true) }
    }
}
