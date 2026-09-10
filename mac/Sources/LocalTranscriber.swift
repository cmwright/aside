@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// On-device speech-to-text with NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML on the
/// Neural Engine). The model (~600 MB) is downloaded from Hugging Face on first use and
/// cached by FluidAudio under ~/Library/Application Support; after that it is offline.
///
/// Two ways to use it:
/// - `transcribe(pcm16:)` runs a whole recording after the key is released.
/// - `beginSession()` starts a streaming session while the key is held. Audio is fed as it
///   arrives and FluidAudio's sliding-window engine transcribes 11 s windows (with 2 s of
///   context on each side, the same layout its offline path uses) in the background, so on
///   key-up only the tail is left to process.
@MainActor
final class LocalTranscriber: ObservableObject {
    static let shared = LocalTranscriber()

    enum State: Equatable {
        case notLoaded
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .notLoaded: return "Model not loaded"
            case .loading: return "Downloading / loading Parakeet v3…"
            case .ready: return "Parakeet v3 ready"
            case .failed(let message): return "Model failed: \(message)"
            }
        }
    }

    @Published private(set) var state: State = .notLoaded

    private let engine = ParakeetEngine()
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// Start downloading and loading the model in the background if needed.
    func prepare() {
        guard loadTask == nil, state != .ready else { return }
        state = .loading
        loadTask = Task { [engine] in
            do {
                try await engine.load()
                self.state = .ready
            } catch {
                Log.asr.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
            }
            self.loadTask = nil
        }
    }

    /// Transcribe raw 16 kHz mono Int16 PCM. Loads the model first if needed.
    func transcribe(pcm16: Data) async throws -> String {
        if state != .ready { prepare() }
        if let loadTask { await loadTask.value }
        guard state == .ready else {
            if case .failed(let message) = state { throw LocalTranscriberError.modelUnavailable(message) }
            throw LocalTranscriberError.modelUnavailable("model is not loaded")
        }
        let samples = LocalTranscriber.floatSamples(fromPCM16: pcm16)
        return try await engine.transcribe(samples)
    }

    /// A streaming session for one recording, or nil when the model is not loaded yet (the
    /// caller then falls back to `transcribe(pcm16:)` after the key is released). Returns
    /// synchronously so the recorder can start feeding it before any audio is lost.
    func beginSession() -> StreamingSession? {
        guard state == .ready else { return nil }
        return StreamingSession(engine: engine)
    }

    /// Int16 little-endian PCM -> Float in [-1, 1], which is what Parakeet expects.
    nonisolated static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let lo = UInt16(raw[index * 2])
                let hi = UInt16(raw[index * 2 + 1])
                let value = Int16(bitPattern: lo | (hi << 8))
                samples[index] = Float(value) / 32768
            }
        }
        return samples
    }
}

enum LocalTranscriberError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let message):
            return "On-device model unavailable: \(message). Pick another engine in Settings → Engines or retry."
        }
    }
}

/// One recording's worth of streaming recognition. `feed` is safe to call from the audio
/// thread: it only enqueues samples. A background task hands them to FluidAudio's
/// `SlidingWindowAsrManager`, which is single-use (its input stream cannot be reopened
/// after `finish`), so each recording gets a fresh one over the already-loaded models.
final class StreamingSession: Sendable {
    private let samples: AsyncStream<[Float]>.Continuation
    private let pump: Task<SlidingWindowAsrManager, Error>
    private let started = Date()

    fileprivate init(engine: ParakeetEngine) {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        samples = continuation
        pump = Task {
            let streamer = try await engine.makeStreamer()
            // Parakeet's native format; FluidAudio takes the fast path and copies the floats out.
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
            for await chunk in stream {
                guard !chunk.isEmpty,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)),
                      let channel = buffer.floatChannelData
                else { continue }
                buffer.frameLength = AVAudioFrameCount(chunk.count)
                chunk.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: chunk.count) }
                await streamer.streamAudio(buffer)
            }
            return streamer
        }
    }

    /// 16 kHz mono Float samples in [-1, 1], in capture order.
    func feed(_ chunk: [Float]) {
        samples.yield(chunk)
    }

    /// Ends the audio and returns the full transcript once the remaining tail is decoded.
    func finish() async throws -> String {
        samples.finish()
        let streamer = try await pump.value
        let tailStarted = Date()
        let text = try await streamer.finish()
        let recorded = Int(tailStarted.timeIntervalSince(started))
        Log.asr.info("Parakeet streaming: \(recorded, privacy: .public)s session, tail decoded in \(Int(Date().timeIntervalSince(tailStarted) * 1000), privacy: .public) ms")
        return text
    }

    /// Drops the session without a result.
    func cancel() {
        samples.finish()
        pump.cancel()
        Task { [pump] in
            guard let streamer = try? await pump.value else { return }
            await streamer.cancel()
        }
    }
}

/// Owns the FluidAudio models so their non-Sendable state never crosses an isolation boundary.
actor ParakeetEngine {
    private var models: AsrModels?
    private var manager: AsrManager?

    func load() async throws {
        if manager != nil { return }
        let started = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        self.models = models
        manager = asr
        Log.asr.info("Parakeet v3 loaded in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw LocalTranscriberError.modelUnavailable("model is not loaded") }
        let started = Date()
        // Fresh decoder state per utterance: each dictation is independent.
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(samples, decoderState: &decoderState)
        Log.asr.info("Parakeet transcribed \(samples.count / 16_000, privacy: .public)s of audio in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms")
        return result.text
    }

    /// A started sliding-window streamer over the loaded models. Loading is a reference
    /// copy, so this is cheap enough to do per recording.
    func makeStreamer() async throws -> SlidingWindowAsrManager {
        guard let models else { throw LocalTranscriberError.modelUnavailable("model is not loaded") }
        let streamer = SlidingWindowAsrManager(config: .default)
        try await streamer.loadModels(models)
        try await streamer.startStreaming(source: .microphone)
        return streamer
    }
}
