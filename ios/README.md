# Aside for iPhone

A dictation keyboard, plus a Control Center control. Hold the mic key in the Aside
keyboard, speak, let go — the text lands at your cursor in whatever app you were typing
in. Or tap the Aside control in Control Center, speak, tap again — the text is copied to
the clipboard for you to paste wherever you like.

An iOS keyboard extension **cannot use the microphone**. That has been true since iOS 8 and
is still true in iOS 26, with or without Full Access. So the work is split:

- the **app** owns the microphone, runs Parakeet v3 on the phone (or posts the audio to a
  provider you chose), runs cleanup on Apple's on-device model (or at a provider), and
  applies your dictionary;
- the **keyboard** writes a one-line command into a shared App Group folder, waits for the
  answer, and pastes it;
- the **control** (Control Center, Lock Screen, or the Action button; iOS 26 and later)
  writes the same command, and the app puts the answer on the clipboard, with a
  notification showing the text.

Keeping the app's audio engine running is what keeps it alive in the background, so after
one app switch per session every dictation is keyboard-only or control-only: tap, speak,
tap, text appears. A control tapped with no session running opens Aside once, which starts
the session and the recording.

```
ios/
  project.yml        xcodegen spec: app target Aside, extension target AsideKeyboard
  build.sh           generic-iOS-device compile check, no signing
  Shared/AsideIPC.swift    the hand-off protocol, unit-tested from the Mac test target
  App/               the app: session engine, recorder, pipeline, four screens
  Keyboard/          the keyboard extension: status line, mic button, four keys
  Control/           the Control Center toggle (a WidgetKit control + one App Intent)
  Tests/             AsideIPCTests.swift (runs in the Mac test target — see below)
```

Everything platform-neutral is shared with the Mac app by reference, never copied:
`Log.swift`, `Settings.swift`, `Dictionary.swift`, `DictionaryReplacer.swift`,
`CleanupPrompt.swift`, `AppleCleanup.swift`, `LocalTranscriber.swift`,
`Providers.swift`, `APIKeyStore.swift`, `DirectClient.swift` in the app, and `Trigger.swift`
in the keyboard. See `../mac/Sources`.

## Build

```sh
cd ios
./build.sh
```

That runs `xcodegen generate` and compiles **both** targets for `generic/platform=iOS` with
`CODE_SIGNING_ALLOWED=NO`; it is the automated verification and needs a network connection
the first time, to resolve FluidAudio into `ios/build`. To run it in the iOS Simulator
instead, open the project in Xcode and pick an iPhone simulator as the destination; the App
Group needs a signed build, so keep automatic signing on.

The protocol tests live in the Mac test target, because they are Foundation-only and a
simulator is not needed:

```sh
cd mac
DVT_PLUG_INS_TO_IGNORE=com.apple.dt.IDESimulatorFoundation \
  xcodebuild -project Aside.xcodeproj -scheme Aside \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build test
```

## Put it on your phone

1. **Fill in your team.** Open `ios/Signing.xcconfig` (created from
   `Signing.xcconfig.example` by `build.sh`) and set `DEVELOPMENT_TEAM` to your 10-character
   Team ID — this repo's owner is `44F896V7UJ`. A free Apple ID works; the Team ID is the
   one Xcode shows under Settings → Accounts.
2. **Generate and open the project.**
   ```sh
   cd ios && ./build.sh && open Aside.xcodeproj
   ```
3. **Turn on Developer Mode** on the phone (iOS 16 and later): Settings → Privacy &
   Security → Developer Mode, then restart it when asked. Xcode cannot install anything
   without it.
4. **Plug in the iPhone**, unlock it, and pick it in Xcode's run destination menu. Trust the
   computer if the phone asks.
5. Check both targets in Signing & Capabilities: **Aside** and **AsideKeyboard** should each
   show "Automatically manage signing", your team, and the App Group
   `group.com.codywright.aside` with a filled checkbox. Xcode registers the group with Apple
   the first time; if it shows a warning triangle press **Try Again**.
6. **Press Run.** The app installs and launches.
7. **Trust the developer certificate** (only with a free Apple ID, and only the first time):
   the phone will refuse to launch with "Untrusted Developer". On the phone go to
   **Settings → General → VPN & Device Management → Developer App →** your Apple ID **→
   Trust**. Then launch Aside again.
