import AppKit
import AVFoundation
import Combine
import DictationCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let settings = AppSettings()
    private let log = DictationLog()
    private let feedbackLog = DictationLog(fileName: "feedback.jsonl")
    /// The last dictation typed, for "That Was Wrong…".
    private var lastRecord: DictationRecord?
    private let pad = HotkeyPad(extendsDictationKey: [:])
    /// What the recording running now was started or turned into, when it acts on the last dictation.
    private var actingOnLast: DictationPurpose?
    private var keyTrace = KeyTrace()
    private var correctionBox: CorrectionBox?
    private lazy var autoReviewer = AutoReviewer(settings: settings, store: store)
    private let recorder = MicRecorder()
    private let cues = CuePlayer()
    private let store = ProfileStore()

    private var statusItem: NSStatusItem!
    private var listener: HotkeyListener?
    private var session: DictationSession!
    private var gestureTimer: Timer?
    private var listenerRetry: Timer?
    private var settingsWindow: NSWindow?
    private var reviewWindow: NSWindow?
    private lazy var editWatcher = EditWatcher { [weak self] feedback in self?.saveFeedback(feedback) }
    private var lastText: String?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LoginItem.exitIfAlreadyRunning()
        LoginItem.enableOnFirstInstalledLaunch()
        lastRecord = log.lastTyped()
        lastText = lastRecord?.text
        listener = HotkeyListener(bindings: hotkeys) { [weak self] index, match, time in
            MainActor.assumeIsolated { self?.keyMatched(index, match, at: time) }
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
        session.onCorrection = { [weak self] feedback in self?.saveFeedback(feedback) }
        session.rewriteHedge = 2.5
        session.transcribeHedge = 1.2
        session.onStatusChange = { [weak self] status in
            self?.show(status)
            if let cue = Cue.for(status) { self?.cues.play(cue) }
            // A new dictation types into the field, so the watch on the last one ends here.
            if case .recording = status { self?.editWatcher.finish() }
        }
        show(.idle)

        listener?.onClick = { [weak self] in self?.interfered(.clicked) }
        listener?.onModifier = { [weak self] keyCode, flags, time in
            MainActor.assumeIsolated {
                guard let self, self.settings.developerMode else { return }
                self.keyTrace.add(keyCode: keyCode, flags: flags, at: time)
                self.session.keyTrace = self.keyTrace.entries
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.interfered(.switchedApps) }
        }
        Publishers.CombineLatest4(settings.$binding, settings.$fixBinding, settings.$reviewBinding, settings.$rewriteBinding)
            .sink { [weak self] dictate, fix, review, rewrite in
                self?.listener?.bindings = [dictate, fix, review, rewrite]
                self?.pad.extendsDictationKey = [1: fix?.extends(dictate) ?? false, 3: rewrite?.extends(dictate) ?? false]
            }.store(in: &subscriptions)
        settings.$capturingShortcut.sink { [weak self] in self?.listener?.paused = $0 }.store(in: &subscriptions)
        settings.$warmSeconds.sink { [weak self] in self?.recorder.warmSeconds = $0 }.store(in: &subscriptions)
        settings.$cueVolume.sink { [weak self] in self?.cues.volume = $0 }.store(in: &subscriptions)
        settings.$developerMode.sink { [weak self] on in
            self?.session.saveAudio = on ? { wav, id in Recordings.save(wav, id: id) } : nil
            if on { Recordings.purge() }
        }.store(in: &subscriptions)

        requestPermissions()
        startListener()
        UNUserNotificationCenter.current().delegate = self
        autoReviewer.start()
        // `--open-settings [general|profiles|dictionary]` opens Settings at launch, on that tab.
        if let flag = CommandLine.arguments.firstIndex(of: "--open-settings") {
            let next = CommandLine.arguments.indices.contains(flag + 1) ? CommandLine.arguments[flag + 1] : "general"
            openSettings(tab: ["general", "profiles", "dictionary"].contains(next) ? next : "general")
        } else if !settings.hasAPIKey {
            openSettings()
        }
        // `--flag-last` opens "That Was Wrong…" for the last dictation at launch.
        if CommandLine.arguments.contains("--flag-last") {
            DispatchQueue.main.async { self.flagLast() }
        }
        // `--open-review [--all]` opens Review Dictations at launch.
        if CommandLine.arguments.contains("--open-review") { openReview() }
    }

    // MARK: hotkey to session

    private var hotkeys: [HotkeyBinding?] { [settings.binding, settings.fixBinding, settings.reviewBinding, settings.rewriteBinding] }

    private func interfered(_ what: DictationSession.Interference) {
        session.userInput(what)
    }

    /// `index`: 0 the dictation hotkey, 1 the fix hotkey, 2 the review hotkey, 3 the rewrite hotkey.
    private func keyMatched(_ index: Int, _ match: KeyMatch, at time: Double) {
        if index == 2 {
            if match == .bindingDown { openReview() }
            return
        }
        if index == 0, match == .otherKey { session.userInput() }
        apply(pad.handle(index, match, at: time))
    }

    private func apply(_ actions: [HotkeyPad.Action]) {
        for action in actions {
            switch action {
            case .dictation(let gestureAction):
                // The microphone first, then the cue, so the cue never delays recording.
                session.handle(gestureAction)
                if gestureAction == .start { settings.warmConnection() }
                cues.play(Cue.for(gestureAction))
                if gestureAction == .finish || gestureAction == .cancel { actingOnLast = nil }
            case .start(let purpose):
                guard !session.isRecording, lastRecord != nil else { continue }
                actingOnLast = purpose
                session.handle(.start, purpose: purpose)
                settings.warmConnection()
                cues.play(.microphoneOn)
            case .upgrade(let purpose):
                actingOnLast = purpose
                session.mark(purpose)
                cues.play(purpose == .rewrite ? .instructionMode : .fixMode)
            case .finish:
                guard actingOnLast != nil else { continue }
                actingOnLast = nil
                session.handle(.finish)
                cues.play(.microphoneOff)
            case .cancel:
                guard actingOnLast != nil else { continue }
                actingOnLast = nil
                session.handle(.cancel)
                cues.play(.cancelled)
            case .discard:
                actingOnLast = nil
                session.handle(.cancel)
            case .openBox(let purpose):
                guard !session.isRecording else { continue }
                purpose == .rewrite ? askForInstruction() : flagLast()
            }
        }
        gestureTimer?.invalidate()
        gestureTimer = nil
        guard let deadline = pad.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        gestureTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.apply(self.pad.tick(at: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    private func recorded(_ record: DictationRecord) {
        log.append(record)
        if record.outcome == .typed, record.fixes != nil, var last = lastRecord {
            // A fix or rewrite: the same dictation, now reading differently; what was said stays.
            last.text = record.text
            lastRecord = last
            lastText = record.text
            if settings.learnFromEdits { editWatcher.watch(last) }
        } else if record.outcome == .typed {
            lastText = record.text
            lastRecord = record
            if settings.learnFromEdits { editWatcher.watch(record) }
        } else if record.fixes != nil, let text = record.text {
            // A fix that could not be typed: offer it under "Copy last".
            lastText = text
        }
    }

    /// The profile for the app in front (or the one chosen in the menu), with its dictionary and clean-up engine.
    private func dictationContext() -> DictationContext {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let profile = store.profiles.profile(forApp: app, override: settings.profileOverride)
        return DictationContext(
            profile: profile, dictionary: store.dictionary,
            cleaner: profile.cleanupModel.map { settings.makeCleaner(model: $0) }, app: app,
            rewriter: settings.makeCleaner(model: settings.rewriteModel.isEmpty ? profile.cleanupModel ?? Profile.defaultCleanupModel : settings.rewriteModel))
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
            case .rewriting: return ("wand.and.stars", .systemPurple)
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
        if lastRecord != nil {
            let item = menu.addItem(withTitle: "That Was Wrong…", action: #selector(flagLast), keyEquivalent: "")
            item.target = self
            if let key = settings.fixBinding { item.toolTip = "Tap \(key.displayName) to type the fix, hold it to say it again" }
        }
        let count = autoReviewer.pending?.proposals.count ?? 0
        menu.addItem(withTitle: count > 0 ? "Review Dictations (\(count) suggestion\(count == 1 ? "" : "s"))…" : "Review Dictations…",
                     action: #selector(openReview), keyEquivalent: "").target = self
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

    /// Asks what the last dictation should have said, keeps the answer for the review, and fixes the text in
    /// place when the field still holds it as typed.
    @objc private func flagLast() {
        guard let record = lastRecord, !session.isRecording, correctionBox?.isOpen != true else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Typing in the box is not typing in the field, and must not trigger a hotkey.
        listener?.paused = true
        correctionBox = CorrectionBox.show(for: record) { [weak self] answer in
            guard let self else { return }
            self.listener?.paused = self.settings.capturingShortcut
            self.correctionBox = nil
            guard let answer else { return }
            let feedback = Feedback(flagging: record, correction: answer)
            self.saveFeedback(feedback)
            guard let corrected = feedback.correctedText, record.app == nil || record.app == front else { return }
            // Keyboard focus is back in the field once the panel is gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.editWatcher.cancel()
                if self.session.correctLast(corrected) {
                    self.lastText = corrected
                    self.lastRecord?.text = corrected
                }
            }
        }
    }

    /// Asks how the last dictation should change, and has it rewritten in place.
    private func askForInstruction() {
        guard let record = lastRecord, correctionBox?.isOpen != true else { return }
        listener?.paused = true
        correctionBox = CorrectionBox.instruction(for: record) { [weak self] answer in
            guard let self else { return }
            self.listener?.paused = self.settings.capturingShortcut
            self.correctionBox = nil
            guard let instruction = answer?.trimmingCharacters(in: .whitespacesAndNewlines), !instruction.isEmpty else { return }
            // The rewrite types once keyboard focus is back in the field.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.editWatcher.cancel()
                self.session.rewriteLast(instruction)
            }
        }
    }

    private func saveFeedback(_ feedback: Feedback) {
        feedbackLog.append(feedback)
        autoReviewer.check()
    }

    // MARK: notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.openReview() }
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

    @objc private func openReview() {
        let model = ReviewModel(settings: settings, store: store)
        let window = reviewWindow ?? {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Review Dictations"
            window.isReleasedWhenClosed = false
            return window
        }()
        window.contentViewController = NSHostingController(rootView: ReviewView(model: model) { [weak window] in window?.close() })
        reviewWindow = window
        if let outcome = autoReviewer.taken() {
            model.show(outcome)
        } else {
            model.start(all: CommandLine.arguments.contains("--all"))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

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
