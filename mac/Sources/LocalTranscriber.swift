@preconcurrency import AVFoundation
import FluidAudio
import Foundation

/// On-device speech-to-text with NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML on the
/// Neural Engine). The model (~600 MB) is downloaded from Hugging Face on first use and
/// cached by FluidAudio under ~/Library/Application Support; after that it is offline.
///
/// `transcribe(pcm16:)` runs the whole recording once the key is released. FluidAudio's
/// sliding-window streaming engine is not used: fed a recording while the key was held, it
/// dropped the words straddling each 11 s window seam and garbled the last ones, every
/// time (Aside 0.3.0 to 0.3.4; see `testParakeetWholeClipKeepsEveryWord`).
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
        try Task.checkCancellation()
        if state != .ready { prepare() }
        if let loadTask { await loadTask.value }
        try Task.checkCancellation()
        guard state == .ready else {
            if case .failed(let message) = state { throw LocalTranscriberError.modelUnavailable(message) }
            throw LocalTranscriberError.modelUnavailable("model is not loaded")
        }
        let samples = LocalTranscriber.floatSamples(fromPCM16: pcm16)
        return try await engine.transcribe(samples)
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

/// Owns the FluidAudio models so their non-Sendable state never crosses an isolation boundary.
actor ParakeetEngine {
    private var models: AsrModels?
    private var manager: AsrManager?

    /// Download (if needed) and load, reporting each step to the two handlers. They are
    /// called on FluidAudio's queues; the caller hops to the main actor.
    func load(onDownload: @escaping ProgressHandler, onLoad: @escaping ProgressHandler) async throws {
        if manager != nil { return }
        let started = Date()
        let directory = try await AsrModels.download(version: .v3, progressHandler: onDownload)
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
}
