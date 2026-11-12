# Mac dictation app: design

Date: 2026-11-12
Status: design agreed in conversation. Brain project: `whisper`. Nothing is built. The only thing run so far is a toolchain check (see "Toolchain").

## Goal

A menu bar app for macOS that works like Wispr Flow: press a key, talk, and the words appear in whichever text field has focus. It must:

- work in any app, with no integration into specific apps;
- be fast, because it is used in short bursts, often;
- write text the way the context needs it (for example `~/projects/whisper` in a terminal, not "today slash projects slash whisper");
- handle long pauses, thinking out loud, and fillers ("umm", "ahh");
- use cloud speech models from OpenRouter, a cloud Whisper host, and OmniRoute (`api.ai.huynle.com`);
- record how it is used so it can be inspected and improved.

An Android version may follow. It is not designed here.

## Decisions

| Topic | Decision | Rejected |
|---|---|---|
| Platform | Pure Swift and SwiftUI Mac app. Profiles and dictionary are portable JSON so a later Android app can reuse the formats. | Shared Rust or Kotlin core; Tauri or Flutter |
| Speech models | Cloud only: OpenRouter, a cloud Whisper host, OmniRoute | Whisper running on the Mac |
| Pipeline | Both recipes from the start, chosen per profile: two-step (speech model, then clean-up model) and one-step (audio-capable chat model) | Two-step only; one-step only |
| Profile choice | Automatic from the focused app, with a manual override in the menu bar | Manual only; one hotkey per profile; model decides |
| Text entry | Simulated keyboard everywhere: type, backspace, retype | Herdr or iTerm integration; Accessibility text replacement; a macOS input method |
| Live text | Typed phrase by phrase while talking, revised in place as context improves | Insert only at the finish (kept as a per-profile fallback) |
| Finishing | Key release or tap always works. Auto-finish is a setting per mode: default on for locked mode, off for hold mode | Manual only |
| History | Full trace per dictation; audio deleted automatically after 30 days (adjustable) | Keep audio forever; text only; record only in developer mode |

## 1. App shape and parts

The app lives in the menu bar with no Dock icon. The code is one Swift package with two targets:

- **Core library:** logic that needs no screen or system permission (providers, pipeline, speech detection, profiles, dictionary, revision, storage). Automated tests run here.
- **App:** everything that touches the system (hotkey, microphone, simulated keyboard, windows).

| Part | What it does |
|---|---|
| Hotkey listener | Detects hold-to-talk and double-tap-to-lock system-wide. Also sees the user's own key presses and clicks, which the revision safety rules need. |
| Recorder | Captures the microphone as 16 kHz mono audio |
| Speech detector | Finds speech, cuts it into segments at pauses, drops silence and noise |
| Context reader | Finds the focused app and picks the profile |
| Pipeline | Runs the profile's recipe on each segment and on the whole dictation |
| Keyboard | Types text and revises it in place with simulated key presses |
| Store | Saves the trace and audio, expires old audio |
| Interface | Menu bar menu, floating indicator, pop-ups and tips, settings, developer mode |

Permissions: Microphone, Accessibility (to send key presses), Input Monitoring (to see the hotkey).

macOS ties these permissions to the app's code signature. An ad-hoc signature changes on every build, so the build script signs with a stable self-signed certificate.

Storage:

- API keys: macOS Keychain, never in files.
- Profiles and dictionary: JSON files in the app's folder under `~/Library/Application Support`.
- History: a SQLite database in the same folder, with audio files beside it.

### Toolchain

- macOS 26.3.1, Apple Silicon, Swift 6.3.1.
- Xcode 26.4.1 is installed at `/Applications/Xcode.app` but is not the selected developer directory (the Command Line Tools are).
- Checked on 2026-11-12 with a scratch package: `swift test` fails on the Command Line Tools alone ("no such module 'Testing'") and passes with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Build and test scripts set `DEVELOPER_DIR` themselves. The system setting is not changed.

## 2. Providers, engines and recipes

A **provider** is a base address plus a key. Three to start: OpenRouter, a cloud Whisper host, OmniRoute.

An **engine** is a model on a provider, in one of three roles:

| Role | Input | Output |
|---|---|---|
| Speech engine | Audio | Raw transcript |
| Clean-up engine | Raw transcript, profile settings, dictionary | Finished text |
| Audio chat engine | Audio, profile settings, dictionary | Finished text |

