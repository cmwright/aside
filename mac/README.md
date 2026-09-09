# Aside (macOS menu-bar app)

Hold a key, speak, let go — the text lands where your cursor is. The app records audio,
posts it to the Worker in `../worker`, and inserts what comes back.

## Build

```sh
cd mac
./build.sh          # generates the Xcode project, builds, prints the .app path
./run.sh            # build.sh, then opens the app
```

`build.sh` needs [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
It resolves one SPM dependency, [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts),
so the first build needs a network connection; after that the resolved copy is cached in
`mac/build`.

The app is menu-bar only (`LSUIElement`): there is no Dock icon and no main window. Look
for a microphone in the menu bar. The icon changes with state — `mic` idle, filled while
listening, a waveform while transcribing, a warning triangle after an error.

Unit tests (WAV header, multipart body, dictionary codec, URL normalization, the
leading-space rule, and the Right Option device-bit decision):

```sh
cd mac
DVT_PLUG_INS_TO_IGNORE=com.apple.dt.IDESimulatorFoundation \
  xcodebuild -project Aside.xcodeproj -scheme Aside \
  -destination 'platform=macOS,arch=arm64' test
```

`DVT_PLUG_INS_TO_IGNORE` is only needed on machines where `xcodebuild -runFirstLaunch`
has not been run since the last Xcode upgrade — without it xcodebuild refuses to start
because it cannot load the (unused, iOS-only) simulator plug-in. `build.sh` sets it for
you; it is harmless on a healthy install.

## Use

1. Start the Worker: `cd worker && npx wrangler dev` (defaults to `http://localhost:8787`).
2. Launch the app. On first run it asks for Microphone, triggers the Accessibility prompt
   and opens its **Permissions** window by itself; grant both there. You can reopen the
   window from the menu at any time.
3. Open **Settings…** if your backend is somewhere other than `http://localhost:8787`, or
   if the Worker has a `BACKEND_TOKEN`. **Test Connection** hits `GET /health`.
4. Hold **Right Option**, speak, let go. A "Listening" pill appears near the bottom of the
   screen, then "Transcribing", then the text is inserted.

**Dictionary…** holds words the transcriber should get right. A row with only a *Term*
teaches the spelling; adding a *Replacement* rewrites what was heard ("hyper comply" →
"HyperComply"). It is stored as JSON at
`~/Library/Application Support/Aside/dictionary.json` and can be imported/exported.

If you prefer a normal shortcut to hold-to-talk, record one in **Settings…**; it toggles
(press to start, press again to stop). You can also turn Right Option off there.

## Permissions, and the ad-hoc signing caveat

- **Microphone** — to record. macOS asks the first time.
- **Accessibility** — to see the Right Option key while another app is frontmost, and to
  put text at the cursor. macOS never asks on its own; use the button in **Permissions…**,
  or System Settings → Privacy & Security → Accessibility.

The app watches the Accessibility grant once a second for as long as it is missing, and
**re-arms the Right Option monitor by itself the moment the grant lands** — a global
key-event monitor installed while the process is untrusted never starts delivering events
on its own, so without that the trigger would stay dead until the next launch. You should
never have to relaunch the app after granting.

There is no code-signing identity here, so builds are **ad-hoc signed** and every rebuild
produces a different signature. macOS ties the Accessibility grant to the signature, so
after a rebuild the app will often appear in the Accessibility list but not actually be
trusted. Fix it by selecting Aside in System Settings → Privacy & Security →
Accessibility, pressing **–** to remove it, then adding the freshly built app again with
**+**. The Permissions window shows live status so you can tell when this has happened.

## How text gets inserted

Three tiers, in order:

1. **Accessibility** — writes into the focused element's selected-text attribute. Nothing
   touches your clipboard.
2. **Clipboard + Cmd+V** — the current pasteboard is copied out (all items, all types),
   the text is pasted, and the old contents are put back 400 ms later — but only if
   nothing else has written to the pasteboard in the meantime (`changeCount` is checked),
   so a slow app that has not consumed the paste yet, or a copy you made in that window,
   is never clobbered.
3. **Clipboard only** — if both fail, the text stays on the clipboard and the overlay says
   "Copied to clipboard; paste manually".

A leading space is added when the character before the cursor is a letter or digit and the
new text starts with a letter, so dictation does not glue onto the previous word. That one
character is read with the `AXStringForRange` parameterized attribute rather than by
copying the whole document, so a large editor buffer costs nothing; elements that do not
implement it fall back to reading the value only when it is under 4096 characters. When
the Accessibility API cannot read the surrounding text, no space is guessed.

## Files

| File | What it does |
| --- | --- |
| `Sources/App.swift` | `@main`, menu-bar item, windows, and `AppController` — the Right Option monitor and the record → post → insert flow |
| `Sources/Recorder.swift` | `AVAudioEngine` capture converted to 16 kHz mono Int16, WAV writer, 300 ms minimum |
| `Sources/BackendClient.swift` | The multipart `POST /v1/audio/transcriptions` contract and `GET /health` |
| `Sources/TextInserter.swift` | The three-tier insertion above |
| `Sources/Dictionary.swift`, `DictionaryView.swift` | Entries, JSON persistence, the table |
| `Sources/Settings.swift`, `SettingsView.swift` | `UserDefaults`-backed preferences |
| `Sources/Permissions.swift`, `PermissionsView.swift` | Live permission status and the System Settings links |
| `Sources/StatusOverlay.swift` | The non-activating floating status pill |
| `Sources/Log.swift` | `os.Logger`; transcripts are never logged |

## Known limits

- No streaming preview; text arrives after you release the key.
- Some apps (Terminal, Electron editors) do not expose a settable selected-text attribute,
  so those fall back to Cmd+V.
- Recording state is per-press; there is no cancel-while-holding gesture yet. A recording
  whose key-up never arrives (screen lock, secure input, sleep) is stopped and sent by a
  90 second watchdog.
