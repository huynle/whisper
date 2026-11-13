import AppKit
import AVFoundation
import Combine
import DictationCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let log = DictationLog()
    private let gesture = HotkeyGesture()
    private let recorder = MicRecorder()

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
            onRecord: { [weak self] record in self?.recorded(record) })
        session.onStatusChange = { [weak self] status in self?.show(status) }
        show(.idle)

        settings.$binding.sink { [weak self] in self?.listener?.binding = $0 }.store(in: &subscriptions)
        settings.$capturingShortcut.sink { [weak self] in self?.listener?.paused = $0 }.store(in: &subscriptions)
        settings.$warmSeconds.sink { [weak self] in self?.recorder.warmSeconds = $0 }.store(in: &subscriptions)

        requestPermissions()
        startListener()
        if !settings.hasAPIKey { openSettings() }
    }

    // MARK: hotkey to session

    private func keyMatched(_ match: KeyMatch, at time: Double) {
        switch match {
        case .bindingDown: apply(gesture.keyDown(at: time))
        case .bindingUp: apply(gesture.keyUp(at: time))
        case .otherKey: apply(gesture.otherKey(at: time))
        case .ignore: break
        }
    }

    private func apply(_ actions: [GestureAction]) {
        for action in actions { session.handle(action) }
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
        if let error = recorder.lastError { info(error) }
        if let lastText {
            let shown = lastText.count > 50 ? String(lastText.prefix(50)) + "…" : lastText
            menu.addItem(withTitle: "Copy last: \(shown)", action: #selector(copyLast), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Open Dictation Log", action: #selector(openLog), keyEquivalent: "").target = self
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
        NSWorkspace.shared.open(log.url)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openSettingsAction() { openSettings() }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
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
