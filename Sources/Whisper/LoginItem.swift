import AppKit
import Foundation
import ServiceManagement

/// Opening Whisper at login, and again if it ever crashes: a launch agent inside the app
/// (Contents/Library/LaunchAgents/com.huynle.whisper.agent.plist), registered with macOS's own login items
/// (System Settings → General → Login Items). Quit exits normally and stays quit.
enum LoginItem {
    static let label = "com.huynle.whisper.agent"
    private static var agent: SMAppService { SMAppService.agent(plistName: label + ".plist") }

    static var isEnabled: Bool { agent.status == .enabled }

    /// Needs the user's approval in System Settings before it takes effect.
    static var needsApproval: Bool { agent.status == .requiresApproval }

    /// Turns it on or off; returns why it failed, if it did.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled { try agent.register() } else { try agent.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Unregisters and registers the agent again, so it trusts this build's signature.
    static func reregister() -> String? {
        // launchd keeps the job, and the old build's launch constraint with it, until it is booted out while
        // still registered; then it is registered fresh for this build.
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        bootout.standardError = FileHandle.nullDevice
        bootout.standardOutput = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()
        Thread.sleep(forTimeInterval: 1)
        try? agent.unregister()
        Thread.sleep(forTimeInterval: 0.5)
        return set(true)
    }

    /// True when the app runs from an Applications folder rather than a build folder.
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().path
        return path == "/Applications" || path == NSHomeDirectory() + "/Applications"
    }

    /// The first time an installed copy starts, it turns itself on once; after that the user's choice stands.
    /// Copies that opened at login the earlier way (as a plain login item) move to the agent.
    static func enableOnFirstInstalledLaunch() {
        guard isInstalled else { return }
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            set(true)
        }
        let key = "loginItemOffered"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !isEnabled { set(true) }
    }

    /// Another Whisper is already running (one opened by hand while the agent started one): this one leaves,
    /// quietly and successfully, so the agent does not start it again.
    static func exitIfAlreadyRunning() {
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.huynle.whisper")
            .filter { $0.processIdentifier != mine && !$0.isTerminated }
        if !others.isEmpty { exit(0) }
    }
}
