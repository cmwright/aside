import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center extension: one toggle that starts a dictation and stops it.
///
/// Nothing outside a keyboard can type into another app, so a dictation started here ends
/// on the clipboard, with a notification showing the text. The extension itself never
/// records: it writes the same `start` / `stop` commands the keyboard writes into the App
/// Group and the app, kept alive by its session, does the work.
///
/// Requires iOS 26: the intent runs in the background while a session is alive and must
/// bring the app forward only when there is none. That "decide at run time" behaviour is
/// the `.foreground(.dynamic)` intent mode, new in 26. On 18 a control's intent either
/// always opens the app or never can, and `OpenURLIntent` does not honour custom schemes.
@main
struct AsideControlBundle: WidgetBundle {
    var body: some Widget {
        DictationControl()
    }
}

struct DictationControl: ControlWidget {
    static let kind = "com.codywright.aside.ios.control.dictation"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: DictationControlProvider()) { isRecording in
            ControlWidgetToggle(isOn: isRecording, action: ToggleDictationIntent()) {
                Label("Aside", systemImage: "mic.fill")
            } valueLabel: { isOn in
                Label(isOn ? "Listening" : "Dictate", systemImage: isOn ? "waveform" : "mic.fill")
            }
            .tint(.red)
        }
        .displayName("Aside Dictation")
        .description("Tap to record, tap again to transcribe and copy the text.")
    }
}

/// The toggle's state is whatever the app last wrote: on only while a dictation started
/// from this control is being recorded and the session behind it is still alive.
struct DictationControlProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let store = AsideIPCStore.appGroup() else { return false }
        return store.activeSession() != nil && (store.readControlState()?.recording ?? false)
    }
}

struct ToggleDictationIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Aside Dictation"
    static let description = IntentDescription(
        "Starts a dictation in Aside, or stops the one in progress and copies the text to the clipboard.")

    /// Background by default; the app is only brought forward when a session has to be
    /// started, because iOS will not let a backgrounded app begin recording.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Recording")
    var value: Bool

    func perform() async throws -> some IntentResult {
        guard let store = AsideIPCStore.appGroup() else { throw AsideIPCError.noContainer }
        try store.writeCommand(DictationCommand(action: value ? .start : .stop, source: .control))
        DarwinNotifier.post(AsideIPC.commandNotification)
        if value, store.activeSession() == nil, systemContext.currentMode.canContinueInForeground {
            // No session, so the app is not running with the microphone. Open it: on
            // becoming active it starts a session and adopts the command just written.
            try await continueInForeground(alwaysConfirm: false)
        }
        return .result()
    }
}
