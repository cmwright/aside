@preconcurrency import AVFoundation
import Foundation

/// Builds a 16 kHz mono 16-bit PCM WAV file — exactly what the HTTP contract asks for.
///
/// A copy of the same helper in `mac/Sources/Recorder.swift`. That file cannot be compiled
/// into this target: it reaches for `Permissions`, which is AppKit-only, and its recorder
/// buffers from `start()` to `stop()`, while a phone session keeps the engine running for
/// up to an hour and must hold nothing between dictations. See the report in PLAN-iOS.md.
enum WAV {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16

    static func file(pcm16: Data, sampleRate: Int = WAV.sampleRate, channels: Int = WAV.channels) -> Data {
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        var out = Data(capacity: 44 + pcm16.count)

        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }

        out.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm16.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // PCM chunk size
        append16(1)                        // format = PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(UInt16(bitsPerSample))
        out.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm16.count))
        out.append(pcm16)
        return out
    }

    /// The raw Int16 PCM inside a file produced by `file(pcm16:)` (canonical 44-byte header).
    static func pcm16(fromFile data: Data) -> Data {
        data.count > 44 ? Data(data.suffix(from: data.startIndex + 44)) : Data()
    }

    /// Seconds of audio in a raw Int16 mono buffer.
    static func duration(ofPCM16 bytes: Int, sampleRate: Int = WAV.sampleRate, channels: Int = WAV.channels) -> Double {
        let frames = Double(bytes) / Double(channels * bitsPerSample / 8)
        return frames / Double(sampleRate)
    }
}

/// Receives audio on the real-time render thread, converts to 16 kHz mono Int16, and keeps
/// it only while a dictation is actually in flight. Between dictations `append` converts
/// nothing and stores nothing: the engine stays running to hold the background audio
/// session, but the microphone's output is dropped on the floor.
private final class GatedSink: @unchecked Sendable {
    /// One-shot flag for the converter's input block. A reference type because Swift 6
    /// types that block as `@Sendable` even though `convert` runs it synchronously, and a
    /// captured `var` would be a data-race warning. Only ever touched under `lock`.
    private final class Handoff: @unchecked Sendable {
        var done = false
    }

    private let lock = NSLock()
    private var pcm = Data()
    private var capturing = false
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let handoff = Handoff()

    let outputFormat: AVAudioFormat = {
        // Force-unwrap: this combination is always supported by CoreAudio.
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: Double(WAV.sampleRate),
                      channels: AVAudioChannelCount(WAV.channels),
                      interleaved: true)!
    }()

    func beginCapture() {
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        capturing = true
        lock.unlock()
    }

    /// Ends capture and hands back the raw Int16 PCM.
    func endCapture() -> Data {
        lock.lock()
        let out = pcm
        pcm = Data()
        capturing = false
        lock.unlock()
        return out
    }

    func discard() {
        lock.lock()
        pcm = Data()
        capturing = false
        lock.unlock()
    }

    var capturedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return WAV.duration(ofPCM16: pcm.count)
    }

    /// Drops the cached converter so the next buffer rebuilds it, after a route change.
    func invalidateConverter() {
        lock.lock()
        converter = nil
        inputFormat = nil
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard capturing else { return }

        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let converter, buffer.frameLength > 0 else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        handoff.done = false
        var error: NSError?
        let handoff = self.handoff
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handoff.done {
                outStatus.pointee = .noDataNow
                return nil
            }
            handoff.done = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        let frames = Int(out.frameLength)
        channel[0].withMemoryRebound(to: UInt8.self, capacity: frames * 2) { bytes in
            pcm.append(bytes, count: frames * 2)
        }
    }
}

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
    private let sink = GatedSink()
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

    func beginDictation() throws {
        guard isRunning else { throw RecorderError.notRunning }
        guard engine.isRunning else { throw RecorderError.inputNotReady(AudioTrace.currentInput) }
        sink.beginCapture()
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
