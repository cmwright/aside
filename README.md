# Aside

Push-to-talk dictation for Mac and iPhone that you control end to end. Hold a key, speak,
let go: clean text lands at your cursor in whatever app you are in. Speech can be
transcribed entirely on your Mac, and the cleanup pass can run on Apple's on-device model
or on any OpenAI-compatible provider with your own API key. No account, no telemetry,
no server in the middle unless you want one.

- **`mac/`** — the menu-bar app for macOS 14+, Apple Silicon. Notarized releases under
  [Releases](https://github.com/cmwright/aside/releases); updates arrive through Sparkle.
- **`ios/`** — the iPhone app plus a tiny dictation keyboard. See [`ios/README.md`](ios/README.md).
- **`worker/`** — an optional self-hosted backend (a Cloudflare Worker) for teams that
  want one place to hold keys and configuration. Not needed for personal use. See
  [`worker/README.md`](worker/README.md).

MIT licensed. Apple Silicon only.

## Install

Download `Aside-<version>.zip` from the latest release, unzip, drag `Aside.app` to
Applications, open it. It has no Dock icon; look for a text cursor with two sound arcs
in the menu bar. It checks for updates once a day and has **Check for Updates…** in its menu.

To build from source instead: `brew install xcodegen`, then `./mac/run.sh`. Details and
signing notes are in [`mac/README.md`](mac/README.md).

## First run

1. **Permissions.** The app asks for the Microphone and opens its Permissions window for
   Accessibility (System Settings → Privacy & Security → Accessibility, switch Aside on).
   Accessibility is what lets it see the Right Option key and type into other apps. It
   notices the grant by itself; no relaunch needed.
2. **Pick your engines** in Settings → Engines. The defaults work with nothing but
   a Groq key; the fully offline setup needs no key at all.

| Stage | Options | Notes |
| --- | --- | --- |
| Speech to text | **On this Mac** (NVIDIA Parakeet v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio)) · **A provider, directly** (Groq, Fireworks, OpenAI, or any OpenAI-compatible URL) · The Worker | Parakeet downloads about 470 MB once and runs on the Neural Engine while you are still holding the key. Audio never leaves the Mac. |
| Cleanup | **A provider, directly** (Cerebras, Groq, Fireworks, OpenAI, Ollama, or custom) · **Apple on-device model** (macOS 26 with Apple Intelligence on) · The Worker · None | Cleanup fixes punctuation and capitalization, drops fillers and false starts at the Medium level, and applies your dictionary. It is told never to add content or answer a question that appears in the transcript. |

API keys go in Settings → Providers and are stored in your login keychain. The
**Test** button confirms the key and model. Everything the app has (General, Engines,
Providers, Dictionary, Recent Dictations, Permissions) lives in one window with a sidebar. Choosing Parakeet plus the Apple model means
nothing leaves the machine; choosing Parakeet plus a provider sends only the transcript.

3. **Dictate.** Hold **Right Option**, speak, release. Double-tap it to keep listening
   hands-free, then tap once to stop. A pill near the bottom of the screen shows Listening,
   Transcribing, then the text appears at your cursor. The trigger key is changeable in
   Settings.

If cleanup fails (provider down, rate-limited, no connection) the app retries once and
then inserts the raw transcript with your dictionary applied, and the pill says so. A
dictation that takes more than a minute end to end is given up on with a message rather
than left hanging; **Cancel Dictation** in the menu does the same by hand.

The key is watched through a session event tap. macOS sometimes switches a tap off
across sleep or when it thinks the process was slow; the app notices, re-enables it, and
also rebuilds it on every wake, so a dead key after sleep no longer needs a relaunch.

If Right Option still does nothing, open the menu: a line there says when another
app has turned on secure keyboard entry, which blocks every global key monitor on the
Mac. A password field does that briefly and is harmless; a login window or terminal
that keeps it on after the screen unlocks is what wedges the key. Locking and unlocking
the screen, or quitting that app, releases it.

## Dictionary

Under **Dictionary…**, add the words transcription gets wrong: a *term* ("acme cloud")
with an optional *replacement* ("AcmeCloud"). Terms are passed to the speech model as
vocabulary hints, given to the cleanup model as instructions, and, for entries with a
replacement, applied once more as a deterministic case-insensitive, word-boundary-safe
substitution so the replacement lands even if the model misses it. It also catches the
speech model joining the words ("acmecloud").

## Recent Dictations

**Recent Dictations…** in the menu shows the last 50: what the speech model heard, what
was pasted after cleanup, which engines ran, and how long each stage took. It lives in
memory only. A toggle appends each dictation as a JSON line to
`~/Library/Logs/Aside/dictations.jsonl` if you want to `tail -f` while comparing engines.

## Privacy

Everything the app records stays on the Mac unless you choose a cloud engine. With a
cloud engine, audio or text goes only to that provider, signed with your own key; check
the provider's retention policy. The app logs timings and engine names to the system log,
never transcript text. Nothing is sent to us; there is no "us".

## Insertion

Text is written into the focused field through the Accessibility API, and the cursor is
read back afterwards to confirm the text actually landed: Chromium-based apps such as
Slack accept the write and silently drop it. If the app in front doesn't support that
route (some terminals, some Electron apps), Aside pastes instead, saving and restoring
your clipboard. If both fail, the text is left on the clipboard and the pill says so.

## Developing

```sh
./mac/build.sh                       # xcodegen generate + xcodebuild (Debug, prints the .app path)
./mac/run.sh                         # build and launch
cd mac && DVT_PLUG_INS_TO_IGNORE=com.apple.dt.IDESimulatorFoundation \
  xcodebuild -project Aside.xcodeproj -scheme Aside -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build test        # unit tests, including the iOS hand-off protocol
```

Releases: `./mac/release.sh` builds, signs with Developer ID, notarizes, staples, and
writes a Sparkle appcast; `./mac/publish.sh <version>` uploads both to a GitHub Release.
Signing setup is in [`mac/README.md`](mac/README.md).

## Known limitations

- No streaming preview of the text while you speak; it appears when you release the key.
- A recording that never sees a key-up (screen lock, sleep) is stopped and sent after 90 s.
- The Apple on-device cleanup model is timid at the Medium level and slower than the fast
  cloud hosts on older Apple Silicon.
- The iPhone app is installed from Xcode onto your own device; there is no TestFlight build yet.
- Cannot ship on the Mac App Store: the Accessibility API requires the App Sandbox off.
