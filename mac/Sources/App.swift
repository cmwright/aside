import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts
import Sparkle
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
    /// Transcription plus cleanup that takes this long is given up on. Without this, a
    /// stalled model download or a provider that never answers left the app in
    /// "Transcribing…" for good, with the key and the menu both ignored.
    nonisolated static let maximumProcessingSeconds: Double = 60
    /// One retry, after this pause, for a cleanup call that failed in a transient way.
    nonisolated static let cleanupRetryDelay: Double = 1.0

    @Published private(set) var state: DictationState = .idle
    /// Name of the process holding secure keyboard entry, while one does. Global key
    /// monitors receive nothing then, so Right Option is dead until it lets go.
    @Published private(set) var secureInputHolder: String?
    @Published private(set) var lastText: String = ""
    /// One line for the menu: which engine handled the last dictation and how long it took.
    @Published private(set) var lastRunSummary: String = ""

    private let recorder = Recorder()
    private let client = BackendClient()
    private let direct = DirectClient()
    private let settings = AppSettings.shared
    private let dictionary = DictionaryStore.shared

    /// The listen-only session tap that sees Right Option while any app is frontmost. It
    /// lives on its own thread (`FlagsTap`) so a busy main thread can never make macOS
    /// judge the tap slow and switch it off.
    private var flagsTap: FlagsTap?
    private var wakeObservers: [any NSObjectProtocol] = []
    private var capturedAppName: String?
    /// Local mode: Parakeet keeps up with the audio while the key is held, so key-up only
    /// has the tail left to decode. Nil when the model is not loaded yet or in cloud mode.
    private var streamingSession: StreamingSession?
    private var rightOptionDown = false
    private var trigger = TriggerLogic()
    private var tapWindowTask: Task<Void, Never>?
    private var accessibilityCancellable: AnyCancellable?
    private var accessibilityGranted = false
    private var watchdog: Task<Void, Never>?
    private var processingWatchdog: Task<Void, Never>?
    /// Incremented for every dictation; async work compares its ticket against this
    /// before touching state, so a cancelled or timed-out job cannot finish later.
    private var jobTicket = 0
    private var secureInputTimer: Timer?

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
        // Sleep and wake, or the session going away and coming back, can leave the tap dead
        // with no error. Reinstall it whenever the machine comes back.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            let label = name.rawValue
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    Log.app.notice("\(label, privacy: .public); reinstalling the hold-to-talk tap")
                    AppController.shared.reinstallFlagsMonitors()
                }
            })
        }
        // A key-event tap created while the process is untrusted never starts delivering
        // events, not even after the grant lands. Watch the permission and re-install the
        // tap the moment it flips, so the first run (and every re-grant after an ad-hoc
        // rebuild) works without relaunching the app.
        accessibilityCancellable = permissions.$accessibility
            .removeDuplicates()
            .sink { state in
                MainActor.assumeIsolated { AppController.shared.accessibilityChanged(to: state) }
            }
        startSecureInputMonitor()
    }

    // MARK: - Secure input

    /// macOS sends no notification when secure keyboard entry flips, so poll. Password
    /// fields turn it on for a moment, which is normal; a login window or terminal that
    /// keeps it on after the screen unlocks is what breaks the dictation key for good.
    private func startSecureInputMonitor() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated { AppController.shared.refreshSecureInput() }
        }
        RunLoop.main.add(timer, forMode: .common)
        secureInputTimer = timer
        refreshSecureInput()
    }

    private func refreshSecureInput() {
        checkEventTapHealth()
        let holder = AppController.secureInputHolderName()
        guard holder != secureInputHolder else { return }
        secureInputHolder = holder
        if let holder {
            Log.app.notice("Secure keyboard entry is on (\(holder, privacy: .public)); the dictation key cannot be seen")
        } else {
            Log.app.notice("Secure keyboard entry released")
        }
    }

    /// Who has secure input, or nil when nobody does. The pid comes from the session
    /// dictionary; Karabiner and friends read the same key.
    nonisolated static func secureInputHolderName() -> String? {
        guard IsSecureEventInputEnabled() else { return nil }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        guard let pid = session?["kCGSSessionSecureInputPID"] as? Int32 else { return "an unknown app" }
        return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "process \(pid)"
    }

    /// One line for the menu, or nil when the key works.
    var secureInputWarning: String? {
        guard let holder = secureInputHolder else { return nil }
        return "Secure input is on in \(holder); the dictation key is blocked until it lets go (or lock and unlock the screen)"
    }

    private func accessibilityChanged(to state: Permissions.State) {
        let granted = state == .granted
        defer { accessibilityGranted = granted }
        guard granted, !accessibilityGranted else { return }
        Log.app.info("Accessibility granted; re-installing the hold-to-talk monitors")
        reinstallFlagsMonitors()
    }

    private func reinstallFlagsMonitors() {
        flagsTap?.stop()
        flagsTap = nil
        installFlagsMonitors()
    }

    /// A session-wide, listen-only event tap for modifier changes. It sees Right Option
    /// whichever app is frontmost, our own windows included, and needs Accessibility.
    ///
    /// This used to be `NSEvent.addGlobalMonitorForEvents`, which is the same tap with the
    /// failure hidden: macOS disables a tap it thinks was slow to answer, or across a
    /// sleep, and AppKit neither says so nor turns it back on. The app then sat there
    /// looking healthy with a dead key until relaunched. Owning the tap means the
    /// disable arrives as an event and can be undone on the spot.
    private func installFlagsMonitors() {
        let tap = FlagsTap(
            onFlagsChanged: { keyCode, flags, timestamp in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AppController.shared.handleFlagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
                    }
                }
            },
            onDisabled: { reason in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { AppController.shared.tapWasDisabled(reason) }
                }
            }
        )
        guard tap.start() else {
            Log.app.error("Could not create the hold-to-talk event tap (Accessibility not granted?)")
            return
        }
        flagsTap = tap
        Log.app.notice("Hold-to-talk event tap installed")
    }

    private func tapWasDisabled(_ reason: String) {
        Log.app.error("macOS disabled the hold-to-talk tap (\(reason, privacy: .public)); re-enabling")
        rightOptionDown = false
        guard let flagsTap, flagsTap.enable() else { reinstallFlagsMonitors(); return }
    }

    /// Belt and braces, run from the two-second poll: a tap that is off with no event
    /// having told us (it happens across sleep) is switched back on or rebuilt.
    private func checkEventTapHealth() {
        guard accessibilityGranted, settings.holdRightOption else { return }
        guard let flagsTap else {
            Log.app.error("Hold-to-talk tap is missing; installing")
            installFlagsMonitors()
            return
        }
        if !flagsTap.isEnabled {
            Log.app.error("Hold-to-talk tap was found disabled; re-enabling")
            rightOptionDown = false
            if !flagsTap.enable() { reinstallFlagsMonitors() }
        }
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

    /// `flags` is the event's `CGEventFlags` raw value, which carries the same device bits
    /// AppKit exposes in `NSEvent.modifierFlags.rawValue`.
    private func handleFlagsChanged(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        guard settings.holdRightOption, keyCode == Int64(AppController.rightOptionKeyCode) else { return }
        let isDown = AppController.rightOptionIsDown(
            eventFlags: UInt(truncatingIfNeeded: flags),
            liveFlags: NSEvent.modifierFlags
        )
        Log.app.debug("flagsChanged right-option down=\(isDown, privacy: .public)")
        guard isDown != rightOptionDown else { return }
        rightOptionDown = isDown
        trigger.doubleTapWindow = settings.doubleTapToLatch ? TriggerLogic().doubleTapWindow : 0
        let action = isDown ? trigger.keyDown(at: timestamp) : trigger.keyUp(at: timestamp)
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
        } else if state == .processing {
            cancelProcessing()
        } else {
            beginRecording()
        }
    }

    /// Drops the dictation in flight. Whatever the job returns later is ignored.
    func cancelProcessing() {
        guard state == .processing else { return }
        jobTicket += 1
        cancelProcessingWatchdog()
        Log.app.notice("Dictation cancelled while processing")
        state = .idle
        StatusOverlay.shared.flash("Cancelled", tone: .failure, after: 1.5)
    }

    /// Claims the current dictation. Async work keeps the ticket and hands it back to
    /// `stillCurrent` before reporting; a stale ticket means the user cancelled or the
    /// watchdog gave up, and the result is thrown away.
    private func beginJob() -> Int {
        jobTicket += 1
        startProcessingWatchdog(ticket: jobTicket)
        return jobTicket
    }

    private func stillCurrent(_ ticket: Int) -> Bool {
        ticket == jobTicket && state == .processing
    }

    private func startProcessingWatchdog(ticket: Int) {
        processingWatchdog?.cancel()
        processingWatchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppController.maximumProcessingSeconds))
            guard !Task.isCancelled else { return }
            let controller = AppController.shared
            guard controller.stillCurrent(ticket) else { return }
            Log.app.error("Processing hit the \(Int(AppController.maximumProcessingSeconds), privacy: .public)s watchdog; giving up")
            controller.jobTicket += 1
            controller.fail("Took too long; gave up. Check the engine in Settings, then try again.")
        }
    }

    private func cancelProcessingWatchdog() {
        processingWatchdog?.cancel()
        processingWatchdog = nil
    }

    func beginRecording() {
        guard !recorder.isRecording, state != .processing else { return }
        capturedAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        let session = settings.transcriptionMode == .local ? LocalTranscriber.shared.beginSession() : nil
        var listener: (@Sendable ([Float]) -> Void)?
        if let session { listener = { session.feed($0) } }
        do {
            try recorder.start(listener: listener)
            streamingSession = session
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
            session?.cancel()
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
        let session = streamingSession
        streamingSession = nil
        let audio: Data
        do {
            audio = try recorder.stop()
        } catch RecorderError.tooShort {
            session?.cancel()
            state = .idle
            StatusOverlay.shared.hide()
            return
        } catch {
            session?.cancel()
            fail(error.localizedDescription)
            return
        }

        play(.stop)
        state = .processing

        if settings.transcriptionMode == .local {
            transcribeLocally(audio, session: session)
            return
        }
        session?.cancel()

        if settings.transcriptionMode == .direct {
            transcribeDirect(audio)
            return
        }

        StatusOverlay.shared.show("Transcribing", tone: .working)

        guard let baseURL = settings.backendURL else {
            fail(BackendError.badURL.localizedDescription)
            return
        }

        let plan = cleanupPlan()
        let request = TranscriptionRequest(
            baseURL: baseURL,
            token: settings.trimmedToken,
            audio: audio,
            dictionaryJSON: DictionaryCodec.encodeForRequest(dictionary.entries),
            cleanup: plan.engine == .worker ? plan.level : .none,
            appName: capturedAppName
        )
        let client = self.client
        let ticket = beginJob()

        Task { @MainActor in
            do {
                let response = try await client.transcribe(request)
                if plan.engine == .worker {
                    guard self.stillCurrent(ticket) else { return }
                    self.finish(with: response, engine: .cloud, cleanupLabel: plan.level == .none ? "none" : "Worker")
                    return
                }
                let raw = response.rawText ?? response.text
                let sttMs = response.timing?.stt ?? 0
                let result = await self.runCleanup(raw: raw, plan: plan)
                guard self.stillCurrent(ticket) else { return }
                self.finish(with: TranscriptionResponse(
                    text: result.text, rawText: raw,
                    timing: .init(stt: sttMs, cleanup: Double(result.ms), total: sttMs + Double(result.ms))),
                    engine: .cloud, cleanupLabel: result.label, warning: result.warning)
            } catch {
                guard self.stillCurrent(ticket) else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    /// Speech straight from the app to an OpenAI-compatible provider, then the cleanup stage.
    private func transcribeDirect(_ audio: Data) {
        guard let endpoint = settings.directSttEndpoint() else {
            fail("Pick a speech provider with a model and base URL in Settings → Providers.")
            return
        }
        let preset = ProviderPreset.preset(id: settings.directSttProvider)
        if preset.needsKey && (endpoint.apiKey ?? "").isEmpty {
            fail(DirectError.missingKey(preset.name).localizedDescription)
            return
        }
        StatusOverlay.shared.show("Transcribing via \(endpoint.providerName)", tone: .working)
        let plan = cleanupPlan()
        let vocabulary = DirectClient.vocabulary(from: dictionary.entries)
        let direct = self.direct
        let ticket = beginJob()

        Task { @MainActor in
            do {
                let started = Date()
                let raw = try await direct.transcribe(audio: audio, endpoint: endpoint, vocabulary: vocabulary)
                let sttMs = Date().timeIntervalSince(started) * 1000
                let result = await self.runCleanup(raw: raw, plan: plan)
                guard self.stillCurrent(ticket) else { return }
                self.finish(with: TranscriptionResponse(
                    text: result.text, rawText: raw,
                    timing: .init(stt: sttMs, cleanup: Double(result.ms), total: sttMs + Double(result.ms))),
                    engine: .direct, cleanupLabel: result.label, warning: result.warning)
            } catch {
                guard self.stillCurrent(ticket) else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    struct CleanupPlan {
        var engine: CleanupEngine
        var level: CleanupLevel
        var entries: [DictionaryEntry]
        var baseURL: URL?
        var token: String?
        var appName: String?
        var direct: DirectEndpoint?
        var directNeedsKey: Bool
    }

    private func cleanupPlan() -> CleanupPlan {
        CleanupPlan(engine: settings.cleanupEngine, level: settings.cleanup, entries: dictionary.entries,
                    baseURL: settings.backendURL, token: settings.trimmedToken, appName: capturedAppName,
                    direct: settings.directChatEndpoint(),
                    directNeedsKey: ProviderPreset.preset(id: settings.directChatProvider).needsKey)
    }

    struct CleanupResult {
        var text: String
        var ms: Int
        var label: String
        /// Set when the engine failed and the raw transcript was used instead.
        var warning: String?
    }

    /// The cleanup stage for a transcript already in hand. The Worker applies the dictionary
    /// post-pass itself; every other path runs the Swift port so the result is the same.
    ///
    /// Never throws: a cleanup engine that is down, overloaded or misconfigured must not
    /// cost the user the words they just said. Transient failures get one retry; after
    /// that the raw transcript goes through the dictionary and is inserted with a warning.
    private func runCleanup(raw: String, plan: CleanupPlan) async -> CleanupResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CleanupResult(text: "", ms: 0, label: "none") }
        let fallback = DictionaryReplacer.apply(trimmed, entries: plan.entries).trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan.level != .none else { return CleanupResult(text: fallback, ms: 0, label: "none") }

        let started = Date()
        var attempt = 0
        while true {
            attempt += 1
            do {
                var result = try await cleanupOnce(trimmed, plan: plan)
                if attempt > 1 { result.label += " (after a retry)" }
                return result
            } catch {
                let transient = AppController.isTransientCleanupError(error)
                Log.app.error("Cleanup attempt \(attempt, privacy: .public) failed (\(transient ? "transient" : "permanent", privacy: .public)): \(error.localizedDescription, privacy: .public)")
                if transient && attempt == 1 {
                    StatusOverlay.shared.show("Cleanup failed; retrying", tone: .working)
                    try? await Task.sleep(for: .seconds(AppController.cleanupRetryDelay))
                    continue
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let why = AppController.shortCleanupFailure(error)
                return CleanupResult(text: fallback, ms: ms,
                                     label: "failed (\(why)); raw text kept",
                                     warning: "Cleanup unavailable (\(why)); inserted the raw transcript")
            }
        }
    }

    /// Worth one retry: the provider is unreachable, overloaded or throwing 5xx. Bad keys,
    /// bad configuration and rejected requests are not going to pass a second later.
    nonisolated static func isTransientCleanupError(_ error: Error) -> Bool {
        switch error {
        case DirectError.transport, BackendError.transport: return true
        case DirectError.http(_, let status, _): return AppController.isTransientStatus(status)
        case BackendError.http(let status, _): return AppController.isTransientStatus(status)
        case is URLError: return true
        default: return false
        }
    }

    nonisolated static func isTransientStatus(_ status: Int) -> Bool {
        status == 408 || status == 429 || status >= 500
    }

    /// A few words for the pill and the history row.
    nonisolated static func shortCleanupFailure(_ error: Error) -> String {
        switch error {
        case DirectError.http(let provider, let status, _): return "\(provider) \(status)"
        case BackendError.http(let status, _): return "Worker \(status)"
        case DirectError.transport, BackendError.transport, is URLError: return "no connection"
        case DirectError.missingKey(let provider): return "no \(provider) key"
        default: return String(error.localizedDescription.prefix(60))
        }
    }

    /// One attempt at the selected engine. Throws on anything but success.
    private func cleanupOnce(_ trimmed: String, plan: CleanupPlan) async throws -> CleanupResult {
        let started = Date()
        switch plan.engine {
        case .worker:
            guard let baseURL = plan.baseURL else { throw BackendError.badURL }
            StatusOverlay.shared.show("Cleaning up", tone: .working)
            let response = try await client.cleanup(CleanupRequest(
                baseURL: baseURL, token: plan.token, text: trimmed,
                dictionaryJSON: DictionaryCodec.encodeForRequest(plan.entries), cleanup: plan.level, appName: plan.appName))
            return CleanupResult(text: response.text,
                                 ms: Int(response.timing?.cleanup ?? Date().timeIntervalSince(started) * 1000),
                                 label: "Worker")
        case .direct:
            guard let endpoint = plan.direct else {
                throw DirectError.badResponse("a usable cleanup provider (check Settings → Providers)")
            }
            if plan.directNeedsKey && (endpoint.apiKey ?? "").isEmpty {
                throw DirectError.missingKey(endpoint.providerName)
            }
            StatusOverlay.shared.show("Cleaning up via \(endpoint.providerName)", tone: .working)
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
            return CleanupResult(text: DictionaryReplacer.apply(text, entries: plan.entries).trimmingCharacters(in: .whitespacesAndNewlines),
                                 ms: ms, label: label)
        case .apple:
            StatusOverlay.shared.show("Cleaning up on this Mac", tone: .working)
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
            return CleanupResult(text: DictionaryReplacer.apply(text, entries: plan.entries).trimmingCharacters(in: .whitespacesAndNewlines),
                                 ms: ms, label: label)
        }
    }

    /// On-device Parakeet, then whichever cleanup engine is selected. With a streaming session most of the audio is
    /// already decoded; without one (model still loading) the whole recording runs now.
    private func transcribeLocally(_ audio: Data, session: StreamingSession?) {
        let transcriber = LocalTranscriber.shared
        StatusOverlay.shared.show(
            session != nil ? "Finishing up"
                : transcriber.state == .ready ? "Transcribing on this Mac" : "Loading speech model (first time takes a while)",
            tone: .working
        )
        let pcm = WAV.pcm16(fromFile: audio)
        let plan = cleanupPlan()
        let ticket = beginJob()

        Task { @MainActor in
            do {
                let started = Date()
                let raw: String
                if let session {
                    do {
                        raw = try await session.finish()
                    } catch {
                        // The full recording is still in hand; decode it the slow way.
                        Log.asr.error("Streaming session failed, falling back to whole-clip transcription: \(error.localizedDescription, privacy: .public)")
                        raw = try await transcriber.transcribe(pcm16: pcm)
                    }
                } else {
                    raw = try await transcriber.transcribe(pcm16: pcm)
                }
                let sttMs = Date().timeIntervalSince(started) * 1000
                let result = await self.runCleanup(raw: raw, plan: plan)
                guard self.stillCurrent(ticket) else { return }
                self.finish(with: TranscriptionResponse(
                    text: result.text, rawText: raw,
                    timing: .init(stt: sttMs, cleanup: Double(result.ms), total: sttMs + Double(result.ms))),
                    engine: .local, cleanupLabel: result.label, warning: result.warning)
            } catch {
                guard self.stillCurrent(ticket) else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func finish(with response: TranscriptionResponse, engine: TranscriptionMode, cleanupLabel: String, warning: String? = nil) {
        cancelProcessingWatchdog()
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = text
        guard !text.isEmpty else {
            state = .idle
            StatusOverlay.shared.flash("Nothing was said", tone: .failure)
            return
        }
        let outcome = TextInserter.insert(text)
        DictationHistory.shared.add(DictationRecord(
            date: Date(), engine: engine, appName: capturedAppName,
            rawText: response.rawText ?? text, finalText: text,
            sttMs: Int(response.timing?.stt ?? 0), cleanupMs: Int(response.timing?.cleanup ?? 0),
            insertion: outcome.historyLabel, cleanupLabel: cleanupLabel))
        if let message = outcome.userMessage {
            state = .failed(message)
            StatusOverlay.shared.flash(message, tone: .failure)
            resetStateSoon()
        } else if let warning {
            state = .idle
            StatusOverlay.shared.flash(warning, tone: .failure, after: 3.5)
        } else {
            state = .idle
            StatusOverlay.shared.hide()
        }
        let engineLabel: String
        switch engine {
        case .local: engineLabel = "on this Mac (Parakeet v3)"
        case .direct: engineLabel = "provider, direct"
        case .cloud: engineLabel = "cloud (Worker)"
        }
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
        cancelProcessingWatchdog()
        rightOptionDown = false
        recorder.cancel()
        streamingSession?.cancel()
        streamingSession = nil
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
    /// Sparkle. Starting the updater here also schedules the daily background check.
    @MainActor static let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.accessory)
            AppController.shared.startMonitoring()
            askForMissingPermissions()
            if AppSettings.shared.transcriptionMode == .local {
                LocalTranscriber.shared.prepare()
            }
            if AppSettings.shared.cleanupEngine == .apple {
                AppleCleanup.shared.prewarm()
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
        MainWindow.shared.show(.permissions)
    }
}

@main
struct AsideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(nsImage: AsideIcon.menuBarImage(for: controller.state))
                .accessibilityLabel("Aside")
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var localTranscriber = LocalTranscriber.shared

    private var engineLine: String {
        switch settings.transcriptionMode {
        case .cloud: return "Engine: cloud (Worker)"
        case .direct: return "Engine: \(settings.directSttEndpoint()?.label ?? "direct provider (not configured)")"
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
        if let warning = controller.secureInputWarning {
            Text(warning)
        }

        Button(controller.state == .recording ? "Stop Dictation"
               : controller.state == .processing ? "Cancel Dictation" : "Start Dictation") {
            controller.toggle()
        }
        .keyboardShortcut("d")

        if !controller.lastText.isEmpty {
            Button("Copy Last Transcript") { controller.copyLastToClipboard() }
        }

        Divider()

        Button("Recent Dictations…") { MainWindow.shared.show(.history) }
            .keyboardShortcut("h")
        Button("Dictionary…") { MainWindow.shared.show(.dictionary) }
        Button("Settings…") { MainWindow.shared.show(.general) }
            .keyboardShortcut(",")
        Button("Permissions…") { MainWindow.shared.show(.permissions) }

        Divider()

        Button("Check for Updates…") {
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.updater.checkForUpdates(nil)
        }
        Text("Aside \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")

        Divider()

        Button("Quit Aside") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// A listen-only session event tap for `flagsChanged`, run on its own thread so the
/// window server always gets a prompt answer no matter what the main thread is doing.
/// The callbacks are invoked on the tap thread and must hop to wherever they need to be.
final class FlagsTap: @unchecked Sendable {
    typealias FlagsHandler = @Sendable (_ keyCode: Int64, _ flags: UInt64, _ timestamp: TimeInterval) -> Void
    typealias DisabledHandler = @Sendable (_ reason: String) -> Void

    private let onFlagsChanged: FlagsHandler
    private let onDisabled: DisabledHandler
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(onFlagsChanged: @escaping FlagsHandler, onDisabled: @escaping DisabledHandler) {
        self.onFlagsChanged = onFlagsChanged
        self.onDisabled = onDisabled
    }

    /// Creates the tap and starts its thread. False when the tap cannot be created, which
    /// in practice means the process is not trusted for Accessibility.
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<FlagsTap>.fromOpaque(info).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout:
                tap.onDisabled("timeout")
            case .tapDisabledByUserInput:
                tap.onDisabled("user input")
            case .flagsChanged:
                tap.onFlagsChanged(
                    event.getIntegerValueField(.keyboardEventKeycode),
                    event.flags.rawValue,
                    // Same clock as NSEvent.timestamp: seconds since boot.
                    TimeInterval(event.timestamp) / 1_000_000_000
                )
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .listenOnly, eventsOfInterest: mask,
                                           callback: callback, userInfo: info)
        else { return false }
        self.port = port

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            lock.lock()
            runLoop = loop
            lock.unlock()
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.codywright.aside.flags-tap"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return true
    }

    var isEnabled: Bool {
        guard let port else { return false }
        return CGEvent.tapIsEnabled(tap: port)
    }

    /// Re-enables a tap macOS switched off. False when it stays off, in which case the
    /// owner should throw this one away and start another.
    func enable() -> Bool {
        guard let port else { return false }
        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port)
    }

    func stop() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        lock.lock()
        let loop = runLoop
        runLoop = nil
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
        port = nil
        thread = nil
    }
}
