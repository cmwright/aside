import AVFoundation
import Foundation

/// Builds a 16 kHz mono 16-bit PCM WAV file — exactly what the HTTP contract asks for.
enum WAV {
    static let sampleRate = 16_000
    static let channels = 1
    static let bitsPerSample = 16

    /// Wraps raw little-endian Int16 PCM in a canonical 44-byte RIFF/WAVE header.
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

/// Receives audio on the real-time render thread, converts to 16 kHz mono Int16 and
/// appends to a lock-protected buffer. No actor hops, no allocations beyond the output
/// buffer, so the audio callback never blocks on the main actor.
private final class PCMSink: @unchecked Sendable {
    private let lock = NSLock()
    private var pcm = Data()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    let outputFormat: AVAudioFormat = {
        // Force-unwrap: this combination is always supported by CoreAudio.
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: Double(WAV.sampleRate),
                      channels: AVAudioChannelCount(WAV.channels),
                      interleaved: true)!
    }()

    func reset() {
        lock.lock()
        pcm.removeAll(keepingCapacity: true)
        converter = nil
        inputFormat = nil
        lock.unlock()
    }

    /// Drops the cached converter so the next buffer rebuilds it. Used when the engine
    /// reports a configuration change (Bluetooth headset switching formats, etc).
    func invalidateConverter() {
        lock.lock()
        converter = nil
        inputFormat = nil
        lock.unlock()
    }

    func take() -> Data {
        lock.lock()
        let out = pcm
        pcm = Data()
        lock.unlock()
        return out
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        if converter == nil || inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let converter, buffer.frameLength > 0 else { return }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        var handed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if handed {
                outStatus.pointee = .noDataNow
                return nil
            }
            handed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else { return }
        channel[0].withMemoryRebound(to: UInt8.self, capacity: Int(out.frameLength) * 2) { bytes in
            pcm.append(bytes, count: Int(out.frameLength) * 2)
        }
    }
}

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
/// touches lives in `PCMSink`.
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

    func start() throws {
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

        sink.reset()
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
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
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
        engine.stop()

        let pcm = sink.take()
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
        engine.stop()
        _ = sink.take()
    }
}
