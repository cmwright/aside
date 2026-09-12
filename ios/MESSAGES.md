# Aside in Messages

Adds Aside to the Messages **+** menu. Opening the panel starts its own microphone capture after the extension becomes active. Speak when it says Listening. After two seconds of quiet, a three-second countdown appears in the status area. Speaking cancels the countdown; tapping **Keep recording** waits for another spoken phrase before rearming it. **Stop** finishes immediately. There is no fixed recording-duration cap in Messages; device resources, audio interruptions and provider limits still apply. Closing the panel cancels the work.

Audio uses the transcription and cleanup providers selected in the main iOS app, through the same `DictationPipeline` code. This includes local Parakeet or direct speech providers, Apple or direct cleanup, the selected models/base URLs, cleanup level, dictionary vocabulary hints, replacement pass, and the original off-script/Apple-declined fallback behavior. Settings and dictionary are snapshotted when recording starts, then the result is inserted into the Messages composer. The user sends the message. The panel does not read conversation history or the existing draft.

## Run

1. Follow `ios/README.md` to install XcodeGen and configure the ignored `ios/Signing.xcconfig`.
2. Run `./ios/build.sh` for an unsigned device compile, or generate the project and run the Aside scheme on a physical iPhone with your signing team. The new Messages bundle ID is `com.codywright.aside.ios.messages`; it uses the existing `group.com.codywright.aside` App Group. Register/sign this extension for your team as well.
3. Open the main Aside app once after upgrading. This migrates existing provider keys from its private keychain into the existing App Group keychain; secrets are never written to shared files or preferences. Choose your speech/cleanup providers in Settings. If using local transcription, let the local model become ready: it is copied from the old cache when available and otherwise downloaded into the shared container. Direct transcription does not load or require Parakeet.
4. Open Messages, tap **+**, find **Aside**, and allow microphone access. The main app’s recording session can be off.

## Scope and limitations

This branch contains the Messages integration and shared recorder/model/pipeline/keychain prerequisites. The original keyboard and app UI are preserved. It excludes the experimental QWERTY keyboard, selected-text cleanup, cleanup shortcuts, vocabulary suggestions, and Watch work.

Provider settings and fallback behavior match the iPhone app. Worker modes remain unsupported on iPhone, as upstream already specifies. Apple cleanup still requires a supported device and available model. Open the main app once to migrate existing API keys before trying direct providers in Messages. Keychain-sharing migration and live provider calls require on-device verification; mock routing checks do not establish those results.

Silence detection is based on audio energy, not semantic speech detection. Background noise or other voices can delay the countdown. Audio activation is retried briefly; interruptions cancel capture. The existing input-settling checks and shared speech-model cache also apply to the main iOS app. The macOS model-loading and keychain paths are unchanged.

Messages uses its own auto-start/countdown interaction instead of the main app’s tap-behavior preference. Start/stop tones are controlled by **Settings → Messages recording → Play start and stop sounds**, backed by the existing `playSounds` preference. The start tone finishes before transcript capture restarts; the stop tone plays after capture ends.

Completed, successfully inserted dictations are imported into **Recent** on the next main-app activation, including raw/final text, provider, and timing. This requires a saved **Recent → Keep history** period. **This launch only** keeps transcripts off disk, so Messages does not queue history in that mode. One atomic file per record in the App Group avoids concurrent history-array writes; the main app removes queued files only after a successful history save. Imports deduplicate by ID and prune expired records. Disabling persistence removes pending imports. No unfinished recording or recovery draft is saved.

Other differences: Capture is buffered and transcribed when it stops, with no live transcript. Cleanup has a 30-second watchdog and remote requests use the existing DirectClient timeout. Closing the extension cancels processing; there is no background recovery or saved draft after dismissal. These are separate from provider selection. The former 2,000-character cleanup restriction has been removed.

## Validation

The development prototype was built and installed on an iPhone; diagnostics confirmed captured audio, and the user confirmed recording and insertion. Compact and expanded layouts were checked in a simulator preview. Silence/countdown behavior has 17 synthetic checks, runnable using the instructions in `ios/scripts/check-messages-endpoint.swift`. Intermittent microphone activation received a lifecycle/retry fix, but repeated real-device startup reliability and the latest countdown interaction still need hands-on confirmation.

Run `ios/scripts/check-provider-routing.sh` on a Mac with Xcode for offline routing checks. These compile the production settings resolver, pipeline, HTTP client, prompt, dictionary, and cleanup fallback, with mock network responses and test-only local-model/keychain stand-ins. They cover selected hosts/models, snapshot stability, authorization, direct/local dispatch, missing credentials, no-cleanup mode, off-script fallback, history import/persistence, duplicate retries, retention expiry, memory-only behavior, and failed-write recovery. The isolated iOS branch builds unsigned; the signed prototype also needs live provider and key-sharing verification.

Before merging, test with the main app session off: first launch/model preparation, repeated panel opens, permission denial, initial silence, short pauses, all three countdown numbers, speech during countdown, Keep recording, manual Stop, panel dismissal while preparing/transcribing, insertion without sending, start/stop sounds on and off, recording past 90 seconds, and Messages results appearing in Recent with a saved retention period. Also check Bluetooth routes and main app recording after these shared recorder changes.
