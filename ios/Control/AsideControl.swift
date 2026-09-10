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
        if #available(iOS 26.0, *) {
            DictationControl()
        }
    }
}

@available(iOS 26.0, *)
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
