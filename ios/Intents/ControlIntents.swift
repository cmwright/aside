import AppIntents
import Foundation

/// The Control Center toggle's intent. Compiled into the app as well as the control
/// extension: the system resolves an intent by type in whichever process it runs it in,
/// and a control that has to open its app needs the app to know the intent.
///
/// It runs in the background while a session is alive and brings the app forward only
/// when there is none, because iOS will not let a backgrounded app begin recording. That
/// "decide at run time" behaviour is the `.foreground(.dynamic)` intent mode, new in
/// iOS 26; on 18 a control's intent either always opens the app or never can.
@available(iOS 26.0, *)
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
        var trace = ControlTrace(value: value, process: ProcessInfo.processInfo.processName)
        defer { trace.write() }
        guard let store = AsideIPCStore.appGroup() else {
            trace.outcome = "no app group container"
            throw AsideIPCError.noContainer
        }
        try store.writeCommand(DictationCommand(action: value ? .start : .stop, source: .control))
        DarwinNotifier.post(AsideIPC.commandNotification)
        trace.sessionActive = store.activeSession() != nil
        trace.canContinueInForeground = systemContext.currentMode.canContinueInForeground
        trace.mode = String(describing: systemContext.currentMode)
        guard value, store.activeSession() == nil else {
            trace.outcome = "background"
            return .result()
        }
        // No session, so the app is not running with the microphone. Open it: on becoming
        // active it starts a session and adopts the command just written.
        do {
            try await continueInForeground(alwaysConfirm: false)
            trace.outcome = "continued in foreground"
        } catch {
            trace.outcome = "continueInForeground failed: \(error)"
            throw error
        }
        return .result()
    }
}

/// For Shortcuts, the Action button and Siri: the same toggle, but the stopping run waits
/// for the transcript and returns it, so a two-action shortcut — Dictate with Aside, then
/// Copy to Clipboard — puts the text on the clipboard without any app coming forward.
/// Shortcuts may write the clipboard from the background; Aside itself may not.
@available(iOS 26.0, *)
struct DictateIntent: AppIntent {
    static let title: LocalizedStringResource = "Dictate with Aside"
    static let description = IntentDescription(
        "Starts recording. Run it again to stop: it then transcribes and returns the text. Follow it with Copy to Clipboard.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    /// How long the stopping run waits for the app to transcribe and clean up.
    static let resultTimeout: TimeInterval = 90

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let store = AsideIPCStore.appGroup() else { throw AsideIPCError.noContainer }
        let state = store.readControlState()
        let recording = store.activeSession() != nil && (state?.recording ?? false)
        guard recording, let id = state?.dictationID else {
            try store.writeCommand(DictationCommand(action: .start, source: .control))
            DarwinNotifier.post(AsideIPC.commandNotification)
            if store.activeSession() == nil, systemContext.currentMode.canContinueInForeground {
                try await continueInForeground(alwaysConfirm: false)
            }
            return .result(value: "")
        }
        try store.writeCommand(DictationCommand(action: .stop, source: .control))
        DarwinNotifier.post(AsideIPC.commandNotification)
        let deadline = Date().addingTimeInterval(DictateIntent.resultTimeout)
        while Date() < deadline {
            if let result = store.readResult(id: id), result.isFinal {
                store.removeResult(id: id)
                if result.status == .failed { throw DictateError.failed(result.error ?? "unknown error") }
                return .result(value: result.text ?? "")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DictateError.timedOut
    }

    enum DictateError: LocalizedError {
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .failed(let why): return "Aside could not transcribe: \(why)"
            case .timedOut: return "Aside did not finish transcribing in time."
            }
        }
    }
}

/// `control-trace.json` in the App Group: what the last tap of the control did, for
/// diagnosing a control that appears to do nothing. Overwritten on every run.
struct ControlTrace: Codable {
    var at = Date()
    var value: Bool
    var process: String
    var sessionActive = false
    var canContinueInForeground = false
    var mode = ""
    var outcome = "perform did not finish"

    static var url: URL? { AsideIPC.containerURL()?.appendingPathComponent("control-trace.json") }

    func write() {
        guard let url = ControlTrace.url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read() -> ControlTrace? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ControlTrace.self, from: data)
    }

    /// One line for the Settings screen.
    var summary: String {
        let time = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .medium)
        return "Last tap \(time): \(value ? "start" : "stop") in \(process); session \(sessionActive ? "active" : "none"); mode \(mode.isEmpty ? "?" : mode); can continue in foreground: \(canContinueInForeground ? "yes" : "no"); \(outcome)."
    }
}
