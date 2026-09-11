@preconcurrency import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    case needsMicrophonePrompt
    case engineFailed(String)
    case inputNotReady(String)
    case notRunning
    case tooShort

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is off. Turn it on in Settings > Aside > Microphone."
        case .needsMicrophonePrompt:
            return "Allow microphone access, then start the session again."
        case .engineFailed(let message):
            return "Could not start the microphone: \(message)"
        case .inputNotReady(let input):
            return "The microphone (\(input)) is not ready yet — try again in a moment."
        case .notRunning:
            return "No session is running."
        case .tooShort:
            return "Too short — hold the button while you speak."
        }
    }
}

/// The microphone for a whole session. `startSession` configures and activates the audio
/// session and starts `AVAudioEngine`; the engine then runs until `stopSession`, which is
/// what keeps the app alive in the background under the `audio` background mode. Audio is
/// only retained between `beginDictation` and `endDictation`.
@MainActor
final class SessionRecorder {
    /// Recordings shorter than this are treated as an accidental tap.
    nonisolated static let minimumDuration: Double = 0.3

    private let engine = AVAudioEngine()
    private let sink = PCMSink()
    private var observers: [any NSObjectProtocol] = []

    private(set) var isRunning = false
    private(set) var isDictating = false
    /// Between an interruption beginning and ending (system dictation, Siri, a call). No
    /// tap is rebuilt while it is set: the hardware format is in flux, and installing a
    /// tap whose format disagrees with it is an uncatchable Objective-C exception.
    private var interrupted = false
    private var resumeTask: Task<Void, Never>?
    private var rebuildTask: Task<Void, Never>?

    var capturedSeconds: Double { sink.capturedSeconds }

    enum MicrophonePermission {
        case granted
        case denied
        case undetermined
    }

    static var microphonePermission: MicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default: return .undetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func startSession() throws {
        guard !isRunning else { return }
        switch SessionRecorder.microphonePermission {
        case .granted:
            break
        case .undetermined:
            // Starting the engine now would record silence behind the system dialog.
            Task { _ = await SessionRecorder.requestMicrophone() }
            throw RecorderError.needsMicrophonePrompt
        case .denied:
            throw RecorderError.microphoneDenied
        }

        let audioSession = AVAudioSession.sharedInstance()
        do {
            // .playAndRecord (not .record) so a session can survive alongside music and so
            // the app keeps the background audio assertion. .mixWithOthers means starting a
            // session never stops what the user is listening to. .allowBluetoothHFP lets a
            // Bluetooth headset's microphone be the input (AirPods, a car kit); the phone
            // switches such a headset from its music profile to the hands-free one, which
            // takes a moment, see `installTapAndStart`.
            try audioSession.setCategory(.playAndRecord, mode: .default,
                                         options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker])
            try audioSession.setActive(true, options: [])
        } catch {
            AudioTrace.write("session activation failed: \(error.localizedDescription)")
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        installObservers()
        isRunning = true
        do {
            try installTapAndStart()
            Log.audio.notice("Session audio engine started")
        } catch {
            // Typically a Bluetooth headset still switching profiles: the route exists but
            // the input has no format yet. The session stays up and the engine is retried
            // in the background; a dictation attempted before it is ready is refused with
            // a clear message rather than recording silence.
            Log.audio.error("Engine did not start at once: \(error.localizedDescription, privacy: .public)")
            restartEngine(reason: "start", firstDelay: .milliseconds(500))
        }
    }

    func stopSession() {
        guard isRunning else { return }
        isRunning = false
        isDictating = false
        interrupted = false
        resumeTask?.cancel()
        resumeTask = nil
        rebuildTask?.cancel()
        rebuildTask = nil
        sink.discard()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObservers()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        Log.audio.notice("Session audio engine stopped")
    }

    /// Called on the render thread with a 0...1 level for every chunk of a dictation.
    var levelHandler: (@Sendable (Float) -> Void)?

    /// True once the engine is actually pulling audio. Right after `startSession` it can
    /// be false for a moment (the audio session just activated, a Bluetooth headset is
    /// switching profiles) while the engine is retried in the background.
    var isInputReady: Bool { isRunning && engine.isRunning }

    func beginDictation() throws {
        guard isRunning else { throw RecorderError.notRunning }
        guard engine.isRunning else { throw RecorderError.inputNotReady(AudioTrace.currentInput) }
        sink.beginCapture(levelListener: levelHandler)
        isDictating = true
        Log.audio.info("Dictation started")
    }

    /// Ends the dictation and returns a finished WAV file, or throws `.tooShort`.
    func endDictation() throws -> Data {
        guard isDictating else { throw RecorderError.tooShort }
        isDictating = false
        let pcm = sink.endCapture()
        let seconds = WAV.duration(ofPCM16: pcm.count)
        Log.audio.info("Dictation stopped: \(seconds, format: .fixed(precision: 2), privacy: .public)s")
        guard seconds >= SessionRecorder.minimumDuration else { throw RecorderError.tooShort }
        return WAV.file(pcm16: pcm)
    }

    func cancelDictation() {
        guard isDictating else { return }
        isDictating = false
        sink.discard()
    }

