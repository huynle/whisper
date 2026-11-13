import AppKit
import DictationCore
import SwiftUI
import UniformTypeIdentifiers

/// Clean-up models measured on 2026-11-13 (Brain th2dpn6c), fastest first; any other model id can be typed in.
let knownCleanupModels = [
    "openrouter/meta-llama/llama-3.3-70b-instruct",
    "openrouter/google/gemini-3.1-flash-lite",
    "openrouter/openai/gpt-4.1-nano",
    "no-think/claude/claude-haiku-5-5",
    "openrouter/google/gemini-2.5-flash-lite",
]

struct ProfilesView: View {
    @ObservedObject var store: ProfileStore
    @State private var selection: Int? = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Array(store.profileSet.profiles.enumerated()), id: \.offset) { index, profile in
                        Text(profile.name).tag(Optional(index))
                    }
                }
                Divider()
                HStack(spacing: 4) {
                    Button { selection = store.profileSet.addProfile() } label: { Image(systemName: "plus") }
                        .help("Add a profile")
                    Button { remove() } label: { Image(systemName: "minus") }
                        .help("Remove the selected profile")
                        .disabled(selection == nil || selection == store.profileSet.profiles.count - 1)
                    Button("Duplicate") {
                        if let selection { self.selection = store.profileSet.duplicateProfile(at: selection) }
                    }
                    .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 190)

            Divider()

            if let selection, store.profileSet.profiles.indices.contains(selection) {
                ProfileForm(store: store, index: selection)
                    .id(selection)
            } else {
                Text("Select a profile").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func remove() {
        guard let selection, store.profileSet.removeProfile(at: selection) else { return }
        self.selection = max(0, selection - 1)
    }
}

private struct ProfileForm: View {
    @ObservedObject var store: ProfileStore
    let index: Int
    @State private var nameDraft = ""

    private var profile: Profile { store.profileSet.profiles[index] }
    private var isFallback: Bool { index == store.profileSet.profiles.count - 1 }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $nameDraft)
                    .onSubmit(rename)
                    .onAppear { nameDraft = profile.name }
                if nameDraft != profile.name {
                    HStack {
                        Spacer()
                        Button("Rename") { rename() }
                    }
                }
            }

            Section("Used in") {
                if isFallback {
                    Text("Every app not listed in another profile.").foregroundStyle(.secondary)
                } else {
                    ForEach(profile.apps, id: \.self) { app in
                        HStack {
                            Text(appName(app))
                            Spacer()
                            Button { store.profileSet.profiles[index].apps.removeAll { $0 == app } } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Add App…") { chooseApp() }
                }
            }

            Section("Writing") {
                Picker("Typing", selection: binding(\.typing)) {
                    Text("Wait for the clean text").tag(Profile.Typing.waitForClean)
                    Text("Type at once, then correct").tag(Profile.Typing.rawThenFix)
                }
                Picker("Tone", selection: binding(\.tone)) {
                    Text("As spoken").tag(Profile.Tone.asSpoken)
                    Text("Casual").tag(Profile.Tone.casual)
                    Text("Professional").tag(Profile.Tone.professional)
                }
                Picker("Punctuation", selection: binding(\.punctuation)) {
                    Text("Full sentences").tag(Profile.Punctuation.full)
                    Text("Light, no full stop at the end").tag(Profile.Punctuation.light)
                    Text("Only what is said aloud").tag(Profile.Punctuation.spokenOnly)
                }
                Picker("Correctness", selection: binding(\.correctness)) {
                    Text("Word for word").tag(Profile.Correctness.asSaid)
                    Text("Remove fillers and false starts").tag(Profile.Correctness.clean)
                    Text("Also correct grammar").tag(Profile.Correctness.corrected)
                    Text("Polish for clarity").tag(Profile.Correctness.polished)
                }
                Toggle("Spoken symbols (tilde → ~, slash → /, dot → .)", isOn: binding(\.spokenSymbols))
                Toggle("End with a space", isOn: binding(\.trailingSpace))
            }

            Section("Clean-up") {
                Picker("Model", selection: cleanupChoice) {
                    Text("None: type the speech model's text").tag("")
                    ForEach(cleanupChoices, id: \.self) { Text($0).tag($0) }
                }
                if profile.cleanupModel != nil {
                    TextField("Model id", text: Binding(
                        get: { profile.cleanupModel ?? "" },
                        set: { store.profileSet.profiles[index].cleanupModel = $0.isEmpty ? nil : $0 }))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Instructions")
                    TextEditor(text: binding(\.instructions))
                        .font(.body)
                        .frame(minHeight: 70)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Profile, T>) -> Binding<T> {
        Binding(
            get: { store.profileSet.profiles[index][keyPath: keyPath] },
            set: { store.profileSet.profiles[index][keyPath: keyPath] = $0 })
    }

    private var cleanupChoices: [String] {
        guard let current = profile.cleanupModel, !knownCleanupModels.contains(current) else { return knownCleanupModels }
        return [current] + knownCleanupModels
    }

    private var cleanupChoice: Binding<String> {
        Binding(
            get: { profile.cleanupModel ?? "" },
            set: { store.profileSet.profiles[index].cleanupModel = $0.isEmpty ? nil : $0 })
    }

    private func rename() {
        var dictionary = store.userDictionary
        store.profileSet.rename(profileAt: index, to: nameDraft, dictionary: &dictionary)
        if dictionary != store.userDictionary { store.userDictionary = dictionary }
        nameDraft = profile.name
    }

    /// Names for the apps the default profiles list, for when an app is not installed on this Mac.
    private static let knownApps = [
        "com.googlecode.iterm2": "iTerm", "com.apple.Terminal": "Terminal", "com.mitchellh.ghostty": "Ghostty",
        "net.kovidgoyal.kitty": "kitty", "dev.warp.Warp-Stable": "Warp", "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor", "dev.zed.Zed": "Zed", "com.apple.dt.Xcode": "Xcode",
        "com.apple.Notes": "Notes", "md.obsidian": "Obsidian", "notion.id": "Notion", "net.shinyfrog.bear": "Bear",
        "com.apple.TextEdit": "TextEdit", "com.apple.mail": "Mail", "com.microsoft.Outlook": "Outlook",
        "com.tinyspeck.slackmacgap": "Slack", "com.apple.MobileSMS": "Messages", "com.hnc.Discord": "Discord",
        "ru.keepcoder.Telegram": "Telegram",
    ]

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return (Self.knownApps[bundleID] ?? bundleID) + " (not installed)"
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier { store.profileSet.assign(app: bundleID, toProfileAt: index) }
        }
    }
}

