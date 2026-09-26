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
    /// The key is down and the audio engine is coming up. Usually tens of milliseconds;
    /// seconds while an input device is switching.
    case starting
    case recording
    case processing
    case failed(String)

    var menuTitle: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Starting…"
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

    @Published private(set) var state: DictationState = .idle {
        didSet { syncEscapeTap() }
    }
    /// Name of the process holding secure keyboard entry, while one does. Global key
    /// monitors receive nothing then, so Right Option is dead until it lets go.
    @Published private(set) var secureInputHolder: String?
    @Published private(set) var lastText: String = ""
    /// One line for the menu: which engine handled the last dictation and how long it took.
    @Published private(set) var lastRunSummary: String = ""

    private let recorder = Recorder()
    private let pipeline = DictationPipeline()
    private var processingTask: Task<Void, Never>?
    private var recordingID: UUID?
    private var recoveryAudio: Data?
    private var recoveryPlan: DictationPlan?
    private var checkpoint: PipelineResult?
    private var recoveryRecordID: UUID?
    private var recoveryDelivered = false
    @Published private(set) var recoveryAvailable = false
    private let settings = AppSettings.shared
    private let dictionary = DictionaryStore.shared

    /// The listen-only session tap that sees Right Option while any app is frontmost. It
    /// lives on its own thread (`EventTap`) so a busy main thread can never make macOS
    /// judge the tap slow and switch it off.
    private var flagsTap: EventTap?
    /// Active `keyDown` tap that turns Escape into a cancel while a dictation is in flight,
    /// and swallows it so the frontmost app does not also act on it. See `syncEscapeTap`.
    private var escapeTap: EventTap?
    private var wakeObservers: [any NSObjectProtocol] = []
    private var capturedAppName: String?
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
    /// Incremented whenever a recording is discarded or fails, so an engine start still in
    /// flight on the recorder's queue knows to tear itself down instead of going live.
    private var startTicket = 0
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
        let tap = EventTap(
            types: [.flagsChanged], options: .listenOnly, label: "flags-tap",
            handler: { _, keyCode, flags, timestamp in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        AppController.shared.handleFlagsChanged(keyCode: keyCode, flags: flags, timestamp: timestamp)
                    }
                }
                return false
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
    /// Use the state carried by the event, not a separate `NSEvent.modifierFlags`
    /// query. That query can disagree with the event by the time our main-queue
    /// handler runs, causing a valid press to be interpreted as a release.
    nonisolated static func rightOptionIsDown(eventFlags: UInt) -> Bool {
        eventFlags & rightOptionDeviceMask != 0
    }

    /// `flags` is the event's `CGEventFlags` raw value, which carries the same device bits
    /// AppKit exposes in `NSEvent.modifierFlags.rawValue`.
    private func handleFlagsChanged(keyCode: Int64, flags: UInt64, timestamp: TimeInterval) {
        guard settings.holdRightOption, keyCode == Int64(AppController.rightOptionKeyCode) else { return }
        let isDown = AppController.rightOptionIsDown(
            eventFlags: UInt(truncatingIfNeeded: flags)
        )
        Log.app.debug("flagsChanged right-option down=\(isDown, privacy: .public)")
        guard isDown != rightOptionDown else { return }
        rightOptionDown = isDown
        trigger.tapBehavior = settings.tapBehavior
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
            let window = trigger.tapWindow
            tapWindowTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(window))
                guard !Task.isCancelled else { return }
                let controller = AppController.shared
                controller.perform(controller.trigger.tapWindowExpired())
            }
        case .latch:
            tapWindowTask?.cancel()
            guard state == .recording || state == .starting else { trigger.reset(); return }
            StatusOverlay.shared.show("Listening — tap Right Option to stop", tone: .listening)
        case .discard:
            discardRecording()
        case .ignore:
            break
        }
    }

    // MARK: - Escape

    nonisolated static let escapeKeyCode = 53

    /// The Escape tap exists exactly while a dictation is in flight: starting, recording,
    /// or transcribing, right up to the paste. It is an active tap, so Escape reaches nobody
    /// else: a cancel must not also close whatever dialog is in front. Created and torn
    /// down on the state changes rather than left in place, so outside a dictation the app
    /// is not looking at keystrokes at all.
    private func syncEscapeTap() {
        let wanted = state == .starting || state == .recording || state == .processing
        if wanted, escapeTap == nil {
            let tap = EventTap(
                types: [.keyDown], options: .defaultTap, label: "escape-tap",
                handler: { type, keyCode, _, _ in
                    guard type == .keyDown, keyCode == Int64(AppController.escapeKeyCode) else { return false }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { AppController.shared.cancelFromEscape() }
                    }
                    return true
                },
                onDisabled: { reason in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Log.app.error("macOS disabled the Escape tap (\(reason, privacy: .public))")
                            _ = AppController.shared.escapeTap?.enable()
                        }
                    }
                }
            )
            if tap.start() {
                escapeTap = tap
            } else {
                Log.app.error("Could not create the Escape tap (Accessibility not granted?)")
            }
        } else if !wanted, let tap = escapeTap {
            escapeTap = nil
            tap.stop()
        }
    }

    /// Escape at any stage before the paste: throw away everything captured, or the result
    /// on its way back. The key may still be held (or latched); the trigger is reset so its
    /// release means nothing.
    private func cancelFromEscape() {
        if state == .processing {
            Log.app.notice("Dictation cancelled with Escape while transcribing")
            cancelProcessing()
            return
        }
        guard state == .starting || state == .recording else { return }
        Log.app.notice("Dictation cancelled with Escape")
        tapWindowTask?.cancel()
        trigger.reset()
        discardRecording()
        StatusOverlay.shared.flash("Cancelled", tone: .failure, after: 1.5)
    }

    // MARK: - Recording

    func toggle() {
        if state == .recording {
            endRecordingAndSend()
        } else if state == .starting {
            discardRecording()
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
        processingTask?.cancel()
        processingTask = nil
        clearRecovery(discardRecord: true)
        cancelProcessingWatchdog()
        // Still capturing the tail after the key-up: drop that too, at once.
        cancelCapture()
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
            controller.processingTask?.cancel()
            controller.processingTask = nil
            controller.jobTicket += 1
            if let checkpoint = controller.checkpoint {
                controller.finishPipeline(checkpoint, warning: "Cleanup took too long; raw transcript kept")
            } else {
                controller.fail("Transcription took too long. Retry the last recording from the menu.")
            }
        }
    }

    private func cancelProcessingWatchdog() {
        processingWatchdog?.cancel()
        processingWatchdog = nil
    }

    func beginRecording() {
        guard state != .starting, state != .recording, state != .processing else { return }
        clearRecovery(discardRecord: false)
        capturedAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        let captureID = UUID()
        recordingID = captureID
        startTicket += 1
        let ticket = startTicket
        state = .starting
        // The engine starts on the recorder's own queue so a slow coreaudiod cannot freeze
        // the menu bar or the key-up handler. If it drags on, say so instead of showing
        // nothing; on a healthy machine this task loses the race and never shows.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard self.startTicket == ticket, self.state == .starting else { return }
            StatusOverlay.shared.show("Waiting for the microphone…", tone: .working)
        }
        Task { @MainActor in
            do {
                try await recorder.start(inputDeviceUID: settings.inputDeviceUID, id: captureID)
            } catch {
                guard self.startTicket == ticket, self.state == .starting else { return }
                self.fail(error.localizedDescription)
                return
            }
            guard self.startTicket == ticket, self.state == .starting else {
                // The key came up, or the app quit, while the engine was still starting:
                // nothing was captured, so there is nothing to send.
                await self.recorder.cancel(id: captureID)
                return
            }
            self.state = .recording
            // Without Accessibility we can still record, but insertion will fall all the way
            // back to the clipboard — say so instead of surprising the user later.
            StatusOverlay.shared.show(
                self.accessibilityGranted
                    ? "Listening"
                    : "Listening — Accessibility not granted, open Permissions… or the text only reaches the clipboard",
                tone: .listening
            )
            self.startWatchdog()
            self.play(.start)
        }
    }

    /// Abandons the recording, or the engine start still in flight, without transcribing.
    private func discardRecording() {
        startTicket += 1
        cancelWatchdog()
        cancelCapture()
        state = .idle
        StatusOverlay.shared.hide()
    }

    /// If the key-up is never delivered (screen lock, secure input field, sleep, a monitor
    /// that stopped firing) the engine would record forever. Stop it ourselves.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(AppController.maximumRecordingSeconds))
            guard !Task.isCancelled else { return }
            let controller = AppController.shared
            guard controller.state == .recording else { return }
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
        if state == .starting {
            // The key came up before the engine was even running, so nothing was captured.
            // Say so: with AirPods as the input this takes a second or two, and a silent
            // vanish reads as "nothing works".
            tapWindowTask?.cancel()
            trigger.reset()
            discardRecording()
            StatusOverlay.shared.flash("The microphone was not ready yet — hold until you see Listening", tone: .failure, after: 3)
            return
        }
        guard state == .recording else { return }
        tapWindowTask?.cancel()
        trigger.reset()
        cancelWatchdog()
        // Processing from here: a second key-up or a Stop from the menu while the stop
        // is on the recorder's queue must not start a second stop. The recorder keeps
        // capturing for `Recorder.trailingCapture` first, so the end of the last word,
        // still in flight when the key came up, lands in the recording.
        state = .processing
        let ticket = beginJob()
        let captureID = recordingID
        let plan = DictationPlan(settings: settings, entries: dictionary.entries, appName: capturedAppName)
        processingTask = Task { @MainActor in
            do {
                let audio = try await recorder.stop(id: captureID)
                try Task.checkCancellation()
                guard stillCurrent(ticket) else { return }
                recordingID = nil
                self.play(.stop)
                recoveryAudio = audio
                recoveryPlan = plan
                recoveryAvailable = true
                await process(audio: audio, plan: plan, ticket: ticket)
            } catch {
                guard stillCurrent(ticket), !Task.isCancelled else { return }
                if error is CancellationError || isRecorderCancelled(error) { return }
                if case RecorderError.tooShort = error {
                    cancelProcessingWatchdog()
                    state = .idle
                    StatusOverlay.shared.hide()
                } else {
                    fail(error.localizedDescription)
                }
            }
        }
    }

    private func process(audio: Data, plan: DictationPlan, ticket: Int) async {
        StatusOverlay.shared.show("Transcribing", tone: .working)
        do {
            let result = try await pipeline.run(audio: audio, plan: plan) { [weak self] raw in
                await self?.saveCheckpoint(raw, ticket: ticket)
            }
            guard stillCurrent(ticket), !Task.isCancelled else { return }
            finishPipeline(result)
        } catch {
            guard stillCurrent(ticket), !Task.isCancelled else { return }
            fail(error.localizedDescription)
        }
    }

    private func saveCheckpoint(_ raw: PipelineResult, ticket: Int) {
        guard stillCurrent(ticket) else { return }
        checkpoint = raw
        let id = recoveryRecordID ?? UUID()
        recoveryRecordID = id
        if !raw.text.isEmpty {
            DictationHistory.shared.add(DictationRecord(id: id, date: Date(), engine: raw.engine,
                appName: capturedAppName, rawText: raw.raw, finalText: raw.text, sttMs: raw.sttMs,
                cleanupMs: 0, cleanupLabel: "Raw transcript saved; cleanup pending"), log: false)
        }
        StatusOverlay.shared.show("Cleaning up", tone: .working)
    }

    private func finishPipeline(_ result: PipelineResult, warning: String? = nil) {
        let insert = !recoveryDelivered
        processingTask = nil
        finish(with: TranscriptionResponse(text: result.text, rawText: result.raw,
            timing: .init(stt: Double(result.sttMs), cleanup: Double(result.cleanupMs),
                          total: Double(result.sttMs + result.cleanupMs))),
            engine: result.engine, cleanupLabel: warning == nil ? result.cleanupLabel : "timed out; raw text kept",
            warning: warning ?? result.warning, insert: insert)
        recoveryDelivered = true
        // Successful text is already in history; only failures retain temporary retry data.
        if warning == nil, result.warning == nil { clearRecovery(discardRecord: false) }
    }

    func retryLastDictation() {
        guard state != .starting, state != .recording, state != .processing,
              let audio = recoveryAudio, let plan = recoveryPlan else { return }
        state = .processing
        let ticket = beginJob()
        processingTask = Task { @MainActor in
            if let checkpoint {
                do {
                    StatusOverlay.shared.show("Retrying cleanup", tone: .working)
                    let result = try await pipeline.clean(checkpoint, plan: plan)
                    guard stillCurrent(ticket), !Task.isCancelled else { return }
                    finishPipeline(result)
                } catch {
                    guard stillCurrent(ticket), !Task.isCancelled else { return }
                    fail(error.localizedDescription)
                }
            } else {
                await process(audio: audio, plan: plan, ticket: ticket)
            }
        }
    }

    private func clearRecovery(discardRecord: Bool) {
        if discardRecord, !recoveryDelivered, let id = recoveryRecordID { DictationHistory.shared.remove(ids: [id]) }
        recoveryAudio = nil
        recoveryPlan = nil
        checkpoint = nil
        recoveryRecordID = nil
        recoveryAvailable = false
        recoveryDelivered = false
    }

    private func isRecorderCancelled(_ error: Error) -> Bool {
        if case RecorderError.cancelled = error { return true }; return false
    }

    private func cancelCapture() {
        guard let id = recordingID else { return }
        recordingID = nil
        Task { await recorder.cancel(id: id) }
    }

    nonisolated static func isTransientCleanupError(_ error: Error) -> Bool { DictationPipeline.isTransient(error) }
    nonisolated static func isTransientStatus(_ status: Int) -> Bool { status == 408 || status == 429 || status >= 500 }
    nonisolated static func shortCleanupFailure(_ error: Error) -> String { DictationPipeline.shortFailure(error) }

    private func finish(with response: TranscriptionResponse, engine: TranscriptionMode, cleanupLabel: String, warning: String? = nil, insert: Bool = true) {
        cancelProcessingWatchdog()
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastText = text
        guard !text.isEmpty else {
            state = .idle
            StatusOverlay.shared.flash("Nothing was said", tone: .failure)
            return
        }
        let outcome: TextInserter.Outcome
        if insert { outcome = TextInserter.insert(text) }
        else {
            // The raw fallback was already inserted. A retry is copied for review, never
            // appended to whatever document happens to have focus now.
            copyLastToClipboard()
            outcome = .clipboardOnly
        }
        DictationHistory.shared.add(DictationRecord(id: recoveryRecordID ?? UUID(),
            date: Date(), engine: engine, appName: capturedAppName,
            rawText: response.rawText ?? text, finalText: text,
            sttMs: Int(response.timing?.stt ?? 0), cleanupMs: Int(response.timing?.cleanup ?? 0),
            insertion: outcome.historyLabel, cleanupLabel: cleanupLabel))
        if !insert {
            state = .idle
            StatusOverlay.shared.flash("Retried text copied; paste to replace the earlier text", tone: .working, after: 3)
        } else if let message = outcome.userMessage {
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
        startTicket += 1
        cancelCapture()
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
        // Unit tests must never install global taps, request permissions or load models.
        guard NSClassFromString("XCTestCase") == nil else { return }
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

    /// The dictionary autosave is debounced; an edit made in the last half second before
    /// quitting (or before Sparkle relaunches for an update) still needs to reach the disk.
    func applicationWillTerminate(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        MainActor.assumeIsolated { DictionaryStore.shared.save(); DictationHistory.shared.flushBeforeTermination() }
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

        Button(controller.state == .recording || controller.state == .starting ? "Stop Dictation"
               : controller.state == .processing ? "Cancel Dictation" : "Start Dictation") {
            controller.toggle()
        }
        .keyboardShortcut("d")

        if controller.recoveryAvailable {
            Button("Retry Last Dictation") { controller.retryLastDictation() }
        }

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

/// A session event tap run on its own thread, so the window server always gets a prompt
/// answer no matter what the main thread is doing. Two are used: the listen-only
/// `flagsChanged` tap behind Right Option, which lives for the life of the app, and the
/// `keyDown` tap behind Escape, which exists only while a dictation is in flight so the app
/// never sees a keystroke it has no business with. The handler is invoked on the tap thread
/// and must hop to wherever it needs to be; returning true swallows the event, which only
/// an active (`.defaultTap`) tap can do.
final class EventTap: @unchecked Sendable {
    typealias Handler = @Sendable (_ type: CGEventType, _ keyCode: Int64, _ flags: UInt64, _ timestamp: TimeInterval) -> Bool
    typealias DisabledHandler = @Sendable (_ reason: String) -> Void

    private let types: [CGEventType]
    private let options: CGEventTapOptions
    private let label: String
    private let handler: Handler
    private let onDisabled: DisabledHandler
    private let lock = NSLock()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(types: [CGEventType], options: CGEventTapOptions, label: String,
         handler: @escaping Handler, onDisabled: @escaping DisabledHandler) {
        self.types = types
        self.options = options
        self.label = label
        self.handler = handler
        self.onDisabled = onDisabled
    }

    /// Creates the tap and starts its thread. False when the tap cannot be created, which
    /// in practice means the process is not trusted for Accessibility.
    func start() -> Bool {
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        let info = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<EventTap>.fromOpaque(info).takeUnretainedValue()
            switch type {
            case .tapDisabledByTimeout:
                tap.onDisabled("timeout")
            case .tapDisabledByUserInput:
                tap.onDisabled("user input")
            default:
                let swallow = tap.handler(
                    type,
                    event.getIntegerValueField(.keyboardEventKeycode),
                    event.flags.rawValue,
                    // Same clock as NSEvent.timestamp: seconds since boot.
                    TimeInterval(event.timestamp) / 1_000_000_000
                )
                if swallow { return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: options, eventsOfInterest: mask,
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
        thread.name = "com.codywright.aside.\(label)"
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
