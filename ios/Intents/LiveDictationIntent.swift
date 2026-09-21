import AppIntents
import Foundation

@available(iOS 26.0, *)
struct LiveDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Control Aside recording"
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    @Parameter(title: "Start recording") var recording: Bool
    @Parameter(title: "Recording identifier") var recordingID: String?

    init() {}
    init(recording: Bool, recordingID: String?) {
        self.recording = recording
        self.recordingID = recordingID
    }

    func perform() async throws -> some IntentResult {
        guard let store = AsideIPCStore.appGroup() else { throw AsideIPCError.noContainer }
        // An expired activity must not stop a newer recording.
        let id = recordingID.flatMap(UUID.init(uuidString:))
        guard recording || id != nil else { return .result() }
        try store.writeCommand(DictationCommand(action: recording ? .start : .stop,
            source: .control, dictationID: recording ? nil : id))
        DarwinNotifier.post(AsideIPC.commandNotification)
        if recording, store.activeSession() == nil {
            try await continueInForeground(alwaysConfirm: false)
        }
        return .result()
    }
}
