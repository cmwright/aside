import AppIntents
import SwiftUI
import WidgetKit

/// The Control Center extension: one toggle that starts a dictation and stops it.
///
/// Nothing outside a keyboard can type into another app, so a dictation started here ends
/// on the clipboard, with a notification showing the text. The extension itself never
/// records: it writes the same `start` / `stop` commands the keyboard writes into the App
/// Group and the app, kept alive by its session, does the work. Requires iOS 18.2.
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

    @Parameter(title: "Recording")
    var value: Bool

    /// Both branches must produce one concrete result type, so it is named: the plain
    /// container, which `.result()` and the non-generic `.result(opensIntent:)` both return.
    typealias Outcome = IntentResultContainer<Never, Never, Never, Never>

    func perform() async throws -> Outcome {
        guard let store = AsideIPCStore.appGroup() else { throw AsideIPCError.noContainer }
        try store.writeCommand(DictationCommand(action: value ? .start : .stop, source: .control))
        DarwinNotifier.post(AsideIPC.commandNotification)
        if value, store.activeSession() == nil {
            // Without a session the app is not running with the microphone, and iOS will not
            // let it start recording from the background. Open it: it starts a session and
            // picks up the command just written.
            return Outcome.result(opensIntent: OpenURLIntent(URL(string: "aside://control/start")!))
        }
        return Outcome.result()
    }
}
