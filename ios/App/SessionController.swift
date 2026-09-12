import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WidgetKit

/// The session engine: it owns the microphone, watches the App Group for commands from the
/// keyboard extension, runs the same pipeline the Mac app runs, and writes results back.
///
/// The shape of this mirrors `AppController` in `mac/Sources/App.swift` — `cleanupPlan()`
/// and `runCleanup(raw:plan:)` are the same two functions — but the trigger is a file in a
/// shared container instead of a key on a keyboard.
@MainActor
final class SessionController: ObservableObject {
    static let shared = SessionController()

    enum Phase: Equatable {
        case idle
        /// The talk button was pressed before the engine was pulling audio; waiting for it.
        case starting
        case listening
        case processing
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .starting: return "Starting the microphone…"
            case .listening: return "Listening…"
            case .processing: return "Transcribing…"
            case .failed(let message): return message
            }
        }
    }

    /// Where a dictation came from, which decides where the text goes: a result file for
    /// the keyboard, the clipboard for the Control Center control, the screen for the app.
    private enum Origin: Equatable {
        case keyboard(UUID)
        case control(UUID)
        case app

        var name: String {
            switch self {
            case .keyboard: return "keyboard"
            case .control: return "control"
            case .app: return "app"
            }
        }

        /// The start command's id, which keys the result file; nil for the in-app button.
        var commandID: UUID? {
            switch self {
            case .keyboard(let id), .control(let id): return id
            case .app: return nil
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var session: SessionState?
    @Published private(set) var lastText: String = ""
    @Published private(set) var lastSummary: String?
    /// Input level per chunk of the current or last dictation, newest last; feeds the meters.
    @Published private(set) var levels: [Float] = []
    /// Shown at the top of Home after the keyboard sent us here to start a session.
    @Published var banner: String?
    /// Text a Control Center dictation produced while another app was in front. iOS drops
    /// clipboard writes from a backgrounded app, so it waits until we are active. Kept in
    /// a file as well, so it survives iOS killing the app before the user taps.
    @Published private(set) var pendingClipboardText: String? {
        didSet {
            if let pendingClipboardText {
                try? pendingClipboardText.write(to: SessionController.pendingClipboardURL, atomically: true, encoding: .utf8)
            } else {
                try? FileManager.default.removeItem(at: SessionController.pendingClipboardURL)
            }
        }
    }
    private static var pendingClipboardURL: URL { AppGroupStorage.container.appendingPathComponent("pending-clipboard.txt") }

    let settings: AppSettings
    let dictionary: DictionaryStore
    let phone: PhoneSettings
    /// Shared with the Mac app: memory only, or a JSON file pruned by the retention setting.
    let history: DictationHistory

    private let recorder = SessionRecorder()
    private let direct = DirectClient()
    private let ipc = AppGroupStorage.ipc

    private var commandObserver: DarwinObserver?
    private var pollTimer: Timer?
    private var expiryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    /// The Home tab's talk button, run through the same gesture logic as the keyboard.
    private var talkTrigger = TriggerLogic()
    private var talkTapWindowTask: Task<Void, Never>?
    /// Waiting for the engine to come up after a talk-button press with no session running.
    private var talkStartTask: Task<Void, Never>?
    private var current: Origin?
    private var lastControlRecording = false

    /// A dictation longer than this is stopped and processed anyway.
    private static let watchdogSeconds: UInt64 = 90

    /// A control command older than this when the app finally sees it is a leftover from a
    /// tap whose app launch never happened, not a request to start recording now. Two
    /// minutes leaves room for a cold launch that still has to load Parakeet.
    private static let controlCommandMaxAge: TimeInterval = 120

    private var modelWaitTask: Task<Void, Never>?

    init(settings: AppSettings? = nil, dictionary: DictionaryStore? = nil, phone: PhoneSettings? = nil) {
        self.settings = settings ?? AppSettings(defaults: AppGroupStorage.defaults)
        self.dictionary = dictionary ?? DictionaryStore(fileURL: AppGroupStorage.dictionaryURL)
        self.phone = phone ?? PhoneSettings.shared
        self.history = DictationHistory(fileURL: DictationHistory.defaultFileURL, settings: self.settings)
        // A session written by an earlier launch is not ours; the audio engine died with it.
        if ipc.readSession()?.active == true { try? ipc.endSession() }
        self.session = ipc.readSession()
        self.pendingClipboardText = try? String(contentsOf: SessionController.pendingClipboardURL, encoding: .utf8)
        recorder.levelHandler = { [weak self] level in
            Task { @MainActor in self?.pushLevel(level) }
        }
        // The one reliable "we are in front now" signal: SwiftUI's scene phase is still
        // inactive when views first appear, and its change handler skips the initial value.
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { SessionController.shared.refresh() }
        }
    }

    private var activeObserver: NSObjectProtocol?

    var isSessionActive: Bool { AsideIPC.isActive(session, at: Date()) }

    var sessionStatus: String {
        guard let session else { return "Inactive" }
        if !session.active { return "Ended" }
        guard let expiresAt = session.expiresAt else { return "Active until you end it" }
        guard expiresAt > Date() else { return "Expired" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Active until \(formatter.string(from: expiresAt))"
    }

    /// True when the shared container is reachable. Without it the keyboard can never talk
    /// to us, and the app is only useful standalone.
    var appGroupAvailable: Bool { AppGroupStorage.isShared }

    enum Tab: Hashable { case home, dictionary, settings, recent }
    @Published var selectedTab: Tab = .home

    // MARK: - Configuration

    /// Why a dictation cannot run right now. Home shows it and disables the buttons rather
    /// than letting a recording fail after the fact.
    enum ConfigurationProblem: Error, Equatable, LocalizedError {
        case microphoneDenied
        case modelNotLoaded
        case modelLoading
        case modelFailed(String)
        case speechProviderIncomplete
        case speechKeyMissing(String)
        case cleanupProviderIncomplete
        case cleanupKeyMissing(String)
        case appleUnavailable(String)
        case unsupportedEngine

        var message: String {
            switch self {
            case .microphoneDenied:
                return "Microphone access is off for Aside. Allow it in iPhone Settings."
            case .modelNotLoaded:
                return "Parakeet v3 is not downloaded yet. It is about 600 MB, once."
            case .modelLoading:
                return "Parakeet v3 is loading."
            case .modelFailed(let why):
                return "Parakeet v3 failed to load: \(why)"
            case .speechProviderIncomplete:
                return "The speech provider needs a model and a base URL."
            case .speechKeyMissing(let provider):
                return "Add your \(provider) API key for speech to text."
            case .cleanupProviderIncomplete:
                return "The cleanup provider needs a model and a base URL."
            case .cleanupKeyMissing(let provider):
                return "Add your \(provider) API key for cleanup."
            case .appleUnavailable(let why):
                return "Apple on-device model unavailable: \(why)"
            case .unsupportedEngine:
                return "The Worker is not available on iPhone. Pick another engine."
            }
        }

        var errorDescription: String? { message }

        /// What the button under the message should do.
        enum Fix: Equatable { case systemSettings, loadModel, appSettings, wait }

        var fix: Fix {
            switch self {
            case .microphoneDenied: return .systemSettings
            case .modelNotLoaded, .modelFailed: return .loadModel
            case .modelLoading: return .wait
            default: return .appSettings
            }
        }
    }

    /// Nil when everything the current settings need is in place.
    func configurationProblem() -> ConfigurationProblem? {
        if SessionRecorder.microphonePermission == .denied { return .microphoneDenied }
        switch settings.transcriptionMode {
        case .local:
            switch LocalTranscriber.shared.state {
            case .notLoaded: return .modelNotLoaded
            case .loading: return .modelLoading
            case .failed(let why): return .modelFailed(why)
            case .ready: break
            }
        case .direct:
            guard let endpoint = settings.directSttEndpoint() else { return .speechProviderIncomplete }
            let preset = ProviderPreset.preset(id: settings.directSttProvider)
            if preset.needsKey && (endpoint.apiKey ?? "").isEmpty { return .speechKeyMissing(preset.name) }
        case .cloud:
            return .unsupportedEngine
        }
        guard settings.cleanup != .none else { return nil }
        switch settings.cleanupEngine {
        case .direct:
            guard let endpoint = settings.directChatEndpoint() else { return .cleanupProviderIncomplete }
            let preset = ProviderPreset.preset(id: settings.directChatProvider)
            if preset.needsKey && (endpoint.apiKey ?? "").isEmpty { return .cleanupKeyMissing(preset.name) }
        case .apple:
            switch AppleCleanup.shared.availability {
            case .available: break
            case .unsupportedOS: return .appleUnavailable("it needs iOS 26 or later.")
            case .unavailable(let why): return .appleUnavailable(SessionController.phoneWording(why))
            }
        case .worker:
            return .unsupportedEngine
        }
        return nil
    }

    /// `AppleCleanup` is shared with the Mac app and phrases its reasons for a Mac.
    static func phoneWording(_ text: String) -> String {
        text.replacingOccurrences(of: "this Mac", with: "this iPhone")
            .replacingOccurrences(of: "System Settings", with: "Settings")
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard !isSessionActive else { return }
        if let problem = configurationProblem() {
            if problem == .modelLoading {
                // A cold launch from the keyboard or the control lands here while Parakeet
                // is still loading. Rather than fail, start the session the moment it is
                // ready; any command the extension left behind is then picked up as usual.
                banner = "Starting a session as soon as Parakeet v3 finishes loading."
                afterModelLoads { [weak self] in self?.startSession() }
            } else {
                phase = .failed(problem.message)
            }
            return
        }
        ipc.purge()
        do {
            try recorder.startSession()
        } catch {
            phase = .failed(error.localizedDescription)
            Log.app.error("Session start failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        let now = Date()
        let expiresAt = phone.sessionLength.seconds.map { now.addingTimeInterval($0) }
        let state = SessionState(active: true, startedAt: now, expiresAt: expiresAt)
        do {
            try ipc.writeSession(state)
        } catch {
            recorder.stopSession()
            phase = .failed("Could not write the session file: \(error.localizedDescription)")
            return
        }
        session = state
        phase = .idle
        startWatchingCommands()
        scheduleExpiry(at: expiresAt)
        askForNotificationsOnce()
        prepareEngines()
        Log.app.notice("Session started, expires \(expiresAt?.description ?? "never", privacy: .public)")
    }

    /// Runs `action` once the local model is no longer loading (ready or failed).
    private func afterModelLoads(_ action: @escaping @MainActor () -> Void) {
        modelWaitTask?.cancel()
        modelWaitTask = Task { @MainActor [weak self] in
            while LocalTranscriber.shared.state == .loading, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled, self != nil else { return }
            action()
        }
    }

    func endSession(expired: Bool = false) {
        modelWaitTask?.cancel()
        modelWaitTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        stopWatchingCommands()
        discardCurrent()
        recorder.stopSession()
        try? ipc.endSession()
        session = ipc.readSession()
        phase = .idle
        syncControl()
        DarwinNotifier.post(AsideIPC.resultNotification)
        if expired {
            banner = "Session ended."
            notifyExpired()
        }
        Log.app.notice("Session ended\(expired ? " (expired)" : "", privacy: .public)")
    }

    /// Called from `aside://session/start`, which the keyboard opens, and from
    /// `aside://control/start`, which the Control Center control opens when no session
    /// was running to take its command.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "aside" else { return }
        let path = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        switch (path.first, path.dropFirst().first) {
        case ("session", "start"):
            if !isSessionActive { startSession() }
            banner = isSessionActive
                ? "Session started. Go back to your app and switch to the Aside keyboard."
                : "Could not start a session. \(phase.label)"
        case ("session", "end"):
            endSession()
        case ("control", "start"):
            adoptControlCommands()
            banner = isSessionActive
                ? "Listening. Tap the Aside control again (or the button below) to stop; the text is copied for you to paste."
                : "Could not start a session. \(phase.label)"
        default:
            break
        }
    }

    /// Re-reads the session file and drops a session that expired while we were suspended.
    func refresh() {
        session = ipc.readSession()
        if let session, session.active, !AsideIPC.isActive(session, at: Date()) {
            endSession(expired: true)
        }
        adoptControlCommands()
        deliverPendingClipboard()
    }

    /// Copies text held back from a background dictation now that the app is in front.
    private func deliverPendingClipboard() {
        guard let text = pendingClipboardText else { return }
        let state = UIApplication.shared.applicationState
        guard state == .active else {
            Log.app.info("Holding clipboard text: app state \(state.rawValue, privacy: .public)")
            return
        }
        copyToClipboard(text)
        pendingClipboardText = nil
        banner = "Copied to the clipboard. Go back to your app and paste."
    }

    /// The Control Center toggle can be tapped with no session running. It writes its
    /// `start` command anyway and opens the app; this is the app taking that command:
    /// start a session, then let the normal command path begin the dictation.
    private func adoptControlCommands() {
        let now = Date()
        let pending = ipc.pendingCommands().filter(\.isFromControl)
        guard !pending.isEmpty else { return }
        let stale = pending.filter { now.timeIntervalSince($0.at) > SessionController.controlCommandMaxAge }
        stale.forEach { ipc.removeCommand(id: $0.id) }
        let fresh = pending.filter { now.timeIntervalSince($0.at) <= SessionController.controlCommandMaxAge }
        guard !fresh.isEmpty else { return }
        if !isSessionActive {
            guard fresh.contains(where: { $0.action == .start }) else {
                fresh.forEach { ipc.removeCommand(id: $0.id) }
                return
            }
            startSession()
            guard isSessionActive else {
                // Deferred behind the model load: the commands stay for that retry.
                if configurationProblem() != .modelLoading {
                    fresh.forEach { ipc.removeCommand(id: $0.id) }
                }
                return
            }
        }
        drainCommands()
    }

    private func scheduleExpiry(at date: Date?) {
        expiryTask?.cancel()
        guard let date else { expiryTask = nil; return }
        expiryTask = Task { [weak self] in
            let seconds = max(0, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.endSession(expired: true)
        }
    }

    /// Warms up whichever engines the current settings will need.
    func prepareEngines() {
        if settings.transcriptionMode == .local { LocalTranscriber.shared.prepare() }
        if settings.cleanupEngine == .apple, settings.cleanup != .none {
            AppleCleanup.shared.refresh()
            AppleCleanup.shared.prewarm()
        }
    }

    // MARK: - Command watching

    private func startWatchingCommands() {
        commandObserver = DarwinObserver(name: AsideIPC.commandNotification) { [weak self] in
            Task { @MainActor in self?.drainCommands() }
        }
        retimePolling()
        drainCommands()
    }

    private func stopWatchingCommands() {
        commandObserver = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Darwin notifications are best-effort, so the directory is polled too — fast while a
    /// dictation is in flight, lazily the rest of the time.
    private func retimePolling() {
        pollTimer?.invalidate()
        guard commandObserver != nil else { return }
        let interval = current == nil ? 1.0 : AsideIPC.pollInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainCommands() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func drainCommands() {
        guard isSessionActive else {
            if session?.active == true { refresh() }
            return
        }
        for command in ipc.pendingCommands() {
            ipc.removeCommand(id: command.id)
            handle(command)
        }
    }

    private func handle(_ command: DictationCommand) {
        switch command.action {
        case .start:
            beginDictation(origin: command.isFromControl ? .control(command.id) : .keyboard(command.id))
        case .stop:
            endDictationAndProcess()
        case .cancel:
            cancelDictation()
        }
    }

    // MARK: - One dictation

    /// The in-app talk button: hold, or tap according to the tap setting. Starts the audio
    /// engine on its own when no session is running, so the app is useful without ever
    /// enabling the keyboard.
    ///
    /// `time` is the touch event's own timestamp. Starting the engine here blocks the main
    /// thread for a few hundred milliseconds, so the release handler runs late; timed by the
    /// clock at that point, a tap read as a hold and ended the dictation as "too short".
    func pushToTalkDown(at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        talkTrigger.tapBehavior = settings.tapBehavior
        talkTapWindowTask?.cancel()
        // A latched dictation that ended some other way (watchdog, failure) must not turn
        // this press into a "stop".
        if talkTrigger.latched, phase != .listening, phase != .starting { talkTrigger.reset() }
        switch talkTrigger.keyDown(at: time) {
        case .start:
            startPushToTalk()
        case .stopLatched:
            if talkStartTask != nil { abandonTalkStart() } else { endDictationAndProcess() }
        case .latch:
            objectWillChange.send()
        default:
            break
        }
    }

    func pushToTalkUp(at time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        switch talkTrigger.keyUp(at: time) {
        case .send:
            // A hold that ended before the engine came up recorded nothing; drop it.
            if talkStartTask != nil { abandonTalkStart() } else { endDictationAndProcess() }
        case .tapPending:
            scheduleTalkTapWindow()
        case .latch:
            objectWillChange.send()
        default:
            break
        }
    }

    var isTalkLatched: Bool { talkTrigger.latched }

    private func scheduleTalkTapWindow() {
        talkTapWindowTask?.cancel()
        let window = talkTrigger.tapWindow
        talkTapWindowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled, let self else { return }
            if self.talkTrigger.tapWindowExpired() == .discard { self.cancelDictation() }
        }
    }

    private func startPushToTalk() {
        if let problem = configurationProblem() {
            phase = .failed(problem.message)
            return
        }
        if !recorder.isRunning {
            do {
                try recorder.startSession()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        guard !recorder.isInputReady else {
            beginDictation(origin: .app)
            return
        }
        // With no session running the engine was started just now and may not be pulling
        // audio yet. Refusing the tap here used to show as a red "not ready" flash that
        // read as recording; wait for the input instead, then begin.
        phase = .starting
        talkStartTask?.cancel()
        talkStartTask = Task { @MainActor [weak self] in
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if self.recorder.isInputReady {
                    self.talkStartTask = nil
                    self.beginDictation(origin: .app)
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.talkStartTask = nil
            self.fail("The microphone (\(AudioTrace.currentInput)) did not start. Try again.", origin: .app)
        }
    }

    private func abandonTalkStart() {
        talkStartTask?.cancel()
        talkStartTask = nil
        talkTrigger.reset()
        phase = .idle
        idleIfStandalone()
    }

    private static let levelHistory = 40

    private func pushLevel(_ level: Float) {
        levels.append(level)
        if levels.count > SessionController.levelHistory { levels.removeFirst(levels.count - SessionController.levelHistory) }
    }

    private func beginDictation(origin: Origin) {
        // A second `start` with one already running replaces it; do not let that release
        // the audio engine on the way through, we are about to use it.
        if current != nil { discardCurrent() }
        levels = []
        do {
            try recorder.beginDictation()
        } catch {
            fail(error.localizedDescription, origin: origin)
            return
        }
        current = origin
        phase = .listening
        if let id = origin.commandID {
            publish(DictationResult(id: id, status: .recording))
        }
        retimePolling()
        startWatchdog()
        syncControl()
    }

    private func endDictationAndProcess() {
        guard let origin = current else { return }
        cancelWatchdog()
        let audio: Data
        do {
            audio = try recorder.endDictation()
        } catch {
            fail(error.localizedDescription, origin: origin)
            return
        }
        phase = .processing
        if let id = origin.commandID {
            publish(DictationResult(id: id, status: .processing))
        }
        syncControl()
        let plan = cleanupPlan()
        Task { @MainActor in
            await self.run(audio: audio, plan: plan, origin: origin)
        }
    }

    private func cancelDictation() {
        var hadKeyboardResult = false
        if case .keyboard = current { hadKeyboardResult = true }
        discardCurrent()
        // The keyboard is watching for a result that is now never coming; nudge it to look.
        if hadKeyboardResult { DarwinNotifier.post(AsideIPC.resultNotification) }
        phase = .idle
        retimePolling()
        syncControl()
        idleIfStandalone()
    }

    /// Drops the in-flight dictation and its result file without touching the engine.
    private func discardCurrent() {
        cancelWatchdog()
        recorder.cancelDictation()
        if let id = current?.commandID { ipc.removeResult(id: id) }
        current = nil
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Int(SessionController.watchdogSeconds)))
            guard !Task.isCancelled else { return }
            Log.app.notice("Watchdog stopped a dictation at 90 s")
            self?.endDictationAndProcess()
        }
    }

    private func cancelWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Pipeline (the Mac's runCleanup flow)

    typealias CleanupPlan = DictationPipeline.CleanupPlan

    private func cleanupPlan() -> CleanupPlan {
        DictationPipeline.plan(settings: settings, entries: dictionary.entries).cleanup
    }

    private func run(audio: Data, plan: CleanupPlan, origin: Origin) async {
        do {
            var snapshot = DictationPipeline.plan(settings: settings, entries: plan.entries)
            snapshot.cleanup = plan
            let started = Date()
            let raw = try await DictationPipeline.transcribe(audio: audio, plan: snapshot, direct: direct)
            let sttMs = Int(Date().timeIntervalSince(started) * 1000)
            let result = try await DictationPipeline.clean(raw: raw, plan: plan, direct: direct)
            finish(raw: raw, text: result.text, engine: snapshot.mode, cleanupLabel: result.label,
                   sttMs: sttMs, cleanupMs: result.ms, origin: origin)
        } catch {
            fail(error.localizedDescription, origin: origin)
        }
    }

    // MARK: - Results

    private func finish(raw: String, text: String, engine: TranscriptionMode, cleanupLabel: String,
                        sttMs: Int, cleanupMs: Int, origin: Origin) {
        let final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        current = nil
        retimePolling()
        guard !final.isEmpty else {
            fail("Nothing was said", origin: origin, alreadyCleared: true)
            return
        }
        lastText = final
        phase = .idle
        let engineName = engine.rawValue
        if let id = origin.commandID {
            publish(DictationResult(id: id, status: .done, text: final, rawText: raw,
                                    engine: engineName, cleanup: cleanupLabel,
                                    sttMs: sttMs, cleanupMs: cleanupMs))
        }
        if case .control = origin {
            if UIApplication.shared.applicationState == .active {
                copyToClipboard(final)
                notify(title: "Copied to clipboard", body: final)
            } else {
                // A backgrounded app cannot write the clipboard; it happens on the way in.
                pendingClipboardText = final
                notify(title: "Tap to copy", body: final)
            }
        }
        syncControl()
        history.add(DictationRecord(
            date: Date(), engine: engine, source: origin.name,
            rawText: raw, finalText: final, sttMs: sttMs, cleanupMs: cleanupMs, cleanupLabel: cleanupLabel))
        lastSummary = "Last: \(engineDescription(engine)), speech \(sttMs) ms"
            + (cleanupMs > 0 ? ", cleanup \(cleanupMs) ms" : ", no cleanup call")
        Log.app.notice("Done via \(engineName, privacy: .public): stt \(sttMs, privacy: .public) ms, cleanup \(cleanupMs, privacy: .public) ms, \(final.count, privacy: .public) chars")
        idleIfStandalone()
    }

    private func fail(_ message: String, origin: Origin, alreadyCleared: Bool = false) {
        if !alreadyCleared {
            cancelWatchdog()
            recorder.cancelDictation()
            current = nil
            retimePolling()
        }
        phase = .failed(message)
        if let id = origin.commandID {
            publish(DictationResult(id: id, status: .failed, error: message))
        }
        if case .control = origin {
            notify(title: "Aside could not transcribe", body: message)
        }
        syncControl()
        Log.app.error("\(message, privacy: .public)")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .failed = self.phase { self.phase = .idle }
        }
        idleIfStandalone()
    }

    private func engineDescription(_ engine: TranscriptionMode) -> String {
        switch engine {
        case .local: return "on this iPhone (Parakeet v3)"
        case .direct: return settings.directSttEndpoint()?.label ?? "a provider, directly"
        case .cloud: return "Worker (not available on iPhone)"
        }
    }

    private func publish(_ result: DictationResult) {
        do {
            try ipc.writeResult(result)
            DarwinNotifier.post(AsideIPC.resultNotification)
        } catch {
            Log.store.error("Could not write the result file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A hold-to-talk dictation with no session behind it owns the audio engine only for as
    /// long as it takes; releasing it lets iOS suspend the app normally.
    private func idleIfStandalone() {
        guard !isSessionActive, recorder.isRunning, current == nil else { return }
        recorder.stopSession()
    }

    // MARK: - Control Center

    /// Keeps `control.json` and the toggle in Control Center in step with what is really
    /// happening: on only while a control-started dictation is being recorded.
    private func syncControl() {
        var recording = false
        var id: UUID?
        if case .control(let current) = current, phase == .listening {
            recording = true
            id = current
        }
        guard recording != lastControlRecording || ipc.readControlState() == nil else { return }
        lastControlRecording = recording
        try? ipc.writeControlState(ControlState(recording: recording, dictationID: id))
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }

    /// The control's delivery. iOS clears the clipboard at the expiry on its own, and the
    /// text is not marked local-only, so Universal Clipboard carries it to a nearby Mac.
    private func copyToClipboard(_ text: String) {
        var options: [UIPasteboard.OptionsKey: Any] = [:]
        if let seconds = phone.clipboardExpiry.seconds {
            options[.expirationDate] = Date().addingTimeInterval(seconds)
        }
        UIPasteboard.general.setItems([[UTType.plainText.identifier: text]], options: options)
    }

    // MARK: - Notifications

    private func askForNotificationsOnce() {
        guard !phone.askedForNotifications else { return }
        phone.askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.app.info("Notification permission granted: \(granted, privacy: .public)")
        }
    }

    private func notifyExpired() {
        notify(identifier: "aside.session.expired", title: "Aside session ended", body: "Open Aside to start another one.")
    }

    /// Shown when the user is in another app; iOS suppresses it while Aside is in front,
    /// where the result card already says the same thing.
    private func notify(identifier: String = "aside.dictation", title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body.count > 300 ? String(body.prefix(300)) + "…" : body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
