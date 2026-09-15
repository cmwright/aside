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

    /// `listener`, when given, receives the 16 kHz mono Float samples as they are captured,
    /// for a transcriber that works while the key is still held.
    /// CoreAudio UID of the microphone to record from; nil or empty means the system default.
    private var preferredInputUID: String?

    func start(listener: (@Sendable ([Float]) -> Void)? = nil, inputDeviceUID: String? = nil) throws {
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

        sink.beginCapture(listener: listener)
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
        // The hardware format and the format the node hands a tap. Either one at 0 Hz or
        // 0 channels (no input device, a device mid-switch) makes installTap raise.
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.engineFailed("no input device")
        }
        input.removeTap(onBus: 0)
        let sink = self.sink
        // `format: nil` makes the tap take the node's format at install time rather than
        // the one queried a moment ago; the two can disagree while an input device is
        // switching, and AVFAudio reports that by raising an NSException, not an error
        // (issue #2: SIGABRT on the hotkey). The sink converts from whatever format the
        // buffers actually carry. The install still runs under an Objective-C @try so any
        // raise this guard misses fails the recording instead of the process.
        //
        // The tap runs on AVFoundation's realtime messenger thread. Without `@Sendable`
        // the closure inherits this method's @MainActor isolation and Swift 6 traps
        // (dispatch_assert_queue) the first time audio arrives.
        do {
            try ObjCException.catching {
                input.installTap(onBus: 0, bufferSize: 4096, format: nil) { @Sendable buffer, _ in
                    sink.append(buffer)
                }
            }
        } catch {
            input.removeTap(onBus: 0)
            Log.audio.error("installTap raised: \(error.localizedDescription, privacy: .public)")
            throw RecorderError.engineFailed(
                "the input (\(Int(hardware.sampleRate)) Hz × \(hardware.channelCount)) could not be tapped: \(error.localizedDescription)")
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