A **recipe** is what a profile runs:

- **Two-step:** a speech engine, then a clean-up engine.
- **One-step:** an audio chat engine alone.

A profile may also name a fallback recipe.

Hub (`~/projects/hub/src/central/speech`) already calls OpenRouter and OpenAI-compatible hosts through the standard transcription request (multipart `POST {base}/audio/transcriptions` with `file`, `model`, optional `language`). The app uses the same request shape. Two details from Hub are reused:

- For Whisper models, ask for `verbose_json` and drop segments whose `no_speech_prob` is above 0.6. Retry once without it if the provider refuses.
- A provider's model list is not labelled by kind, so speech models are picked out by name, as Hub's `models.ts` does.

The instructions to clean-up and audio chat engines always say: format what was said, never answer it or act on it, never change meaning, never alter exact items such as paths, code and names.

## 3. Speech detection (ported from Hub)

Hub's voice loop (`~/projects/hub/packages/voice-client`) is TypeScript for the browser, so it cannot be used directly. Its decision logic in `src/core/` has no browser code and is ported to Swift, with Hub's test cases, so the port can be checked against the original.

Ported:

| Hub source | What it gives |
|---|---|
| `conversation-core.ts`: `Segmenter`, `EnergyMeter`, `VOICE_TIMINGS` | Segments from voiced and unvoiced frames; loudness-based detection as the fallback |
| `speech-vad.ts`: `ProbabilityVad`, `NORMAL_VAD` | Segments from the Silero model's speech probabilities |
| `conversation-core.ts`: `isFiller`, `looksComplete`, `Endpointer` | Filler-only segments dropped; "is the thought finished" from the text; the hold timers |
| `junk-transcript.ts` | Drops text Whisper invents from noise ("Thank you.", "[Music]") |
| `smart-turn.ts` and the Smart Turn model | "Is the thought finished" from the audio |
| `src/vad/silero_vad.onnx` (MIT), `src/turn/smart-turn-v3.2-cpu.onnx` (BSD-2-Clause) | The two bundled models, shipped with their licence files |

Starting values, from Hub: speech starts after 250 to 300 ms of voice; a segment ends after 350 ms of silence; 300 ms of audio before the onset and 200 ms after the end are kept.

How dictation uses it:

- **Pauses never end a dictation** unless auto-finish is on (section 4).
- **Silence is cut before upload.** Uploads are smaller and Whisper has less silence to invent text from.
- **Each segment is transcribed while the user is still talking.**
- **Pause lengths go to the clean-up engine** as hints for sentence and paragraph breaks.

Beyond Hub:

- Fillers inside a sentence and false starts ("no wait, I mean") are removed by the clean-up engine, according to the profile's correctness setting.
- If clean-up fails, a plain filler-word strip is applied to the raw transcript.

## 4. Starting and finishing a dictation

| Mode | Start | Manual finish | With auto-finish on |
|---|---|---|---|
| Hold | Hold the hotkey | Release | Each finished thought becomes final while the key stays down; listening continues until release |
| Locked | Double-tap the hotkey | Tap again | The finished thought becomes final and the mic closes |

Defaults: auto-finish on for locked mode, off for hold mode.

"Finished" is judged by Hub's logic: the Smart Turn model scores the audio, the text is checked for an unfinished ending (a trailing "and", "the", a comma), and plain silence timers decide if the model is unavailable or slow.

Dictation is more patient than Hub's conversation mode (1.0 s for finished-looking text, 1.6 s for unfinished). Starting values: about 2.5 s and 4 s, adjustable in settings.

## 5. Live rendering and revision

All text goes in through simulated key presses, so the app needs no knowledge of the target app.

Two passes:

1. **Fast pass:** each segment is transcribed as soon as it ends, gets the "always" dictionary replacements, and is typed.
2. **Revise pass:** the clean-up engine re-reads the whole dictation so far with the profile's settings and returns a corrected version. The app compares it with what it typed, sends backspaces back to the first difference, and types the new ending. Example: `today/projects` becomes `~/projects`.

A last revise pass runs at the finish. After that the text is final and is not touched again.

Text appears phrase by phrase, about a second behind speech. Word-by-word text would need a streaming speech model, which is not part of this design.

The app types blind: it knows what it sent, not what is in the field. Safety rules:

