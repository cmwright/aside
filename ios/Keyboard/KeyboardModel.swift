import Foundation
import UIKit
import os

/// Everything the keyboard knows: whether there is a session, what a dictation is doing,
/// and how to get text into the document. All of it goes through the App Group directory
/// described in `AsideIPC`.
@MainActor
final class KeyboardModel: ObservableObject {
    enum State: Equatable {
        /// Without Full Access the App Group is not even readable.
        case noFullAccess
        case noSession
        case ready
        case listening
        case transcribing
        case error(String)

        var text: String {
            switch self {
            case .noFullAccess: return "Turn on Allow Full Access"
            case .noSession: return "Start a session"
            case .ready: return "Ready"
            case .listening: return "Listening…"
            case .transcribing: return "Transcribing…"
            case .error(let message): return message
            }
        }

        var isTappableForSession: Bool { self == .noSession }
        var canDictate: Bool { self == .ready || self == .listening || self == .transcribing }
    }

    private static let log = Logger(subsystem: "com.codywright.aside", category: "keyboard")

    /// The app is asked to start a session through its URL scheme.
    static let startSessionURL = URL(string: "aside://session/start")!
    /// The app writes a `recording` result within a poll or two of the start command. If
    /// nothing appears in this long, the app is not running behind that session file.
    private static let firstAnswerTimeout: TimeInterval = 6
    /// Once it has answered once, a dictation can legitimately take a while (90 s watchdog
    /// plus a slow cleanup call), but not forever.
    private static let finishTimeout: TimeInterval = 180

    @Published private(set) var state: State = .noSession
    @Published var showsGlobe = false

    weak var controller: KeyboardViewController?

    private var ipc: AsideIPCStore?
    private var trigger = TriggerLogic()
    private var inFlight: UUID?
    private var inFlightSince: Date?
    /// Whether the app has written anything at all for the dictation in flight.
    private var sawAnswer = false
    /// Set when the app failed to answer: sessions started before this are treated as
    /// stale, so the status line offers "Start a session" instead of a false "Ready".
    private var distrustSessionsBefore: Date?
    private var pollTimer: Timer?
    private var resultObserver: DarwinObserver?
    private var tapWindowTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func start() {
        guard controller?.hasFullAccess == true else {
            ipc = nil
            state = .noFullAccess
            return
        }
        ipc = AsideIPCStore.appGroup()
        guard ipc != nil else {
            state = .noFullAccess
            return
        }
        resultObserver = DarwinObserver(name: AsideIPC.resultNotification) { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        retimePolling()
        refresh()
    }

    func stop() {
        // Leaving a recording running with the keyboard gone would keep the app's
        // microphone open for nothing.
        if inFlight != nil { cancel() }
        tapWindowTask?.cancel()
        errorTask?.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
        resultObserver = nil
        trigger.reset()
    }

    // MARK: - The mic button

    /// Touch down. Hold-to-talk starts here; a double tap latches, mirroring the Mac.
    func micDown() {
        guard let ipc, state.canDictate || state == .noSession else { return }
        guard hasUsableSession(ipc) else {
            state = .noSession
            return
        }
        switch trigger.keyDown(at: Date().timeIntervalSinceReferenceDate) {
        case .start:
            begin()
        case .stopLatched:
            finishRecording()
        case .latch:
            // Already recording; the second press just means "keep going hands-free".
            break
        default:
            break
        }
    }

    /// Touch up.
    func micUp() {
        switch trigger.keyUp(at: Date().timeIntervalSinceReferenceDate) {
        case .send:
            finishRecording()
        case .tapPending:
            scheduleTapWindow()
        default:
            break
        }
    }

    var isLatched: Bool { trigger.latched }

    private func scheduleTapWindow() {
        tapWindowTask?.cancel()
        let window = trigger.doubleTapWindow
        tapWindowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if self.trigger.tapWindowExpired() == .discard { self.cancel() }
        }
    }

    private func begin() {
        guard let ipc else { return }
        let context = AsideIPC.trimContext(controller?.textDocumentProxy.documentContextBeforeInput)
        let command = DictationCommand(action: .start, contextBefore: context)
        guard send(command, using: ipc) else { return }
        inFlight = command.id
        inFlightSince = Date()
        sawAnswer = false
        state = .listening
        retimePolling()
    }

    private func finishRecording() {
        guard let ipc, inFlight != nil else { return }
        tapWindowTask?.cancel()
        guard send(DictationCommand(action: .stop), using: ipc) else { return }
        state = .transcribing
    }

