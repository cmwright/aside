import Foundation
import SwiftUI
import UserNotifications

/// One finished dictation, kept in memory so the raw speech-model output can be compared
/// with the text after cleanup. Nothing is written to disk: transcripts stay in the
/// process, and the App Group result file is deleted as soon as the keyboard has read it.
struct DictationRecord: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let engine: TranscriptionMode
    let source: String
    let rawText: String
    let finalText: String
    let sttMs: Int
    let cleanupMs: Int
    let cleanupLabel: String

    var engineLabel: String {
        switch engine {
        case .local: return "Parakeet v3 (on this iPhone)"
        case .direct: return "provider, direct"
        case .cloud: return "cloud (Worker)"
        }
    }
    var changed: Bool { rawText.trimmingCharacters(in: .whitespacesAndNewlines) != finalText }
}

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
        case listening
        case processing
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .listening: return "Listening…"
            case .processing: return "Transcribing…"
            case .failed(let message): return message
            }
        }
    }

    /// Where a dictation came from, which decides whether a result file is written.
    private enum Origin: Equatable {
        case keyboard(UUID)
        case app
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var session: SessionState?
    @Published private(set) var lastText: String = ""
    @Published private(set) var lastSummary: String?
    /// Shown at the top of Home after the keyboard sent us here to start a session.
    @Published var banner: String?

    let settings: AppSettings
    let dictionary: DictionaryStore
    let phone: PhoneSettings

    private let recorder = SessionRecorder()
    private let client = BackendClient()
    private let direct = DirectClient()
    private let ipc = AppGroupStorage.ipc

    private var commandObserver: DarwinObserver?
    private var pollTimer: Timer?
    private var expiryTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var current: Origin?

    /// A dictation longer than this is stopped and processed anyway.
    private static let watchdogSeconds: UInt64 = 90

    init(settings: AppSettings? = nil, dictionary: DictionaryStore? = nil, phone: PhoneSettings? = nil) {
        self.settings = settings ?? AppSettings(defaults: AppGroupStorage.defaults)
        self.dictionary = dictionary ?? DictionaryStore(fileURL: AppGroupStorage.dictionaryURL)
        self.phone = phone ?? PhoneSettings.shared
        // A session written by an earlier launch is not ours; the audio engine died with it.
        if ipc.readSession()?.active == true { try? ipc.endSession() }
        self.session = ipc.readSession()
    }

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

    // MARK: - Session lifecycle

    func startSession() {
        guard !isSessionActive else { return }
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

    func endSession(expired: Bool = false) {
        expiryTask?.cancel()
        expiryTask = nil
        stopWatchingCommands()
        discardCurrent()
        recorder.stopSession()
        try? ipc.endSession()
        session = ipc.readSession()
        phase = .idle
        DarwinNotifier.post(AsideIPC.resultNotification)
        if expired {
            banner = "Session ended."
            notifyExpired()
        }
        Log.app.notice("Session ended\(expired ? " (expired)" : "", privacy: .public)")
    }

    /// Called from `aside://session/start`, which the keyboard opens.
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "aside" else { return }
        let path = (url.host.map { [$0] } ?? []) + url.pathComponents.filter { $0 != "/" }
        guard path.first == "session" else { return }
        switch path.dropFirst().first {
        case "start":
            if !isSessionActive { startSession() }
            banner = isSessionActive
                ? "Session started. Go back to your app and switch to the Aside keyboard."
                : "Could not start a session. \(phase.label)"
        case "end":
            endSession()
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
            beginDictation(origin: .keyboard(command.id))
        case .stop:
            endDictationAndProcess()
        case .cancel:
            cancelDictation()
        }
    }

    // MARK: - One dictation

    /// The in-app hold-to-talk button. Starts the audio engine on its own when no session
    /// is running, so the app is useful without ever enabling the keyboard.
    func pushToTalkDown() {
        if !recorder.isRunning {
            do {
                try recorder.startSession()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        beginDictation(origin: .app)
    }

    func pushToTalkUp() {
        endDictationAndProcess()
    }

    private func beginDictation(origin: Origin) {
        // A second `start` with one already running replaces it; do not let that release
        // the audio engine on the way through, we are about to use it.
        if current != nil { discardCurrent() }
        do {
            try recorder.beginDictation()
        } catch {
            fail(error.localizedDescription, origin: origin)
            return
        }
        current = origin
        phase = .listening
        if case .keyboard(let id) = origin {
            publish(DictationResult(id: id, status: .recording))
        }
        retimePolling()
        startWatchdog()
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
        if case .keyboard(let id) = origin {
            publish(DictationResult(id: id, status: .processing))
        }
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
        idleIfStandalone()
    }

    /// Drops the in-flight dictation and its result file without touching the engine.
    private func discardCurrent() {
        cancelWatchdog()
        recorder.cancelDictation()
        if case .keyboard(let id) = current { ipc.removeResult(id: id) }
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

    struct CleanupPlan {
        var engine: CleanupEngine
        var level: CleanupLevel
        var entries: [DictionaryEntry]
        var baseURL: URL?
        var token: String?
        var direct: DirectEndpoint?
        var directNeedsKey: Bool
    }

    private func cleanupPlan() -> CleanupPlan {
        CleanupPlan(engine: settings.cleanupEngine, level: settings.cleanup, entries: dictionary.entries,
                    baseURL: settings.backendURL, token: settings.trimmedToken,
                    direct: settings.directChatEndpoint(),
                    directNeedsKey: ProviderPreset.preset(id: settings.directChatProvider).needsKey)
    }

    private func run(audio: Data, plan: CleanupPlan, origin: Origin) async {
        do {
            let started = Date()
            switch settings.transcriptionMode {
            case .local:
                let raw = try await LocalTranscriber.shared.transcribe(pcm16: WAV.pcm16(fromFile: audio))
                let sttMs = Int(Date().timeIntervalSince(started) * 1000)
                let result = try await runCleanup(raw: raw, plan: plan)
                finish(raw: raw, text: result.text, engine: .local, cleanupLabel: result.label,
                       sttMs: sttMs, cleanupMs: result.ms, origin: origin)
                return

            case .direct:
                guard let endpoint = settings.directSttEndpoint() else {
                    throw DirectError.badResponse("a speech provider with a model and base URL (check Settings)")
                }
                let preset = ProviderPreset.preset(id: settings.directSttProvider)
                if preset.needsKey && (endpoint.apiKey ?? "").isEmpty {
                    throw DirectError.missingKey(preset.name)
                }
                let raw = try await direct.transcribe(
                    audio: audio, endpoint: endpoint,
                    vocabulary: DirectClient.vocabulary(from: plan.entries))
                let sttMs = Int(Date().timeIntervalSince(started) * 1000)
                let result = try await runCleanup(raw: raw, plan: plan)
                finish(raw: raw, text: result.text, engine: .direct, cleanupLabel: result.label,
                       sttMs: sttMs, cleanupMs: result.ms, origin: origin)
                return

            case .cloud:
                break
            }

            guard let baseURL = plan.baseURL else { throw BackendError.badURL }
            let response = try await client.transcribe(TranscriptionRequest(
                baseURL: baseURL,
                token: plan.token,
                audio: audio,
                dictionaryJSON: DictionaryCodec.encodeForRequest(plan.entries),
                // When cleanup runs on this phone the Worker is asked for the raw transcript.
                cleanup: plan.engine == .worker ? plan.level : .none,
                appName: nil
            ))
            if plan.engine == .worker {
                finish(raw: response.rawText ?? response.text, text: response.text, engine: .cloud,
                       cleanupLabel: plan.level == .none ? "none" : "Worker",
                       sttMs: Int(response.timing?.stt ?? 0), cleanupMs: Int(response.timing?.cleanup ?? 0),
                       origin: origin)
                return
            }
            let raw = response.rawText ?? response.text
            let result = try await runCleanup(raw: raw, plan: plan)
            finish(raw: raw, text: result.text, engine: .cloud, cleanupLabel: result.label,
                   sttMs: Int(response.timing?.stt ?? 0), cleanupMs: result.ms, origin: origin)
        } catch {
            fail(error.localizedDescription, origin: origin)
        }
    }

    /// The cleanup stage for a transcript already in hand. The Worker applies the dictionary
    /// post-pass itself; every other path runs the Swift port so the result is the same.
    private func runCleanup(raw: String, plan: CleanupPlan) async throws -> (text: String, ms: Int, label: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", 0, "none") }
        guard plan.level != .none else {
            return (DictionaryReplacer.apply(trimmed, entries: plan.entries)
                .trimmingCharacters(in: .whitespacesAndNewlines), 0, "none")
        }
        let started = Date()
        switch plan.engine {
        case .worker:
            guard let baseURL = plan.baseURL else { throw BackendError.badURL }
            let response = try await client.cleanup(CleanupRequest(
                baseURL: baseURL, token: plan.token, text: trimmed,
                dictionaryJSON: DictionaryCodec.encodeForRequest(plan.entries),
                cleanup: plan.level, appName: nil))
            return (response.text, Int(response.timing?.cleanup ?? Date().timeIntervalSince(started) * 1000), "Worker")
        case .direct:
            guard let endpoint = plan.direct else {
                throw DirectError.badResponse("a usable cleanup provider (check Settings)")
            }
            if plan.directNeedsKey && (endpoint.apiKey ?? "").isEmpty {
                throw DirectError.missingKey(endpoint.providerName)
            }
            let reply = try await direct.chat(
                endpoint: endpoint,
                system: CleanupPrompt.instructions(level: plan.level, entries: plan.entries),
                user: CleanupPrompt.userPrompt(trimmed))
            var text = CleanupPrompt.sanitize(reply)
            var label = "Direct: \(endpoint.label)"
            if text.isEmpty || AppleCleanup.similarity(raw: trimmed, cleaned: text) < 0.5 {
                label += " (off-script; raw text kept)"
                text = trimmed
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return (DictionaryReplacer.apply(text, entries: plan.entries)
                .trimmingCharacters(in: .whitespacesAndNewlines), ms, label)
        case .apple:
            var text = trimmed
            var label = "Apple on-device model"
            do {
                text = try await AppleCleanup.shared.clean(trimmed, level: plan.level, entries: plan.entries)
            } catch let error as AppleCleanupError {
                if case .declined(let why) = error {
                    label = "Apple model declined (\(why)); raw text kept"
                    Log.app.notice("Apple cleanup declined: \(why, privacy: .public)")
                } else {
                    throw error
                }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return (DictionaryReplacer.apply(text, entries: plan.entries)
                .trimmingCharacters(in: .whitespacesAndNewlines), ms, label)
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
        if case .keyboard(let id) = origin {
            publish(DictationResult(id: id, status: .done, text: final, rawText: raw,
                                    engine: engineName, cleanup: cleanupLabel,
                                    sttMs: sttMs, cleanupMs: cleanupMs))
        }
        RecentDictations.shared.add(DictationRecord(
            date: Date(), engine: engine, source: origin == .app ? "app" : "keyboard",
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
        if case .keyboard(let id) = origin {
            publish(DictationResult(id: id, status: .failed, error: message))
        }
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
        case .cloud: return "cloud (Worker)"
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

    // MARK: - Notifications

    private func askForNotificationsOnce() {
        guard !phone.askedForNotifications else { return }
        phone.askedForNotifications = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.app.info("Notification permission granted: \(granted, privacy: .public)")
        }
    }

    private func notifyExpired() {
        let content = UNMutableNotificationContent()
        content.title = "Aside session ended"
        content.body = "Open Aside to start another one."
        let request = UNNotificationRequest(identifier: "aside.session.expired", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Ring buffer of recent dictations. Memory only, like the Mac app's history: a phone
/// keyboard should not leave transcripts behind on disk.
@MainActor
final class RecentDictations: ObservableObject {
    static let shared = RecentDictations()
    static let capacity = 50

    @Published private(set) var records: [DictationRecord] = []

    func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > RecentDictations.capacity { records.removeLast() }
    }

    func clear() { records.removeAll() }
}