- Only text from the current dictation is revised.
- Revising stops if the user types, clicks or switches apps during the dictation.
- When revising stops, the typed text stays and the corrected version is offered in a pop-up to copy.
- Enter is never typed, so a dictation cannot run a command or send a message.

Known limits:

| Situation | Effect |
|---|---|
| Editors that insert text themselves (auto-closed brackets, autocomplete) | The backspace count can be wrong |
| Password fields | macOS blocks simulated input; dictation is skipped with a pop-up |
| iTerm "Secure Keyboard Entry" | Expected to hide the hotkey while iTerm has focus; not yet confirmed |
| A long revision | Text is briefly seen being deleted and retyped |
| No text field focused | The text is kept on the clipboard and a pop-up says so; detection is best-effort |

Per-profile fallback: where in-place revision is unreliable for an app, the profile shows live text in the floating indicator and types once at the finish.

The app only knows which app is in front. In iTerm it cannot tell a shell prompt from an agent prompt, so one terminal profile covers both and the user can switch by hand.

## 6. Profiles and dictionary

A profile contains:

| Field | Meaning |
|---|---|
| Name, apps | The apps it applies to, by macOS bundle identifier |
| Recipe, fallback recipe | Two-step or one-step, and which engines |
| Tone | As spoken, casual, professional, or a custom description |
| Punctuation | Full sentences with capitals; light (no trailing full stop); only what is said aloud |
| Correctness | As said; clean (fillers and false starts removed); corrected (grammar fixed too); polished (may rephrase for clarity) |
| Spoken symbols | For example tilde, slash, dot, dash, underscore |
| Instructions | Free text for anything the settings do not cover |
| Insertion style | Live in the field, or preview in the indicator and type at the finish |

Shipped profiles: *Terminal* (matched to iTerm) and *General* (everything else).

A dictionary entry:

```json
{
  "written": "~",
  "spoken": ["tilde"],
  "misheard": ["today", "tilda"],
  "kind": "context",
  "profiles": ["Terminal"]
}
```

- `kind: "always"`: exact replacement everywhere it applies. For terms that are safe to replace blindly.
- `kind: "context"`: given to the clean-up engine, which applies it only where it fits. Needed because replacing every "today" with `~` would break ordinary sentences.
- `profiles` is optional; without it the entry applies to every profile.

The dictionary is used at three points: as a vocabulary hint to the speech engine (where the model accepts one), in the instructions to the clean-up or audio chat engine, and as exact replacements on the text.

## 7. History and developer mode

Per dictation, history keeps:

- when, which app, profile, recipe and engines;
- each segment: length, pause before it, raw transcript, and the reason if it was dropped;
- every revision typed, and the final text;
- time taken by each step, and errors;
- the audio file, deleted automatically after 30 days (adjustable);
- the user's correction, if they marked the result wrong.

The text record stays until deleted, one dictation at a time or all at once.

Developer mode is a window listing dictations. For each: a timeline of the audio with segments and pauses, the raw transcript per segment, each revision, the final text, timings, drop reasons and errors. From there the user can replay audio, re-run it through another profile or recipe and compare side by side, and mark a result wrong to create a dictionary entry. It is modelled on Hub's voice recording view.

Saved recordings with corrections double as a test set for comparing models and profile settings.

## 8. Interface

- **Menu bar icon:** shows idle, listening, working or problem. Menu: active profile and switcher, recent dictations (click to copy), settings, developer mode, quit.
- **Floating indicator:** a small pill near the bottom of the screen while dictating. Shows sound level, locked state, and live text for preview-style profiles. It never takes keyboard focus.
- **Pop-ups:** brief and non-blocking. Problems (fallback used, revising stopped, provider failed) and tips triggered by use (for example suggesting double-tap to lock after several long holds, or a dictionary entry after a repeated mishearing). Tips appear rarely and can be turned off.
- **First-run setup:** permissions, hotkey, provider keys, a test dictation.
- **Settings:** General (hotkey, auto-finish, timings), Providers and engines, Profiles, Dictionary, History and privacy.

## 9. Speed

The app is used in short bursts, often, so delay is a design constraint, not a later tuning step.