    private func cancel() {
        guard let ipc else { return }
        tapWindowTask?.cancel()
        _ = send(DictationCommand(action: .cancel), using: ipc)
        if let id = inFlight { ipc.removeResult(id: id) }
        forget()
        refresh()
    }

    private func send(_ command: DictationCommand, using ipc: AsideIPCStore) -> Bool {
        do {
            try ipc.writeCommand(command)
            DarwinNotifier.post(AsideIPC.commandNotification)
            return true
        } catch {
            KeyboardModel.log.error("Could not write a command: \(error.localizedDescription, privacy: .public)")
            show(error: "Could not reach the Aside app.")
            return false
        }
    }

    // MARK: - Watching for the answer

    /// Fast while a dictation is in flight, lazily otherwise. Darwin notifications wake us
    /// sooner when they arrive, but they are best-effort, so the timer is the floor.
    private func retimePolling() {
        pollTimer?.invalidate()
        guard ipc != nil else { return }
        let timer = Timer(timeInterval: inFlight == nil ? 1.0 : AsideIPC.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func tick() {
        guard let ipc else { return }
        guard let id = inFlight else {
            refresh()
            return
        }
        if let result = ipc.readResult(id: id) {
            sawAnswer = true
            apply(result, id: id, ipc: ipc)
            return
        }
        // No file yet is normal for the first few hundred milliseconds. A session that went
        // away underneath us, or an app iOS has killed, is not.
        if !AsideIPC.isActive(ipc.readSession(), at: Date()) {
            forget()
            state = .noSession
            return
        }
        guard let since = inFlightSince else { return }
        let waited = Date().timeIntervalSince(since)
        if !sawAnswer, waited > KeyboardModel.firstAnswerTimeout {
            // The session file says active but nobody is home: stop believing it until a
            // newer one is written.
            distrustSessionsBefore = Date()
            forget()
            show(error: "Aside is not running. Tap “Start a session”.")
        } else if sawAnswer, waited > KeyboardModel.finishTimeout {
            forget()
            show(error: "The Aside app did not finish.")
        }
    }

    /// Drops the in-flight dictation without telling the app anything.
    private func forget() {
        inFlight = nil
        inFlightSince = nil
        sawAnswer = false
        trigger.reset()
        retimePolling()
    }

    private func apply(_ result: DictationResult, id: UUID, ipc: AsideIPCStore) {
        switch result.status {
        case .recording:
            if state != .listening { state = .listening }
        case .processing:
            if state != .transcribing { state = .transcribing }
        case .done:
            insert(result.text ?? "")
            clearInFlight(id: id, ipc: ipc)
            state = .ready
        case .failed:
            clearInFlight(id: id, ipc: ipc)
            show(error: result.error ?? "Dictation failed.")
        }
    }

    private func clearInFlight(id: UUID, ipc: AsideIPCStore) {
        ipc.removeResult(id: id)
        forget()
    }

    /// Re-reads the session file; cheap enough for the idle 1 s tick.
    func refresh() {
        guard controller?.hasFullAccess == true, let ipc else {
            state = .noFullAccess
            return
        }
        if case .error = state { return }
        state = hasUsableSession(ipc) ? .ready : .noSession
    }

    /// A session counts only if it is active and was started after the last time the app
    /// failed to answer — otherwise a session file left behind by a killed app would keep
    /// the keyboard saying "Ready" forever.
    private func hasUsableSession(_ ipc: AsideIPCStore) -> Bool {
        guard let session = ipc.readSession(), AsideIPC.isActive(session, at: Date()) else { return false }
        guard let distrust = distrustSessionsBefore else { return true }
        return session.startedAt > distrust
    }

    private func show(error message: String) {
        state = .error(message)
        errorTask?.cancel()
        errorTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if case .error = self.state { self.state = .noSession }
            self.refresh()
        }
    }

    // MARK: - The document

    /// Insert at the cursor, with the same leading-space rule the Mac inserter uses. The
    /// context is read now rather than when the dictation started, because the user may
    /// have moved the cursor while speaking.
    private func insert(_ text: String) {
        guard !text.isEmpty, let proxy = controller?.textDocumentProxy else { return }
        let context = AsideIPC.trimContext(proxy.documentContextBeforeInput)
        proxy.insertText(AsideIPC.needsLeadingSpace(contextBefore: context, text: text) ? " " + text : text)
    }

    func nextKeyboard() {
        controller?.advanceToNextKeyboard()
    }

    func insertSpace() { controller?.textDocumentProxy.insertText(" ") }
    func insertReturn() { controller?.textDocumentProxy.insertText("\n") }
    func deleteBackward() { controller?.textDocumentProxy.deleteBackward() }
}