    // MARK: - Plumbing

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let route = AudioTrace.routeDescription
        guard format.sampleRate > 0, format.channelCount > 0 else {
            AudioTrace.write("input not ready (\(route))")
            throw RecorderError.engineFailed("the input (\(AudioTrace.currentInput)) is not ready yet")
        }
        input.removeTap(onBus: 0)
        let sink = self.sink
        // The tap runs on AVFoundation's realtime thread; @Sendable keeps it out of the
        // main actor, which Swift 6 would otherwise assert on. `format: nil` makes the
        // tap take the node's format at install time rather than the one queried a moment
        // ago; a mismatch there raises an exception instead of an error. The sink builds
        // its converter from whatever format the buffers actually carry.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
            sink.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            AudioTrace.write("engine running: \(route), \(Int(format.sampleRate)) Hz × \(format.channelCount)")
        } catch {
            input.removeTap(onBus: 0)
            AudioTrace.write("engine start failed (\(route)): \(error.localizedDescription)")
            throw RecorderError.engineFailed(error.localizedDescription)
        }
    }

    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild(reason: "engine configuration change") }
        })
        // Plugging in headphones or a car kit changes the input format; so does a phone
        // call taking the microphone away and giving it back.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.rebuild(reason: "route change (\(AudioTrace.name(of: reason)))") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // Pull the one value out here: the Notification itself is not Sendable.
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(raw) }
        })
    }

    private func removeObservers() {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
    }

    /// A route change and an engine configuration change usually arrive together, and a
    /// Bluetooth headset switching profiles produces several in a row while the input has
    /// no usable format. Rebuilds are coalesced and retried rather than done at once.
    private func rebuild(reason: String) {
        guard isRunning else { return }
        guard !interrupted else {
            Log.audio.info("Ignoring a \(reason, privacy: .public) while interrupted")
            return
        }
        Log.audio.info("Input changed: \(reason, privacy: .public)")
        AudioTrace.write(reason)
        restartEngine(reason: reason, firstDelay: .milliseconds(300))
    }

    /// Stops the engine and starts it again on the current input, retrying for a few
    /// seconds: after a route change the hardware format settles a moment later, and a
    /// failed start is an error, not a crash. A dictation in flight cannot survive the
    /// gap, so it is dropped.
    private func restartEngine(reason: String, firstDelay: Duration) {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor [weak self] in
            for attempt in 1...6 {
                try? await Task.sleep(for: attempt == 1 ? firstDelay : .milliseconds(700))
                guard let self, !Task.isCancelled, self.isRunning, !self.interrupted else { return }
                if self.isDictating {
                    self.isDictating = false
                    self.sink.discard()
                }
                self.sink.invalidateConverter()
                self.engine.stop()
                do {
                    try self.installTapAndStart()
                    Log.audio.notice("Engine restarted after \(reason, privacy: .public) (attempt \(attempt, privacy: .public))")
                    return
                } catch {
                    Log.audio.error("Restart attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            AudioTrace.write("gave up restarting the engine after \(reason)")
        }
    }

    private func handleInterruption(_ raw: UInt?) {
        guard isRunning, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Log.audio.notice("Audio interrupted; dropping any in-flight dictation")
            interrupted = true
            resumeTask?.cancel()
            sink.discard()
            isDictating = false
            engine.stop()
        case .ended:
            interrupted = false
            resumeAfterInterruption()
        @unknown default:
            break
        }
    }

    /// The other party (system dictation, Siri, a call) has let go of the microphone, but
    /// the route and hardware format settle a moment later. Wait, then reactivate and
    /// rebuild, retrying a few times: a failed start here is an error, not a crash.
    private func resumeAfterInterruption() {
        resumeTask?.cancel()
        resumeTask = Task { @MainActor [weak self] in
            for attempt in 1...4 {
                try? await Task.sleep(for: .milliseconds(attempt == 1 ? 400 : 1000))
                guard let self, !Task.isCancelled, self.isRunning, !self.interrupted else { return }
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                    self.sink.invalidateConverter()
                    self.engine.stop()
                    try self.installTapAndStart()
                    Log.audio.notice("Resumed after interruption (attempt \(attempt, privacy: .public))")
                    return
                } catch {
                    Log.audio.error("Resume attempt \(attempt, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

/// The last few things the microphone did — which input the session runs on, route
/// changes, engine restarts and failures — shown under Settings so a report like "with
/// AirPods in I can't record" comes with the facts. Kept in the app's own defaults,
/// capped at twenty lines.
enum AudioTrace {
    private static let key = "audioTrace"

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append("\(stamp) \(line)")
        UserDefaults.standard.set(Array(lines.suffix(20)), forKey: key)
        Log.audio.info("\(line, privacy: .public)")
    }

    static var lines: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    /// "AirPods Pro (BluetoothHFP) → AirPods Pro (BluetoothHFP)".
    static var routeDescription: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        func list(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.isEmpty ? "none" : ports.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        }
        return "\(list(route.inputs)) → \(list(route.outputs))"
    }

    static var currentInput: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "no input"
    }

    static func name(of reason: AVAudioSession.RouteChangeReason?) -> String {
        switch reason {
        case .newDeviceAvailable: return "new device"
        case .oldDeviceUnavailable: return "device gone"
        case .categoryChange: return "category change"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "no suitable route"
        case .routeConfigurationChange: return "route configuration change"
        case .unknown, .none: return "unknown"
        @unknown default: return "other"
        }
    }
}