struct DictionaryView: View {
    @ObservedObject var store: ProfileStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Words the speech model gets wrong. \"Always\" replaces the misheard forms everywhere; \"In context\" tells the clean-up model, which applies it only where it fits. Separate several forms with commas; leave Profiles empty for all.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Written").bold()
                    Text("Said as").bold()
                    Text("Misheard as").bold()
                    Text("Applies").bold()
                    Text("Profiles").bold()
                    Text("")
                }
                ForEach(store.userDictionary.entries.indices, id: \.self) { i in
                    GridRow {
                        TextField("~", text: field(i, \.written)).frame(width: 90)
                        TextField("tilde", text: list(i, \.spoken))
                        TextField("today, two", text: list(i, \.misheard))
                        Picker("", selection: field(i, \.kind)) {
                            Text("In context").tag(DictionaryEntry.Kind.context)
                            Text("Always").tag(DictionaryEntry.Kind.always)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        TextField("All", text: profiles(i)).frame(width: 110)
                        Button { store.userDictionary.entries.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Button("Add Word") {
                store.userDictionary.entries.append(DictionaryEntry(written: "", spoken: [], misheard: [], kind: .context, profiles: nil))
            }
            Spacer()
        }
        .padding()
    }

    private func field<T>(_ i: Int, _ keyPath: WritableKeyPath<DictionaryEntry, T>) -> Binding<T> {
        Binding(
            get: { store.userDictionary.entries[i][keyPath: keyPath] },
            set: { store.userDictionary.entries[i][keyPath: keyPath] = $0 })
    }

    private func list(_ i: Int, _ keyPath: WritableKeyPath<DictionaryEntry, [String]>) -> Binding<String> {
        Binding(
            get: { CommaList.format(store.userDictionary.entries[i][keyPath: keyPath]) },
            set: { store.userDictionary.entries[i][keyPath: keyPath] = CommaList.parse($0) })
    }

    private func profiles(_ i: Int) -> Binding<String> {
        Binding(
            get: { CommaList.format(store.userDictionary.entries[i].profiles ?? []) },
            set: {
                let names = CommaList.parse($0)
                store.userDictionary.entries[i].profiles = names.isEmpty ? nil : names
            })
    }
}
