import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case microphoneDenied
    /// macOS has not asked yet. We trigger the prompt and stop, rather than recording
    /// silence behind the system dialog.
    case needsMicrophonePrompt
    case engineFailed(String)
    case tooShort
    /// `cancel()` ran while `stop()` was still capturing the tail; there is no audio.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access is not granted."
        case .needsMicrophonePrompt: return "Allow microphone access, then hold the key again"
        case .engineFailed(let message): return "Could not start the microphone: \(message)"
        case .tooShort: return "Too short — hold the key while you speak."
        case .cancelled: return "Cancelled"
        }
    }
}

/// Microphone capture. An actor on its own serial queue, not the main actor: starting and
/// stopping `AVAudioEngine` and installing the tap are synchronous mach IPC to coreaudiod,
/// which has been seen to block for seconds while an input device switches (the sample of
/// a hung 0.2.0 in issue #2). On the main thread that froze the menu bar and the key-up
/// handler with it; here it only delays the recording, and the controller can say so.
/// Everything the audio thread touches lives in `PCMSink` (PCMCapture.swift, shared with
/// the iPhone app).
actor Recorder {
    /// Recordings shorter than this are treated as an accidental key tap.
    nonisolated static let minimumDuration: Double = 0.3

    /// How long capture goes on after the key comes up. The end of the last word is still
    /// on its way at that moment: the tap hands audio over in blocks of up to 4096 frames
    /// (85 ms at 48 kHz, 256 ms at a Bluetooth headset's 16 kHz) and the partial block in
    /// flight when the tap comes off is dropped; the input path adds its own latency, more
    /// over Bluetooth; and a hand that lets go on the last syllable is early by a little
    /// more. Parakeet still gets a final word with 200 ms of it missing and loses it
    /// outright at 400 ms (measured), so the tail is kept for this long, which moves the
    /// cut into the quiet after the speech.
    nonisolated static let trailingCapture: Duration = .milliseconds(400)

    private let queue = DispatchSerialQueue(label: "com.codywright.aside.recorder", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

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
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange() }
        }
    }

    deinit {
        if let token = observerBox.token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// CoreAudio UID of the microphone to record from; nil or empty means the system default.
    private var preferredInputUID: String?

    func start(inputDeviceUID: String? = nil) throws {
        guard !isRecording else { return }
        preferredInputUID = inputDeviceUID
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

        sink.beginCapture()
        engineStopTask?.cancel()
        engineStopTask = nil
        do {
            try installTapAndStart()
        } catch {
            sink.discard()
            throw error
        }
        isRecording = true
        Log.audio.info("Recording started")
    }

    /// Points the input node at the chosen microphone, or at whatever the system default is
    /// right now. Done before every start and rebuild, so a device that disappears falls back
    /// to the default and a changed default is picked up. Changing the device restarts the
    /// I/O unit, so the engine is stopped first; the caller starts it again.
    private func applyInputDevice() {
        let unit = engine.inputNode.auAudioUnit
        let wanted: AudioDeviceID?
        if let uid = preferredInputUID, !uid.isEmpty {
            if let chosen = AudioInputDevices.deviceID(forUID: uid) {
                wanted = chosen
            } else {
                Log.audio.notice("Chosen microphone is not connected; using the system default")
                wanted = AudioInputDevices.defaultInputID
            }
        } else if inputDeviceOverridden {
            // Back to "system default" after a fixed device: the node no longer follows the
            // default on its own, so hand it the current default explicitly.
            wanted = AudioInputDevices.defaultInputID
        } else {
            return
        }
        guard let wanted, unit.deviceID != wanted else { return }
        if engine.isRunning { engine.stop() }
        do {
            try unit.setDeviceID(wanted)
            inputDeviceOverridden = true
            Log.audio.info("Input device: \(AudioInputDevices.name(of: wanted) ?? String(wanted), privacy: .public)")
        } catch {
            Log.audio.error("Could not select the input device: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Set once the input node has been pointed at a device explicitly.
    private var inputDeviceOverridden = false

    private func installTapAndStart() throws {
        applyInputDevice()
        let input = engine.inputNode
        // The hardware format is the one that counts, and it is always current. The node's
        // own output format is not: it keeps the previous device's format when the device
        // changes while Aside is idle (AirPods disconnecting between dictations left it at
        // 24 kHz with the built-in mic at 48 kHz), and a tap in that stale format fails the
        // engine with kAudioUnitErr_FormatNotSupported (-10868), or, when passed explicitly
        // against a changed device, raises the issue #2 exception. Zero Hz or zero channels
        // means no usable input yet (a device mid-switch).
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.engineFailed("no input device")
        }
        input.removeTap(onBus: 0)
        let sink = self.sink
        // AVFAudio reports a tap/hardware format disagreement by raising an NSException, not
        // an error, so the install runs under an Objective-C @try: any raise the guard above
        // misses fails the recording instead of the process. The sink converts from whatever
        // format the buffers actually carry.
        //
        // The tap runs on AVFoundation's realtime messenger thread. Without `@Sendable`
        // the closure inherits this method's @MainActor isolation and Swift 6 traps
        // (dispatch_assert_queue) the first time audio arrives.
        do {
            try ObjCException.catching {
                input.installTap(onBus: 0, bufferSize: 4096, format: format) { @Sendable buffer, _ in
                    sink.append(buffer)
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            Log.audio.error("installTap raised: \(error.localizedDescription, privacy: .public)")
            throw RecorderError.engineFailed(
                "the input (\(Int(format.sampleRate)) Hz × \(format.channelCount)) could not be tapped: \(error.localizedDescription)")
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
        // The latency is part of what `trailingCapture` has to cover; keep it in the log.
        Log.audio.info("Input: \(Int(format.sampleRate), privacy: .public) Hz × \(format.channelCount, privacy: .public), latency \(Int(input.presentationLatency * 1000), privacy: .public) ms")
    }

    /// See `minimumEngineLifetime`. A `start()` before the deadline keeps the engine running.
    private func stopEngineSoon() {
        engineStopTask?.cancel()
        var delay = Recorder.engineStopDelay
        if let engineStartedAt {
            delay = max(delay, Recorder.minimumEngineLifetime - engineStartedAt.duration(to: .now))
        }
        engineStopTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            stopEngineIfIdle()
        }
    }

    private func stopEngineIfIdle() {
        guard !isRecording else { return }
        engine.stop()
        engineStartedAt = nil
        engineStopTask = nil
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

    /// Keeps capturing for `trailingCapture`, then stops and returns a finished WAV file.
    /// Throws `.tooShort` for an accidental tap and `.cancelled` when `cancel()` ran while
    /// the tail was being captured.
    func stop() async throws -> Data {
        guard isRecording else { throw RecorderError.tooShort }
        // What was in hand when the key came up decides "too short"; the tail is not the
        // user's doing. The tap lags real time by up to a block, so the total minus the
        // tail is the other estimate and the larger one is used.
        let heldAtKeyUp = sink.capturedSeconds
        try? await Task.sleep(for: Recorder.trailingCapture)
        guard isRecording else { throw RecorderError.cancelled }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        stopEngineSoon()

        let pcm = sink.endCapture()
        let seconds = WAV.duration(ofPCM16: pcm.count)
        let trailing = Double(Recorder.trailingCapture.components.seconds)
            + Double(Recorder.trailingCapture.components.attoseconds) / 1e18
        let held = max(heldAtKeyUp, seconds - trailing)
        Log.audio.info("Recording stopped: \(seconds, format: .fixed(precision: 2), privacy: .public)s, \(held, format: .fixed(precision: 2), privacy: .public)s before the key came up")
        guard held >= Recorder.minimumDuration else { throw RecorderError.tooShort }
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
