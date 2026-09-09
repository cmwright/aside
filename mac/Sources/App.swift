import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    /// Optional press-to-start / press-to-stop combo. The default trigger is holding
    /// Right Option, handled by a flagsChanged monitor instead.
    static let toggleDictation = Self("toggleDictation")
}

enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case failed(String)

    var menuTitle: String {
        switch self {
        case .idle: return "Ready"
        case .recording: return "Listening…"
        case .processing: return "Transcribing…"
        case .failed(let message): return message
        }
    }
}

/// Ties the trigger, the recorder, the backend and the inserter together. Everything here
/// is main-actor; the only off-main work is the audio tap inside `Recorder`.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    /// Right Option. `kVK_RightOption` = 0x3D.
    nonisolated static let rightOptionKeyCode: UInt16 = 61

    /// `NX_DEVICERALTKEYMASK` from `<IOKit/hidsystem/IOLLEvent.h>`. AppKit puts the
    /// device-specific modifier bits in the low half of `modifierFlags.rawValue`, and this
    /// one is set only while the *right* Option key is physically down. The generic
    /// `.option` bit stays set while the left Option key is held, which is why we cannot
    /// use it to decide whether the right one just came up.
    nonisolated static let rightOptionDeviceMask: UInt = 0x40

    /// A recording that runs this long without a key-up is assumed to be wedged (screen
    /// lock, secure input, sleep, a dropped monitor) and is stopped for the user.
    nonisolated static let maximumRecordingSeconds: Double = 90

    @Published private(set) var state: DictationState = .idle
    @Published private(set) var lastText: String = ""
    /// One line for the menu: which engine handled the last dictation and how long it took.
    @Published private(set) var lastRunSummary: String = ""

    private let recorder = Recorder()
    private let client = BackendClient()
    private let settings = AppSettings.shared
    private let dictionary = DictionaryStore.shared

    private var flagsMonitors: [Any] = []
    private var capturedAppName: String?
    private var rightOptionDown = false
    private var trigger = TriggerLogic()
    private var tapWindowTask: Task<Void, Never>?
    private var accessibilityCancellable: AnyCancellable?
    private var accessibilityGranted = false
    private var watchdog: Task<Void, Never>?

    private init() {}

    // MARK: - Trigger wiring

    func startMonitoring() {
        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            self?.toggle()
        }
        installFlagsMonitors()

        let permissions = Permissions.shared
        permissions.refresh()
        accessibilityGranted = permissions.accessibility == .granted
        if !accessibilityGranted {
            Log.app.error("Accessibility not granted; the hold-to-talk monitor will not see key events until it is")
        }
        // A global key-event monitor installed while the process is untrusted never starts
        // delivering events, not even after the grant lands. Watch the permission and
        // re-install the monitors the moment it flips, so the first run (and every re-grant
        // after an ad-hoc rebuild) works without relaunching the app.
        accessibilityCancellable = permissions.$accessibility
            .removeDuplicates()
            .sink { state in
                MainActor.assumeIsolated { AppController.shared.accessibilityChanged(to: state) }
            }
    }

    private func accessibilityChanged(to state: Permissions.State) {
        let granted = state == .granted
        defer { accessibilityGranted = granted }
        guard granted, !accessibilityGranted else { return }
        Log.app.info("Accessibility granted; re-installing the hold-to-talk monitors")
        reinstallFlagsMonitors()
    }

    private func reinstallFlagsMonitors() {
        for monitor in flagsMonitors { NSEvent.removeMonitor(monitor) }
        flagsMonitors.removeAll()
        installFlagsMonitors()
    }

    /// A global monitor sees Right Option while another app is frontmost; the local one
    /// covers the case where one of our own windows has focus. Both need Accessibility.
    private func installFlagsMonitors() {
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { event in
            MainActor.assumeIsolated { AppController.shared.handleFlagsChanged(event) }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
            MainActor.assumeIsolated { AppController.shared.handleFlagsChanged(event) }
            return event
        }
        flagsMonitors = [global, local].compactMap { $0 }
    }

    /// Pure decision, split out so it can be unit-tested: is the *right* Option key down?
    /// `eventFlags` is `NSEvent.modifierFlags.rawValue` from the flagsChanged event;
    /// `liveFlags` is the current hardware state (`NSEvent.modifierFlags`), used only to
    /// veto a stale "still down" when no Option key is held any more.
    nonisolated static func rightOptionIsDown(
        eventFlags: UInt,
        liveFlags: NSEvent.ModifierFlags
    ) -> Bool {
        guard eventFlags & rightOptionDeviceMask != 0 else { return false }
        return liveFlags.contains(.option)
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard settings.holdRightOption, event.keyCode == AppController.rightOptionKeyCode else { return }
        let isDown = AppController.rightOptionIsDown(
            eventFlags: event.modifierFlags.rawValue,
            liveFlags: NSEvent.modifierFlags
        )
        Log.app.debug("flagsChanged right-option down=\(isDown, privacy: .public)")
        guard isDown != rightOptionDown else { return }
        rightOptionDown = isDown
        trigger.doubleTapWindow = settings.doubleTapToLatch ? TriggerLogic().doubleTapWindow : 0
        let action = isDown ? trigger.keyDown(at: event.timestamp) : trigger.keyUp(at: event.timestamp)
        perform(action)
    }

    private func perform(_ action: TriggerLogic.Action) {
        switch action {
        case .start:
            beginRecording()
        case .send, .stopLatched:
            endRecordingAndSend()
        case .tapPending:
            // Keep recording so a double-tap loses no audio; decide when the window closes.
            tapWindowTask?.cancel()
            let window = trigger.doubleTapWindow
            tapWindowTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(window))
                guard !Task.isCancelled else { return }
                let controller = AppController.shared
                controller.perform(controller.trigger.tapWindowExpired())
            }
        case .latch:
            tapWindowTask?.cancel()
            guard recorder.isRecording else { trigger.reset(); return }
            StatusOverlay.shared.show("Listening — tap Right Option to stop", tone: .listening)
        case .discard:
            recorder.cancel()
            cancelWatchdog()
            state = .idle
            StatusOverlay.shared.hide()
        case .ignore:
            break
        }
    }

    // MARK: - Recording

    func toggle() {
        if recorder.isRecording {
            endRecordingAndSend()
        } else {
            beginRecording()
        }
    }

    func beginRecording() {
        guard !recorder.isRecording, state != .processing else { return }
        capturedAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        do {
            try recorder.start()
            state = .recording
            // Without Accessibility we can still record, but insertion will fall all the way
            // back to the clipboard — say so instead of surprising the user later.
            StatusOverlay.shared.show(
                accessibilityGranted
                    ? "Listening"
                    : "Listening — Accessibility not granted, open Permissions… or the text only reaches the clipboard",
                tone: .listening
            )
            startWatchdog()
            play(.start)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// If the key-up is never delivered (screen lock, secure input field, sleep, a monitor
    /// that stopped firing) the engine would record forever. Stop it ourselves.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppController.maximumRecordingSeconds))
            guard !Task.isCancelled else { return }
            let controller = AppController.shared
            guard controller.recorder.isRecording else { return }
            Log.app.error("Recording hit the \(Int(AppController.maximumRecordingSeconds), privacy: .public)s watchdog; stopping it")
            controller.rightOptionDown = false
            controller.endRecordingAndSend()
        }
    }

    private func cancelWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    func endRecordingAndSend() {
        guard recorder.isRecording else { return }
        tapWindowTask?.cancel()
        trigger.reset()
        cancelWatchdog()
        let audio: Data
        do {
            audio = try recorder.stop()
        } catch RecorderError.tooShort {
            state = .idle
            StatusOverlay.shared.hide()
            return
        } catch {
            fail(error.localizedDescription)
            return
        }

        play(.stop)
        state = .processing

        if settings.transcriptionMode == .local {
            transcribeLocally(audio)
            return
        }

        StatusOverlay.shared.show("Transcribing", tone: .working)

        guard let baseURL = settings.backendURL else {
            fail(BackendError.badURL.localizedDescription)
            return
        }

        let request = TranscriptionRequest(
            baseURL: baseURL,
            token: settings.trimmedToken,
            audio: audio,
            dictionaryJSON: DictionaryCodec.encodeForRequest(dictionary.entries),
            cleanup: settings.cleanup,
            appName: capturedAppName
        )
        let client = self.client

        Task { @MainActor in
            do {
                let response = try await client.transcribe(request)
                self.finish(with: response, engine: .cloud)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    /// On-device Parakeet, then the Worker's text-only cleanup route unless nothing
    /// server-side would change the text.
    private func transcribeLocally(_ audio: Data) {
        let transcriber = LocalTranscriber.shared
        StatusOverlay.shared.show(
            transcriber.state == .ready ? "Transcribing on this Mac" : "Loading speech model (first time takes a while)",
            tone: .working
        )
        let pcm = WAV.pcm16(fromFile: audio)
        let needsServer = settings.cleanup != .none || dictionary.entries.contains { $0.wire.replacement != nil }
        let baseURL = settings.backendURL
        let token = settings.trimmedToken
        let dictionaryJSON = DictionaryCodec.encodeForRequest(dictionary.entries)
        let cleanup = settings.cleanup
        let appName = capturedAppName
        let client = self.client

        Task { @MainActor in
            do {
                let started = Date()
                let raw = try await transcriber.transcribe(pcm16: pcm)
                let sttMs = Date().timeIntervalSince(started) * 1000
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || !needsServer {
                    self.finish(with: TranscriptionResponse(
                        text: trimmed, rawText: raw,
                        timing: .init(stt: sttMs, cleanup: 0, total: sttMs)), engine: .local)
                    return
                }
                guard let baseURL else {
                    self.fail(BackendError.badURL.localizedDescription)
                    return
                }
                StatusOverlay.shared.show("Cleaning up", tone: .working)
                var response = try await client.cleanup(CleanupRequest(
                    baseURL: baseURL, token: token, text: raw,
                    dictionaryJSON: dictionaryJSON, cleanup: cleanup, appName: appName))
                if let timing = response.timing {
                    response.timing = .init(stt: sttMs, cleanup: timing.cleanup, total: sttMs + timing.total)
                }
                self.finish(with: response, engine: .local)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func finish(with response: TranscriptionResponse, engine: TranscriptionMode) {
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = text
        guard !text.isEmpty else {
            state = .idle
            StatusOverlay.shared.flash("Nothing was said", tone: .failure)
            return
        }
        let outcome = TextInserter.insert(text)
        if let message = outcome.userMessage {
            state = .failed(message)
            StatusOverlay.shared.flash(message, tone: .failure)
            resetStateSoon()
        } else {
            state = .idle
            StatusOverlay.shared.hide()
        }
        let engineLabel = engine == .local ? "on this Mac (Parakeet v3)" : "cloud (Worker)"
        if let timing = response.timing {
            let cleanupPart = timing.cleanup > 0 ? ", cleanup \(Int(timing.cleanup)) ms" : ", no cleanup call"
            lastRunSummary = "Last: \(engineLabel), speech \(Int(timing.stt)) ms\(cleanupPart)"
            // .notice persists in the unified log, so `log show` can answer "which engine ran?" later.
            Log.app.notice("Done via \(engineLabel, privacy: .public): stt \(Int(timing.stt), privacy: .public) ms, cleanup \(Int(timing.cleanup), privacy: .public) ms, \(text.count, privacy: .public) chars")
        } else {
            lastRunSummary = "Last: \(engineLabel)"
            Log.app.notice("Done via \(engineLabel, privacy: .public), \(text.count, privacy: .public) chars")
        }
    }

    private func fail(_ message: String) {
        cancelWatchdog()
        rightOptionDown = false
        recorder.cancel()
        state = .failed(message)
        StatusOverlay.shared.flash(message, tone: .failure, after: 4)
        Log.app.error("\(message, privacy: .public)")
        resetStateSoon()
    }

    private func resetStateSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .failed = self.state { self.state = .idle }
        }
    }

    /// Puts the last transcript back on the clipboard, for when insertion went somewhere odd.
    func copyLastToClipboard() {
        guard !lastText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastText, forType: .string)
    }

    private enum Cue { case start, stop }

    private func play(_ cue: Cue) {
        guard settings.playSounds else { return }
        let name = cue == .start ? "Tink" : "Pop"
        NSSound(named: name)?.play()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            AppController.shared.startMonitoring()
            askForMissingPermissions()
            if AppSettings.shared.transcriptionMode == .local {
                LocalTranscriber.shared.prepare()
            }
            Log.app.info("Aside launched")
        }
    }

    /// First run must not be silent: without Microphone there is no audio, and without
    /// Accessibility the Right Option monitor never fires, so "hold the key and speak"
    /// would do nothing at all with no visible explanation.
    @MainActor
    private func askForMissingPermissions() {
        let permissions = Permissions.shared
        permissions.refresh()
        if permissions.microphone == .notDetermined {
            permissions.requestMicrophone()
        }
        guard permissions.accessibility != .granted else { return }
        // Shows the system "Open System Settings" alert, then our own checklist so the user
        // can see the status flip to Granted without hunting for the menu-bar icon.
        permissions.requestAccessibility()
        permissions.showWindow()
    }
}

@main
struct AsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var dictionary = DictionaryStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(nsImage: AsideIcon.menuBarImage(for: controller.state))
                .accessibilityLabel("Aside")
        }

        Window("Dictionary", id: WindowID.dictionary) {
            DictionaryView()
                .environmentObject(dictionary)
                // Without an ideal height the Table reports an unbounded one, the window
                // opens taller than the screen, and macOS then remembers that frame.
                .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 420)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 420)
        .defaultPosition(.center)

        Window("Settings", id: WindowID.settings) {
            SettingsView()
                .environmentObject(settings)
                .frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 460)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 480, height: 460)
        .defaultPosition(.center)
    }
}

