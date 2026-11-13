import AppKit
import AVFoundation
import DictationCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var captureMessage: String?
    @State private var monitor: Any?
    @State private var capture = ShortcutCapture()
    @State private var permissions = Permissions.current()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Hotkey") {
                HStack {
                    Text("Dictate with")
                    Spacer()
                    Text(settings.capturingShortcut ? "Press the new shortcut…" : settings.binding.displayName)
                        .foregroundStyle(settings.capturingShortcut ? .secondary : .primary)
                    Button(settings.capturingShortcut ? "Cancel" : "Change…") {
                        settings.capturingShortcut ? stopCapture() : startCapture()
                    }
                }
                if let captureMessage {
                    Text(captureMessage).font(.caption).foregroundStyle(.orange)
                }
                Text("Hold to talk; release to finish. Double-tap to keep listening; tap again to finish.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Speech model") {
                TextField("Provider address", text: $settings.baseURL)
                Picker("Model", selection: $settings.model) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                TextField("Model id", text: $settings.model)
                TextField("Language (empty: detect)", text: $settings.language)
                HStack {
                    SecureField(settings.hasAPIKey ? "API key stored; type to replace" : "API key", text: $keyDraft)
                    Button("Save key") { saveKey() }.disabled(keyDraft.isEmpty)
                }
                if let keyMessage {
                    Text(keyMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Microphone") {
                Picker("Keep the microphone ready", selection: $settings.warmSeconds) {
                    ForEach(AppSettings.warmChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                Text("While ready, the next press records at once, and the macOS microphone indicator stays on.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                permissionRow("Accessibility (hotkey and typing)", permissions.accessibility,
                              "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                permissionRow("Input Monitoring", permissions.inputMonitoring,
                              "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
                permissionRow("Microphone", permissions.microphone,
                              "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            }
        }
        .formStyle(.grouped)
        // A grouped Form scrolls, so it reports no height of its own; without a fixed size the window collapses.
        .frame(width: 520, height: 640)
        .onReceive(refresh) { _ in permissions = Permissions.current() }
        .onDisappear { stopCapture() }
    }

    private var modelChoices: [String] {
        AppSettings.knownModels.contains(settings.model) ? AppSettings.knownModels : [settings.model] + AppSettings.knownModels
    }

    private func permissionRow(_ title: String, _ granted: Bool, _ pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
            Text(title)
            Spacer()
            if !granted {
                Button("Open Settings") { NSWorkspace.shared.open(URL(string: pane)!) }
            }
        }
    }

    private func saveKey() {
        do {
            try settings.setAPIKey(keyDraft)
            keyDraft = ""
            keyMessage = "Key stored in the Keychain."
        } catch {
            keyMessage = "Could not store the key: \(error)"
        }
    }

    private func startCapture() {
        capture = ShortcutCapture()
        captureMessage = nil
        settings.capturingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = UInt64(event.modifierFlags.rawValue)
            let input: KeyInput = event.type == .flagsChanged
                ? .flagsChanged(keyCode: event.keyCode, flags: flags)
                : .keyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
            switch capture.handle(input) {
            case .listening: break
            case .bound(let binding):
                settings.binding = binding
                stopCapture()
            case .rejected(let message): captureMessage = message
            case .cancelled: stopCapture()
            }
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        settings.capturingShortcut = false
    }
}

struct Permissions {
    var accessibility: Bool
    var inputMonitoring: Bool
    var microphone: Bool

    static func current() -> Permissions {
        Permissions(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: CGPreflightListenEventAccess(),
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
    }
}
