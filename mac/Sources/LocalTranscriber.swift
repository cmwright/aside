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

    /// What the loader is doing while `state == .loading`, for a status line and a bar.
    /// Every number comes from FluidAudio's own progress callbacks: bytes received for the
    /// file being fetched, then the compile step. Nothing here is estimated or animated.
    struct LoadProgress: Equatable {
        enum Stage: Equatable {
            case checking
            case downloading
            case compiling
            case loading(String)
        }

        var stage: Stage
        /// 1-based index of the model file being fetched. Parakeet v3 ships as three CoreML
        /// bundles (fused preprocessor+encoder, decoder, joint).
        var file: Int = 1
        /// Bytes received / bytes expected for the current file, 0...1. Only meaningful in
        /// the `.downloading` stage.
        var downloadFraction: Double = 0
        /// FluidAudio's per-file operation fraction as last reported; a value that goes
        /// backwards means the next file started.
        var rawFraction: Double = 0
        /// FluidAudio weights the download phase of each file operation at 0.5 (its
        /// `ProgressReporter.downloadPhaseWeight`); the compile step is the rest. The bar
        /// divides that out. If a future version reports byte progress on a 0...1 scale the
        /// maximum seen tells us so and the divisor becomes 1.
        var downloadWeight: Double = 0.5

        static let fileCount = 3

        var label: String {
            switch stage {
            case .checking: return "Checking Parakeet v3 files…"
            case .downloading: return "Downloading Parakeet v3, file \(file) of \(LoadProgress.fileCount): \(Int(downloadFraction * 100))%"
            case .compiling: return "Compiling file \(file) of \(LoadProgress.fileCount) for the Neural Engine…"
            case .loading(let name): return name.isEmpty ? "Loading Parakeet v3…" : "Loading \(name) onto the Neural Engine…"
            }
        }
    }

    @Published private(set) var progress: LoadProgress?

    /// One line for a status row: the live progress while loading, the state otherwise.
    var statusLine: String { progress?.label ?? state.label }

    private let engine = ParakeetEngine()
    private var loadTask: Task<Void, Never>?

    private init() {}

    /// Start downloading and loading the model in the background if needed.
    func prepare() {
        guard loadTask == nil, state != .ready else { return }
        state = .loading
        progress = LoadProgress(stage: .checking)
        loadTask = Task { [engine] in
            do {
                try await engine.load(
                    onDownload: { [weak self] report in
                        Task { @MainActor in self?.noteDownload(report) }
                    },
                    onLoad: { [weak self] report in
                        Task { @MainActor in self?.noteLoad(report) }
                    })
                self.state = .ready
            } catch {
                Log.asr.error("Parakeet load failed: \(error.localizedDescription, privacy: .public)")
                self.state = .failed(error.localizedDescription)
            }
            self.progress = nil
            self.loadTask = nil
        }
    }

    /// `AsrModels.download` runs one FluidAudio operation per model file, and each reports
    /// its own 0...1 fraction: bytes during the download phase, then the compile step.
    private func noteDownload(_ report: DownloadProgress) {
        var next = progress ?? LoadProgress(stage: .checking)
        if report.fractionCompleted + 0.001 < next.rawFraction {
            next.file = min(next.file + 1, LoadProgress.fileCount)
            next.downloadFraction = 0
        }
        next.rawFraction = report.fractionCompleted
        switch report.phase {
        case .listing:
            next.stage = .checking
        case .downloading:
            next.stage = .downloading
            if report.fractionCompleted > next.downloadWeight { next.downloadWeight = 1 }
            next.downloadFraction = min(report.fractionCompleted / next.downloadWeight, 1)
        case .compiling:
            next.stage = .compiling
        }
        progress = next
    }

    /// `AsrModels.load` reports which bundle it is handing to Core ML; there is no finer
    /// progress for that step, so the line names the file and nothing pretends otherwise.
    private func noteLoad(_ report: DownloadProgress) {
        var next = progress ?? LoadProgress(stage: .checking)
        if case .compiling(let name) = report.phase {
            next.stage = .loading(name.replacingOccurrences(of: ".mlmodelc", with: ""))
        } else if case .loading = next.stage {
            // keep the last name
        } else {
            next.stage = .loading("")
        }
        progress = next
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

    /// Download (if needed) and load, reporting each step to the two handlers. They are
    /// called on FluidAudio's queues; the caller hops to the main actor.
    func load(onDownload: @escaping ProgressHandler, onLoad: @escaping ProgressHandler) async throws {
        if manager != nil { return }
        let started = Date()
        #if os(iOS)
        let directory: URL
        if let shared = AsideIPC.containerURL() {
            let original = AsrModels.defaultCacheDirectory(for: .v3)
            let sharedParent = shared.appendingPathComponent("SpeechModels", isDirectory: true)
            let sharedModels = sharedParent.appendingPathComponent(original.lastPathComponent, isDirectory: true)
            let fm = FileManager.default
            let isExtension = Bundle.main.bundleURL.pathExtension == "appex"
            if isExtension {
                guard AsrModels.modelsExist(at: sharedModels, version: .v3) else {
                    throw LocalTranscriberError.modelUnavailable("Open Aside once to prepare the speech model for Messages, then return here.")
                }
                directory = sharedModels
            } else {
                try fm.createDirectory(at: sharedParent, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: sharedModels.path), AsrModels.modelsExist(at: original, version: .v3) {
                    let staging = sharedParent.appendingPathComponent("migration-" + UUID().uuidString)
                    defer { try? fm.removeItem(at: staging) }
                    try fm.copyItem(at: original, to: staging)
                    try fm.moveItem(at: staging, to: sharedModels)
                }
                directory = try await AsrModels.download(to: sharedModels, version: .v3, progressHandler: onDownload)
            }
        } else {
            directory = try await AsrModels.download(version: .v3, progressHandler: onDownload)
        }
        #else
        let directory = try await AsrModels.download(version: .v3, progressHandler: onDownload)
        #endif
        let models = try await AsrModels.load(from: directory, version: .v3, progressHandler: onLoad)
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