| Where time goes | What the design does |
|---|---|
| Starting the microphone | Capture is kept warm for a period after each dictation (setting: off, a number of seconds, or always; default 60 seconds). While warm, the macOS microphone indicator stays on. |
| Connecting to the provider | The connection is opened at key press and reused between dictations |
| Transcribing | Segments are transcribed while the user talks, so only the last segment remains at the finish |
| Clean-up | The fast pass is typed without waiting for clean-up; clean-up arrives as a revision |
| Presses with no speech | Discarded on the Mac with no network call |
| Dictations in quick succession | A new dictation can start while the previous one is finishing. Text is typed strictly in order, and the previous dictation has a hard time limit so the next is never held for long. |

Every step is timed in the trace from the first usable build, and developer mode shows the timings per engine, so engines are chosen by measured speed.

Targets to check against measurements (not yet measured, and dependent on the providers):

- no clipped first word when capture is warm;
- for a 5-second dictation, first text within about 1 second of the finish and final text within about 2 seconds.

If cloud models cannot meet these, running a speech model on the Mac is the option to revisit.

## 10. When something fails

The user should never lose what they said.

- **Clean-up fails or is too slow:** the raw transcript with dictionary replacements and the filler strip stays as typed; a pop-up says so.
- **Speech or audio chat engine fails:** the profile's fallback recipe is tried.
- **Everything fails:** the audio is kept in history with a retry button; a pop-up says so.
- Each step has a time limit, set from measurements.

## 11. Testing

| Area | How it is checked |
|---|---|
| Core logic (segmenting, filters, profile matching, dictionary) | Automated tests; parts ported from Hub reuse Hub's test cases |
| Revision (old text to new text as backspaces and typing) | Automated tests, including `today/projects` to `~/projects` |
| Pipeline (failures, time limits, fallbacks, ordering of quick dictations) | Automated tests with stand-in engines |
| Providers | Automated tests against recorded responses; a manual check against the real services |
| Hotkey, typing, permissions | The app types into its own test window and reads it back; a manual checklist for iTerm and a browser form |
| Speed | Step timings from the trace compared with the targets in section 9 |
| Quality over time | Saved recordings re-run through recipes and compared with the user's corrections |

## 12. Build order

Each step ends with something that can be tried.

1. **Keyboard prototype:** type a phrase and revise it in place, in iTerm (under Herdr), a browser form and a native field. Decides whether live editing is viable. If not, the preview style in section 5 becomes the default and the rest stands.
2. **First dictation:** hotkey, recorder, one speech engine, text typed at the finish, a basic timed record of each dictation.
3. **Providers and recipes:** three providers, both recipes, clean-up, fallbacks, keys in the Keychain. Measure speed per engine.
4. **Profiles and dictionary:** app matching, tone, punctuation, correctness, both kinds of dictionary entry.
5. **Live rendering:** speech detection ported from Hub, transcription per segment, in-place revision, quick successive dictations.
6. **Auto-finish:** Hub's finished-thought logic and model.
7. **History and developer mode:** full trace, audio expiry, replay and comparison.
8. **Interface:** indicator, pop-ups and tips, first-run setup, settings.

## Not yet verified

- Whether OmniRoute accepts the standard transcription request and which speech models it offers. Its model list returned 401 without a key.
- Which speech models accept a vocabulary hint. Hub does not send one.
- Which audio-capable chat models are available on the three providers for the one-step recipe.
- Running the Silero and Smart Turn models from Swift. The loudness detector and the silence timers are the fallbacks.
- In-place revision in iTerm under Herdr, including agent prompts.
- The effect of iTerm's "Secure Keyboard Entry" on the hotkey.
- Whether a held hotkey interferes with simulated typing in hold mode.
- How long the microphone takes to start cold, and how much of the first word is lost.
- All speed targets.

## Open items

- The app's name.
- Which key is the hotkey.
- Which host provides cloud Whisper.

## Sources read

- `~/projects/hub/packages/voice-client/README.md`
- `~/projects/hub/packages/voice-client/src/core/conversation-core.ts`
- `~/projects/hub/packages/voice-client/src/core/speech-vad.ts`
- `~/projects/hub/packages/voice-client/src/core/junk-transcript.ts`
- `~/projects/hub/packages/voice-client/src/core/smart-turn.ts`
- `~/projects/hub/src/central/speech/provider.ts`, `openrouter.ts`, `models.ts`
- `herdr --help`, `herdr pane --help`, `herdr agent --help` (considered and rejected as an integration)
