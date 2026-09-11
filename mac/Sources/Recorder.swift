import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    /// macOS has not asked yet. We trigger the prompt and stop, rather than recording
    /// silence behind the system dialog.
    case needsMicrophonePrompt
    case engineFailed(String)
    case tooShort

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is not granted."
        case .needsMicrophonePrompt: return "Allow microphone access, then hold the key again"
        case .engineFailed(let message): return "Could not start the microphone: \(message)"
        case .tooShort: return "Too short — hold the key while you speak."
        }
    }
}

/// Microphone capture. `start()` and `stop()` are main-actor; everything the audio thread
/// touches lives in `PCMSink` (PCMCapture.swift, shared with the iPhone app).
@MainActor
final class Recorder {
    /// Recordings shorter than this are treated as an accidental key tap.
    nonisolated static let minimumDuration: Double = 0.3

    private let engine = AVAudioEngine()
    private let sink = PCMSink()
    /// `deinit` is nonisolated, so the observer token lives in a box it can safely reach.
    private final class ObserverBox: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
    }

    private let observerBox = ObserverBox()
    private(set) var isRecording = false

    /// Stopping the engine within a few hundred milliseconds of starting it, while the start
    /// cue's audio queue is being torn down in the same process, has crashed inside CoreAudio:
    /// its IO thread called a null callback during `AudioOutputUnitStop` (Aside 0.2.2, macOS
    /// 26.2). We cannot catch that, so we avoid the pattern: the tap comes off immediately, so
    /// no audio is kept, and the engine itself winds down a moment later, never sooner than
    /// `minimumEngineLifetime` after it started.
    nonisolated static let minimumEngineLifetime: Duration = .seconds(1)
    nonisolated static let engineStopDelay: Duration = .milliseconds(500)
    private var engineStartedAt: ContinuousClock.Instant?
    private var engineStopTask: Task<Void, Never>?

    init() {
        observerBox.token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        }
    }

    deinit {
        if let token = observerBox.token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// `listener`, when given, receives the 16 kHz mono Float samples as they are captured,
    /// for a transcriber that works while the key is still held.
    func start(listener: (@Sendable ([Float]) -> Void)? = nil) throws {
        guard !isRecording else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Starting the engine here would record silence behind the TCC dialog and end
            // as "Too short". Ask, and let the user press the key again.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in Permissions.shared.refresh() }
            }
            throw RecorderError.needsMicrophonePrompt
        default:
            // .denied and .restricted (managed devices) both mean no microphone, ever.
            throw RecorderError.microphoneDenied
        }

        sink.beginCapture(listener: listener)
        engineStopTask?.cancel()
        engineStopTask = nil
        try installTapAndStart()
        isRecording = true
        Log.audio.info("Recording started")
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.engineFailed("no input device")
        }
        input.removeTap(onBus: 0)
        let sink = self.sink
        // The tap runs on AVFoundation's realtime messenger thread. Without `@Sendable`
        // the closure inherits this method's @MainActor isolation and Swift 6 traps
        // (dispatch_assert_queue) the first time audio arrives.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
            sink.append(buffer)
        }
        let wasRunning = engine.isRunning
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        if !wasRunning { engineStartedAt = .now }
    }

    /// See `minimumEngineLifetime`. A `start()` before the deadline keeps the engine running.
    private func stopEngineSoon() {
        engineStopTask?.cancel()
        var delay = Recorder.engineStopDelay
        if let engineStartedAt {
            delay = max(delay, Recorder.minimumEngineLifetime - engineStartedAt.duration(to: .now))
        }
        engineStopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, !self.isRecording else { return }
            self.engine.stop()
            self.engineStartedAt = nil
            self.engineStopTask = nil
        }
    }

    /// A Bluetooth headset connecting mid-recording changes the input format. Rebuild the
    /// tap and the converter instead of ending up with garbage audio.
    private func handleConfigurationChange() {
        guard isRecording else { return }
        Log.audio.info("Audio engine configuration changed; rebuilding tap")
        sink.invalidateConverter()
        engine.stop()
        do {
            try installTapAndStart()
        } catch {
            Log.audio.error("Rebuild after configuration change failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops the engine and returns a finished WAV file, or throws `.tooShort`.
    func stop() throws -> Data {
        guard isRecording else { throw RecorderError.tooShort }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        stopEngineSoon()

        let pcm = sink.endCapture()
        let seconds = WAV.duration(ofPCM16: pcm.count)
        Log.audio.info("Recording stopped: \(seconds, format: .fixed(precision: 2), privacy: .public)s")
        guard seconds >= Recorder.minimumDuration else { throw RecorderError.tooShort }
        return WAV.file(pcm16: pcm)
    }

    /// Throws away whatever has been captured; used when a recording is abandoned.
    func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        stopEngineSoon()
        sink.discard()
    }
}