enum WindowID {
    static let dictionary = "dictionary"
    static let settings = "settings"
}

private struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var localTranscriber = LocalTranscriber.shared
    @Environment(\.openWindow) private var openWindow

    private var engineLine: String {
        switch settings.transcriptionMode {
        case .cloud: return "Engine: cloud (Worker)"
        case .local:
            switch localTranscriber.state {
            case .ready: return "Engine: on this Mac (Parakeet v3), ready"
            case .loading: return "Engine: on this Mac (Parakeet v3), loading…"
            case .notLoaded: return "Engine: on this Mac (Parakeet v3), not loaded"
            case .failed: return "Engine: on this Mac (Parakeet v3), FAILED — see Settings"
            }
        }
    }

    var body: some View {
        Text(controller.state.menuTitle)
        Text(engineLine)
        if !controller.lastRunSummary.isEmpty {
            Text(controller.lastRunSummary)
        }

        Button(controller.state == .recording ? "Stop Dictation" : "Start Dictation") {
            controller.toggle()
        }
        .keyboardShortcut("d")

        if !controller.lastText.isEmpty {
            Button("Copy Last Transcript") { controller.copyLastToClipboard() }
        }

        Divider()

        Button("Dictionary…") { open(WindowID.dictionary) }
        Button("Settings…") { open(WindowID.settings) }
        // Permissions lives in an AppKit window owned by `Permissions` so the app delegate
        // can also open it at launch, where SwiftUI's `openWindow` is out of reach.
        Button("Permissions…") { Permissions.shared.showWindow() }

        Divider()

        Button("Quit Aside") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// LSUIElement apps have no Dock icon, so a window opened from the menu needs an
    /// explicit activation to come to the front.
    private func open(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