8. **Allow the microphone** when the app asks, and **allow notifications** (they are used
   for one message: "Aside session ended").
9. **Enable the keyboard**: on the phone, **Settings → General → Keyboard → Keyboards → Add
   New Keyboard… → Aside** (under THIRD-PARTY KEYBOARDS).
10. **Turn on Full Access**: tap **Aside** in that same Keyboards list and switch on **Allow
   Full Access**, then confirm. Without it the keyboard cannot read the shared folder and
   will say so instead of showing the mic button.
11. **Start your first session.** Open Aside, press **Start Session**. Now switch to any app
    with a text field, tap and hold the globe key (or tap it) to switch to **Aside**, and
    hold its mic button while you speak. Let go and the text appears.

If the keyboard says "Start a session", tap that line: it opens the app and starts one. iOS
has no API to send you back automatically — use the small back breadcrumb at the top left of
the status bar.

12. **Add the control** (optional): open Control Center, tap **+** at the top left, **Add a
    Control**, and pick **Aside Dictation**. It can also go on the Lock Screen, and on an
    iPhone with an Action button, Settings → Action Button → Controls → Aside Dictation.
    Tap it to record, tap again to stop; the text is copied and a notification shows it.
    Settings → Control Center chooses when iOS clears the copied text.

## Settings

- **Transcription** — *On this iPhone (Parakeet v3)*, the default, downloads a ~600 MB
  CoreML model once (Home and Settings show the download as it happens, file by file)
  and then runs offline on the Neural Engine; *a provider, directly* posts the audio
  straight to any OpenAI-compatible service with your own API key (the key goes to the
  keychain, never to `UserDefaults`). A provider running on your Mac needs a URL the phone
  can reach — `localhost` is the phone, not your Mac. The Mac app's Worker option does not
  exist on the phone.
- **Cleanup** — level (None / Light / Medium) and engine: Apple's on-device model (the
  default; needs iOS 26 and Apple Intelligence) or a direct provider. The dictionary
  post-pass always runs in Swift afterwards, exactly as on the Mac.
- Home refuses to record until the chosen engines can actually run — model downloaded,
  key present, Apple Intelligence available, microphone allowed — and says what is missing.
- **Session length** — 5 minutes, 15 minutes, 1 hour, or until you end it. When it expires
  the microphone is released and you get one notification.

The dictionary is the same JSON the Mac app writes, stored in the App Group container.

## How the hand-off works

Everything is files in the App Group container, so there is no cross-process caching
ambiguity, and every write is atomic:

| File | Written by | Contents |
| --- | --- | --- |
| `session.json` | app | `active`, `startedAt`, `expiresAt`, `pid` |
| `control.json` | app | `recording`: whether a control-started dictation is being recorded, for the toggle |
| `commands/<uuid>.json` | keyboard or control | `start` / `stop` / `cancel`, `source`, plus ~40 characters of text before the cursor (keyboard only) |
| `results/<uuid>.json` | app | `recording` / `processing` / `done` / `failed`, the text, timings (keyboard only; the control's text goes to the clipboard) |

The `start` command's id is the dictation's id and the key of its result file; `stop` and
`cancel` are separate commands that apply to whatever is in flight, since only one dictation
can be. Both sides post a Darwin notification (`com.codywright.aside.command`,
`com.codywright.aside.result`) to wake the other, and both also poll every 250 ms while a
dictation is in flight, because Darwin notifications are best-effort. Command and result
files older than 10 minutes are deleted when a session starts.

Nothing is buffered between dictations: the audio engine keeps running so the app stays
alive, but the converter output is dropped on the floor unless a dictation is actually in
flight. Transcripts are held in memory and the result file is deleted as soon as the
keyboard has read it.

## Known limits

- No streaming preview; the text arrives when you let go.
- Recent dictations are in memory only, so they are gone after the app is killed.
- The keyboard has no typing keys beyond space, backspace and return — switch keyboards with
  the globe for anything else.
- iOS gives no way to jump back to the app you came from; use the status-bar breadcrumb.
- A session ends if iOS kills the app under memory pressure. Start a new one from Home.
