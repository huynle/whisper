import AppKit
import AVFoundation
import DictationCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var store: ProfileStore

    var body: some View {
        TabView(selection: $settings.settingsTab) {
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ProfilesView(store: store)
                .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
                .tag("profiles")
            DictionaryView(store: store)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag("dictionary")
        }
        // Grouped Forms scroll, so they report no height of their own; without a fixed size the window collapses.
        .frame(width: 760, height: 660)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var showKey = false
    @State private var captureMessage: String?
    @State private var monitor: Any?
    @State private var capture = ShortcutCapture()
    @State private var capturing: HotkeyTarget?

    enum HotkeyTarget: String { case dictate, fix, rewrite, review }
    @State private var permissions = Permissions.current()
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginMessage: String?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Open Whisper at login", isOn: Binding(
                    get: { openAtLogin },
                    set: { wanted in
                        loginMessage = LoginItem.set(wanted).map { "Could not change it: \($0)" }
                        openAtLogin = LoginItem.isEnabled
                    }))
                if LoginItem.needsApproval {
                    Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if !LoginItem.isInstalled {
                    Text("This copy runs from \(Bundle.main.bundleURL.deletingLastPathComponent().path). Install it with scripts/install.sh so the login item points to a copy that stays put.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let loginMessage {
                    Text(loginMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Hotkeys") {
                hotkeyRow("Dictate", .dictate, settings.binding)
                Text("Hold to talk; release to finish. Double-tap to keep listening; tap again to finish.")
                    .font(.caption).foregroundStyle(.secondary)
                hotkeyRow("Fix the last dictation", .fix, settings.fixBinding)
                Text("Hold and say it again to replace what was typed; tap to type the fix. Either way the correction is kept for the review.")
                    .font(.caption).foregroundStyle(.secondary)
                hotkeyRow("Rewrite by instruction", .rewrite, settings.rewriteBinding)
                Text("Hold and say how to change the last dictation (\u{201C}make it a little more formal\u{201D}); tap to type the instruction. A model rewrites it in place.")
                    .font(.caption).foregroundStyle(.secondary)
                hotkeyRow("Review dictations", .review, settings.reviewBinding)
                if let captureMessage {
                    Text(captureMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Speech model") {
                TextField("Provider address", text: $settings.baseURL)
                Picker("Model", selection: $settings.model) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }
                TextField("Model id", text: $settings.model)
                TextField("Language (empty: detect)", text: $settings.language)
                HStack {
                    Group {
                        if showKey { TextField("API key", text: $keyDraft) } else { SecureField("API key", text: $keyDraft) }
                    }
                    .onAppear { keyDraft = settings.apiKey.value() ?? "" }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .help(showKey ? "Hide the key" : "Show the key")
                    Button("Save") { saveKey() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == (settings.apiKey.value() ?? ""))
                    if settings.hasAPIKey {
                        Button("Remove") {
                            keyDraft = ""
                            saveKey()
                        }
                    }
                }
                Text(keyMessage ?? "Saved on this Mac in ~/Library/Application Support/Whisper/api-key, readable only by your account.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Microphone") {
                Picker("Keep the microphone ready", selection: $settings.warmSeconds) {
                    ForEach(AppSettings.warmChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                }
                Text("While ready, the next press records at once, and the macOS microphone indicator stays on.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Sound cues", selection: $settings.cueVolume) {
                    ForEach(AppSettings.cueChoices, id: \.volume) { Text($0.label).tag($0.volume) }
                }
                Text("A blip when the microphone turns on, two rising when it locks, a lower one when it turns off, two falling when a press is cancelled, a low tone when a dictation fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Learning") {
                Toggle("Review on my own and notify me", isOn: $settings.autoReview)
                Text("After 5 corrections, or once a day, Whisper asks the review model for suggestions in the background and shows a notification when there are some. Nothing changes until you save a suggestion.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Learn from my corrections", isOn: $settings.learnFromEdits)
                Text("For 30 seconds after a dictation, Whisper notices when you fix what it typed, and keeps the fixed text (only that) for the review. Fields that hide their text, like passwords and most terminals, are never read.")
                    .font(.caption).foregroundStyle(.secondary)
                modelPicker("Rewrite model", $settings.rewriteModel, empty: "Same as the profile's clean-up model", choices: knownCleanupModels)
                Text("Rewrites the last dictation when you give an instruction. Measured fastest: openrouter/openai/gpt-4.1-nano.")
                    .font(.caption).foregroundStyle(.secondary)
                modelPicker("Review model", $settings.reviewModel, empty: nil, choices: [Reviewer.defaultModel, "claude/claude-opus-5-5", "claude/claude-haiku-5-5"])
                Text("Review Dictations… in the menu asks this model to suggest dictionary and profile changes from your recent dictations and corrections. Nothing changes until you tick and save a suggestion.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Developer") {
                Toggle("Developer mode", isOn: $settings.developerMode)
                Text("Keeps every recording on this Mac for 30 days, next to the detailed timings in the dictation log, so speed and accuracy can be analysed and models compared.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Recordings Folder") { NSWorkspace.shared.open(Recordings.folder) }
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
        .onReceive(refresh) { _ in
            permissions = Permissions.current()
            openAtLogin = LoginItem.isEnabled
        }
        .onDisappear { stopCapture() }
    }

    private var modelChoices: [String] {
        AppSettings.knownModels.contains(settings.model) ? AppSettings.knownModels : [settings.model] + AppSettings.knownModels
    }

    /// A menu of known models, plus a field for any other model id.
    @ViewBuilder
    private func modelPicker(_ title: String, _ value: Binding<String>, empty: String?, choices: [String]) -> some View {
        let all = (value.wrappedValue.isEmpty || choices.contains(value.wrappedValue) ? [] : [value.wrappedValue]) + choices
        Picker(title, selection: value) {
            if let empty { Text(empty).tag("") }
            ForEach(all, id: \.self) { Text($0).tag($0) }
        }
        TextField("\(title) id", text: value, prompt: Text(empty ?? "model id"))
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
            keyDraft = settings.apiKey.value() ?? ""
            keyMessage = settings.hasAPIKey ? "Key saved. It is used from the next dictation." : "Key removed."
        } catch {
            keyMessage = "Could not store the key: \(error)"
        }
    }

    private func hotkeyRow(_ title: String, _ target: HotkeyTarget, _ binding: HotkeyBinding?) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(capturing == target ? "Press the new shortcut…" : binding?.displayName ?? "Not set")
                .foregroundStyle(capturing == target || binding == nil ? .secondary : .primary)
            if target != .dictate, binding != nil, capturing != target {
                Button("Clear") { assign(nil, to: target) }
            }
            Button(capturing == target ? "Cancel" : "Change…") {
                capturing == target ? stopCapture() : startCapture(target)
            }
            .disabled(capturing != nil && capturing != target)
        }
    }

    private func assign(_ binding: HotkeyBinding?, to target: HotkeyTarget) {
        switch target {
        case .dictate: if let binding { settings.binding = binding }
        case .fix: settings.fixBinding = binding
        case .review: settings.reviewBinding = binding
        case .rewrite: settings.rewriteBinding = binding
        }
    }

    /// The other hotkey `binding` is already used for, if any.
    private func clash(_ binding: HotkeyBinding, for target: HotkeyTarget) -> String? {
        let others: [(HotkeyTarget, HotkeyBinding?, String)] = [
            (.dictate, settings.binding, "dictating"), (.fix, settings.fixBinding, "fixing"), (.review, settings.reviewBinding, "reviewing"),
            (.rewrite, settings.rewriteBinding, "rewriting"),
        ]
        return others.first { $0.0 != target && $0.1 == binding }?.2
    }

    private func startCapture(_ target: HotkeyTarget) {
        stopCapture()
        capture = ShortcutCapture()
        captureMessage = nil
        capturing = target
        settings.capturingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let flags = UInt64(event.modifierFlags.rawValue)
            let input: KeyInput = event.type == .flagsChanged
                ? .flagsChanged(keyCode: event.keyCode, flags: flags)
                : .keyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
            switch capture.handle(input) {
            case .listening: break
            case .bound(let binding):
                guard let target = capturing else { break }
                if let use = clash(binding, for: target) {
                    captureMessage = "\(binding.displayName) is already the hotkey for \(use). Choose another."
                } else {
                    assign(binding, to: target)
                    stopCapture()
                }
            case .rejected(let message): captureMessage = message
            case .cancelled: stopCapture()
            }
            return nil
        }
    }

    private func stopCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturing = nil
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
