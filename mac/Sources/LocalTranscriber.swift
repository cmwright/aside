import FluidAudio
import Foundation

/// On-device speech-to-text with NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (CoreML on the
/// Neural Engine). The model (~600 MB) is downloaded from Hugging Face on first use and
/// cached by FluidAudio under ~/Library/Application Support; after that it is offline.
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
            return "On-device model unavailable: \(message). Switch Transcription to Cloud in Settings or retry."
        }
    }
}

/// Owns the FluidAudio manager so its non-Sendable state never crosses an isolation boundary.
actor ParakeetEngine {
    private var manager: AsrManager?

    func load() async throws {
        if manager != nil { return }
        let started = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(models)
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
