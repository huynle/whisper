import AppKit
import AVFoundation
import Combine
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let log = DictationLog()
    private let gesture = HotkeyGesture()
    private let recorder = MicRecorder()
    private let cues = CuePlayer()
    private let store = ProfileStore()

    private var statusItem: NSStatusItem!
    private var listener: HotkeyListener?
    private var session: DictationSession!
    private var gestureTimer: Timer?
    private var listenerRetry: Timer?
    private var settingsWindow: NSWindow?
    private var lastText: String?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        listener = HotkeyListener(binding: settings.binding) { [weak self] match, time in
            MainActor.assumeIsolated { self?.keyMatched(match, at: time) }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        session = DictationSession(
            recorder: recorder,
            transcriber: { [settings] in settings.makeTranscriber() },
            keyboard: TypingKeyboard(),
            now: { ProcessInfo.processInfo.systemUptime },
            onRecord: { [weak self] record in self?.recorded(record) },
            context: { [weak self] in self?.dictationContext() ?? .plain })
        session.onStatusChange = { [weak self] status in
            self?.show(status)
            if let cue = Cue.for(status) { self?.cues.play(cue) }
        }
        show(.idle)

        listener?.onClick = { [weak self] in self?.session.userInput() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.userInput() }
        }
        settings.$binding.sink { [weak self] in self?.listener?.binding = $0 }.store(in: &subscriptions)
        settings.$capturingShortcut.sink { [weak self] in self?.listener?.paused = $0 }.store(in: &subscriptions)
        settings.$warmSeconds.sink { [weak self] in self?.recorder.warmSeconds = $0 }.store(in: &subscriptions)
        settings.$cueVolume.sink { [weak self] in self?.cues.volume = $0 }.store(in: &subscriptions)
        settings.$developerMode.sink { [weak self] on in
            self?.session.saveAudio = on ? { wav, id in Recordings.save(wav, id: id) } : nil
            if on { Recordings.purge() }
        }.store(in: &subscriptions)

        requestPermissions()
        startListener()
        // `--open-settings [general|profiles|dictionary]` opens Settings at launch, on that tab.
        if let flag = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let next = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "general"
            openSettings(tab: ["general", "profiles", "dictionary"].contains(next) ? next : "general")
        } else if !settings.hasAPIKey {
            openSettings()
        }
    }

    // MARK: hotkey to session

    private func keyMatched(_ match: KeyMatch, at time: Double) {
        switch match {
        case .bindingDown: apply(gesture.keyDown(at: time))
        case .bindingUp: apply(gesture.keyUp(at: time))
        case .otherKey:
            session.userInput()
            apply(gesture.otherKey(at: time))
        case .ignore: break
        }
    }

    private func apply(_ actions: [GestureAction]) {
        // The microphone first, then the cue, so the cue never delays recording.
        for action in actions {
            session.handle(action)
            cues.play(Cue.for(action))
        }
        gestureTimer?.invalidate()
        gestureTimer = nil
        guard let deadline = gesture.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        gestureTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.gesture.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func recorded(_ record: DictationRecord) {
        log.append(record)
        if record.outcome == .typed { lastText = record.text }
    }

    /// The profile for the app in front (or the one chosen in the menu), with its dictionary and clean-up engine.
    private func dictationContext() -> DictationContext {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let profile = store.profiles.profile(forApp: app, override: settings.profileOverride)
        return DictationContext(
            profile: profile, dictionary: store.dictionary,
            cleaner: profile.cleanupModel.map { settings.makeCleaner(model: $0) })
    }

    // MARK: permissions

    private func requestPermissions() {
        if !AXIsProcessTrusted() {
            let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
    }

    /// The listener needs Accessibility; until it is granted, try again every 2 seconds.
    private func startListener() {
        guard let listener else { return }
        if listener.start() { return }
        listenerRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.listener?.start() == true else { return }
                timer.invalidate()
                self.show(self.session.status)
            }
        }
        show(session.status)
    }

    // MARK: menu bar

    private func show(_ status: DictationSession.Status) {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?) = {
            if listener?.isRunning != true { return ("mic.slash", .systemOrange) }
            switch status {
            case .idle: return ("mic", nil)
            case .recording(locked: false): return ("mic.fill", .systemRed)
            case .recording(locked: true): return ("mic.circle.fill", .systemRed)
            case .transcribing: return ("ellipsis.circle", nil)
            case .failed: return ("exclamationmark.triangle", .systemOrange)
            }
        }()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Whisper")
        button.contentTintColor = tint
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if listener?.isRunning != true {
            menu.addItem(withTitle: "Allow Accessibility to use the hotkey…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        } else {
            info("Hold \(settings.binding.displayName) to dictate, double-tap to lock")
        }
        if !settings.hasAPIKey {
            menu.addItem(withTitle: "Add your API key…", action: #selector(openSettingsAction), keyEquivalent: "").target = self
        }
        if case .failed(let message) = session.status { info("Last dictation failed: \(message)") }
        if let problem = store.problem { info(problem) }
        store.refresh()

        let profiles = NSMenuItem(title: "Profile: \(settings.profileOverride ?? "Automatic")", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let automatic = submenu.addItem(withTitle: "Automatic (by app)", action: #selector(chooseProfile(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = settings.profileOverride == nil ? .on : .off
        submenu.addItem(.separator())
        for profile in store.profiles.profiles {
            let item = submenu.addItem(withTitle: profile.name, action: #selector(chooseProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = profile.name
            item.state = settings.profileOverride == profile.name ? .on : .off
        }
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Edit Profiles…", action: #selector(editProfiles), keyEquivalent: "").target = self
        submenu.addItem(withTitle: "Edit Dictionary…", action: #selector(editDictionary), keyEquivalent: "").target = self
        profiles.submenu = submenu
        menu.addItem(profiles)
        if let error = recorder.lastError { info(error) }
        if let lastText {
            let shown = lastText.count > 50 ? String(lastText.prefix(50)) + "…" : lastText
            menu.addItem(withTitle: "Copy last: \(shown)", action: #selector(copyLast), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Dictation Log", action: #selector(openLog), keyEquivalent: "").target = self
        if settings.developerMode {
            menu.addItem(withTitle: "Open Recordings Folder (developer mode)", action: #selector(openRecordings), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Whisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func copyLast() {
        guard let lastText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    @objc private func openLog() {
        if !FileManager.default.fileExists(atPath: log.url.path) { try? Data().write(to: log.url) }
        openInTextEditor(log.url)
    }

    @objc private func chooseProfile(_ item: NSMenuItem) {
        settings.profileOverride = item.representedObject as? String
    }

    @objc private func editProfiles() { openSettings(tab: "profiles") }
    @objc private func editDictionary() { openSettings(tab: "dictionary") }

    /// The default plain-text editor: macOS has no app for .jsonl, and may open .json in a viewer.
    private func openInTextEditor(_ url: URL) {
        let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText)
            ?? URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openRecordings() {
        NSWorkspace.shared.open(Recordings.folder)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettingsAction() { openSettings() }

    private func openSettings(tab: String? = nil) {
        if let tab { settings.settingsTab = tab }
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(settings: settings, store: store))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Whisper Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
