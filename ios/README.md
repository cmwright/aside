# Aside for iPhone

A dictation keyboard. Hold the mic key in the Aside keyboard, speak, let go — the text
lands at your cursor in whatever app you were typing in.

An iOS keyboard extension **cannot use the microphone**. That has been true since iOS 8 and
is still true in iOS 26, with or without Full Access. So the work is split:

- the **app** owns the microphone, runs Parakeet v3 on the phone (or posts to the Worker),
  runs cleanup on Apple's on-device model (or at the Worker), and applies your dictionary;
- the **keyboard** writes a one-line command into a shared App Group folder, waits for the
  answer, and pastes it.

Keeping the app's audio engine running is what keeps it alive in the background, so after
one app switch per session every dictation is keyboard-only: tap, speak, tap, text appears.

```
ios/
  project.yml        xcodegen spec: app target Aside, extension target AsideKeyboard
  build.sh           generic-iOS-device compile check, no signing
  Shared/AsideIPC.swift    the hand-off protocol, unit-tested from the Mac test target
  App/               the app: session engine, recorder, pipeline, four screens
  Keyboard/          the keyboard extension: status line, mic button, four keys
  Tests/             AsideIPCTests.swift (runs in the Mac test target — see below)
```

Everything platform-neutral is shared with the Mac app by reference, never copied:
`Log.swift`, `Settings.swift`, `Dictionary.swift`, `DictionaryReplacer.swift`,
`CleanupPrompt.swift`, `BackendClient.swift`, `AppleCleanup.swift`, `LocalTranscriber.swift`,
`Providers.swift`, `APIKeyStore.swift`, `DirectClient.swift` in the app, and `Trigger.swift`
in the keyboard. See `../mac/Sources`.

## Build

```sh
cd ios
./build.sh
```

That runs `xcodegen generate` and compiles **both** targets for `generic/platform=iOS` with
`CODE_SIGNING_ALLOWED=NO`. There is no usable iOS simulator runtime on this machine, so
this compile is the automated verification. It needs a network connection the first time,
to resolve FluidAudio into `ios/build`.

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
3. **Plug in the iPhone**, unlock it, and pick it in Xcode's run destination menu. Trust the
   computer if the phone asks.
4. Check both targets in Signing & Capabilities: **Aside** and **AsideKeyboard** should each
   show "Automatically manage signing", your team, and the App Group
   `group.com.codywright.aside` with a filled checkbox. Xcode registers the group with Apple
   the first time; if it shows a warning triangle press **Try Again**.
5. **Press Run.** The app installs and launches.
6. **Trust the developer certificate** (only with a free Apple ID, and only the first time):
   the phone will refuse to launch with "Untrusted Developer". On the phone go to
   **Settings → General → VPN & Device Management → Developer App →** your Apple ID **→
   Trust**. Then launch Aside again.
7. **Allow the microphone** when the app asks, and **allow notifications** (they are used
   for one message: "Aside session ended").
8. **Enable the keyboard**: on the phone, **Settings → General → Keyboard → Keyboards → Add
   New Keyboard… → Aside** (under THIRD-PARTY KEYBOARDS).
9. **Turn on Full Access**: tap **Aside** in that same Keyboards list and switch on **Allow
   Full Access**, then confirm. Without it the keyboard cannot read the shared folder and
   will say so instead of showing the mic button.
10. **Start your first session.** Open Aside, press **Start Session**. Now switch to any app
    with a text field, tap and hold the globe key (or tap it) to switch to **Aside**, and
    hold its mic button while you speak. Let go and the text appears.

If the keyboard says "Start a session", tap that line: it opens the app and starts one. iOS
has no API to send you back automatically — use the small back breadcrumb at the top left of
the status bar.

## Settings

- **Transcription** — three ways, the same three the Mac app has:
  *On this iPhone (Parakeet v3)* downloads a ~600 MB CoreML model once and then runs
  offline on the Neural Engine; *a provider, directly* posts the audio straight to any
  OpenAI-compatible service with your own API key (the key goes to the keychain, never to
  `UserDefaults`); *the Worker* posts to your self-hosted backend. The Worker and any
  local provider need a URL the phone can actually reach — `localhost` is the phone, not
  your Mac, so use the Mac's LAN address or a deployed Worker.
- **Cleanup** — level (None / Light / Medium) and engine: a direct provider, Apple's
  on-device model (needs iOS 26 and Apple Intelligence), or the Worker. The dictionary
  post-pass always runs in Swift afterwards, exactly as on the Mac.
- **Session length** — 5 minutes, 15 minutes, 1 hour, or until you end it. When it expires
  the microphone is released and you get one notification.

The dictionary is the same JSON the Mac app writes, stored in the App Group container.

## How the hand-off works

Everything is files in the App Group container, so there is no cross-process caching
ambiguity, and every write is atomic:

| File | Written by | Contents |
| --- | --- | --- |
| `session.json` | app | `active`, `startedAt`, `expiresAt`, `pid` |
| `commands/<uuid>.json` | keyboard | `start` / `stop` / `cancel`, plus ~40 characters of text before the cursor |
| `results/<uuid>.json` | app | `recording` / `processing` / `done` / `failed`, the text, timings |

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
