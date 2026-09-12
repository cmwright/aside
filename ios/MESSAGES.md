# Aside in Messages

Adds Aside to the Messages **+** menu. Opening the panel starts its own microphone capture after the extension becomes active. Speak when it says Listening. After two seconds of quiet, a three-second countdown appears in the status area. Speaking cancels the countdown; tapping **Keep recording** waits for another spoken phrase before rearming it. **Stop** finishes immediately. Recordings are capped at 90 seconds, and closing the panel cancels the work.

Audio is transcribed locally with Aside’s existing Parakeet engine, then passed through the existing Apple cleanup and dictionary replacement before insertion into the Messages composer. The user sends the message. The panel does not read conversation history or the existing draft.

## Run

1. Follow `ios/README.md` to install XcodeGen and configure the ignored `ios/Signing.xcconfig`.
2. Run `./ios/build.sh` for an unsigned device compile, or generate the project and run the Aside scheme on a physical iPhone with your signing team. The new Messages bundle ID is `com.codywright.aside.ios.messages`; it uses the existing `group.com.codywright.aside` App Group. Register/sign this extension for your team as well.
3. Open the main Aside app and let the local speech model become ready. The model is copied from the old cache when available and otherwise downloaded into the shared container. The extension never downloads it independently.
4. Open Messages, tap **+**, find **Aside**, and allow microphone access. The main app’s recording session can be off.

## Scope and limitations

This branch contains only the Messages integration and its shared recorder/model prerequisites. The original keyboard and app UI are preserved. It excludes the experimental QWERTY keyboard, selected-text cleanup, cleanup shortcuts, vocabulary suggestions, and Watch work.

The Messages pipeline uses local Parakeet and Apple on-device cleanup. It does not honor direct/cloud provider choices; Apple cleanup requires a supported device and available model. Cleanup level and dictionary come from the shared app settings. `CleanupLevel` is moved unchanged into a standalone file so the extension need not compile the full settings UI.

Silence detection is based on audio energy, not semantic speech detection. Background noise or other voices can delay the countdown. **Keep recording** does not remove the 90-second limit. Audio activation is retried briefly; interruptions cancel capture. The existing input-settling checks and shared speech-model cache also apply to the main iOS app. The macOS model-loading path is unchanged.

## Validation

The development prototype was built and installed on an iPhone; diagnostics confirmed captured audio, and the user confirmed recording and insertion. Compact and expanded layouts were checked in a simulator preview. Silence/countdown behavior has 17 synthetic checks, runnable using the instructions in `ios/scripts/check-messages-endpoint.swift`. Intermittent microphone activation received a lifecycle/retry fix, but repeated real-device startup reliability and the latest countdown interaction still need hands-on confirmation.

Before merging, test with the main app session off: first launch/model preparation, repeated panel opens, permission denial, initial silence, short pauses, all three countdown numbers, speech during countdown, Keep recording, manual Stop, panel dismissal while preparing/transcribing, and insertion without sending. Also check Bluetooth routes and main app recording after these shared recorder changes.
