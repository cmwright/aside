import Foundation

/// A snapshot: editing Settings during a request cannot change its destination or keys.
struct DictationPlan: Sendable {
    var speech: TranscriptionMode
    var speechEndpoint: DirectEndpoint?
    var speechNeedsKey: Bool
    var cleanup: CleanupEngine
    var level: CleanupLevel
    var cleanupEndpoint: DirectEndpoint?
    var cleanupNeedsKey: Bool
    var entries: [DictionaryEntry]
    var backendURL: URL?
    var backendToken: String?
    var appName: String?

    @MainActor
    init(settings: AppSettings, entries: [DictionaryEntry], appName: String? = nil) {
        speech = settings.transcriptionMode
        speechEndpoint = settings.transcriptionMode == .direct ? settings.directSttEndpoint() : nil
        speechNeedsKey = ProviderPreset.preset(id: settings.directSttProvider).needsKey
        cleanup = settings.cleanupEngine
        level = settings.cleanup
        cleanupEndpoint = settings.cleanupEngine == .direct ? settings.directChatEndpoint() : nil
        cleanupNeedsKey = ProviderPreset.preset(id: settings.directChatProvider).needsKey
        self.entries = entries
        backendURL = settings.backendURL
        backendToken = settings.trimmedToken
        self.appName = appName
    }
}

struct PipelineResult: Sendable {
    var raw: String
    var text: String
    var engine: TranscriptionMode
    var sttMs: Int
    var cleanupMs: Int = 0
    var cleanupLabel = "none"
    var warning: String?
}

enum PipelineError: LocalizedError {
    case timedOut
    var errorDescription: String? { "The engine took too long to respond." }
}

/// Shared by Mac and iPhone. UI, microphone ownership and text delivery stay in the
/// platform controllers. Every boundary checks cancellation before doing more work.
struct DictationPipeline: Sendable {
    var direct = DirectClient()
    var backend = BackendClient()
    var cleanupAttemptSeconds: Double = 10
    var retryDelay: Double = 1
    var localSpeech: @Sendable (Data) async throws -> String = {
        try await LocalTranscriber.shared.transcribe(pcm16: WAV.pcm16(fromFile: $0))
    }
    var appleCleanup: @Sendable (String, CleanupLevel, [DictionaryEntry]) async throws -> String = {
        try await AppleCleanup.shared.clean($0, level: $1, entries: $2)
    }

    func run(audio: Data, plan: DictationPlan,
             onTranscript: @Sendable (PipelineResult) async -> Void = { _ in }) async throws -> PipelineResult {
        try Task.checkCancellation()
        let started = Date()
        let raw: String
        switch plan.speech {
        case .local:
            raw = try await localSpeech(audio)
        case .direct:
            guard let endpoint = plan.speechEndpoint else { throw DirectError.badResponse("a configured speech provider") }
            try requireKey(endpoint, needed: plan.speechNeedsKey)
            raw = try await direct.transcribe(audio: audio, endpoint: endpoint,
                                             vocabulary: DirectClient.vocabulary(from: plan.entries))
        case .cloud:
            guard let url = plan.backendURL else { throw BackendError.badURL }
            // Always obtain the raw text before cleanup, so a cleanup outage cannot lose it.
            let response = try await backend.transcribe(TranscriptionRequest(
                baseURL: url, token: plan.backendToken, audio: audio,
                dictionaryJSON: DictionaryCodec.encodeForRequest(plan.entries), cleanup: .none, appName: plan.appName))
            raw = response.rawText ?? response.text
        }
        try Task.checkCancellation()
        let checkpoint = PipelineResult(raw: raw, text: fallback(raw, plan: plan), engine: plan.speech,
                                        sttMs: Int(Date().timeIntervalSince(started) * 1000))
        await onTranscript(checkpoint)
        try Task.checkCancellation()
        return try await clean(checkpoint, plan: plan)
    }

    func clean(_ checkpoint: PipelineResult, plan: DictationPlan) async throws -> PipelineResult {
        try Task.checkCancellation()
        var result = checkpoint
        result.text = fallback(checkpoint.raw, plan: plan)
        result.warning = nil
        result.cleanupLabel = "none"
        guard plan.level != .none, !checkpoint.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result }
        let started = Date()
        for attempt in 1...2 {
            do {
                let cleaned = try await withPipelineTimeout(seconds: cleanupAttemptSeconds) {
                    try await cleanupOnce(checkpoint.raw, plan: plan)
                }
                try Task.checkCancellation()
                result.text = fallback(cleaned, plan: plan)
                result.cleanupLabel = cleanupLabel(plan) + (attempt > 1 ? " (after a retry)" : "")
                result.cleanupMs = Int(Date().timeIntervalSince(started) * 1000)
                return result
            } catch {
                // Cancellation is control flow, never a reason to insert raw text or retry.
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if attempt == 1, Self.isTransient(error) {
                    try await Task.sleep(for: .seconds(retryDelay))
                    continue
                }
                let reason = Self.shortFailure(error)
                result.cleanupLabel = "failed (\(reason)); raw text kept"
                result.warning = "Cleanup unavailable (\(reason)); raw transcript kept"
                result.cleanupMs = Int(Date().timeIntervalSince(started) * 1000)
                return result
            }
        }
        return result
    }

    private func cleanupOnce(_ raw: String, plan: DictationPlan) async throws -> String {
        try Task.checkCancellation()
        let reply: String
        switch plan.cleanup {
        case .direct:
            guard let endpoint = plan.cleanupEndpoint else { throw DirectError.badResponse("a configured cleanup provider") }
            try requireKey(endpoint, needed: plan.cleanupNeedsKey)
            reply = try await direct.chat(endpoint: endpoint,
                                          system: CleanupPrompt.instructions(level: plan.level, entries: plan.entries),
                                          user: CleanupPrompt.userPrompt(raw))
        case .apple:
            reply = try await appleCleanup(raw, plan.level, plan.entries)
        case .worker:
            guard let url = plan.backendURL else { throw BackendError.badURL }
            let response = try await backend.cleanup(CleanupRequest(baseURL: url, token: plan.backendToken, text: raw,
                dictionaryJSON: DictionaryCodec.encodeForRequest(plan.entries), cleanup: plan.level, appName: plan.appName))
            if response.warning != nil { throw DirectError.badResponse("successful cleanup") }
            reply = response.text
        }
        try Task.checkCancellation()
        let text = CleanupPrompt.sanitize(reply)
        guard !text.isEmpty, AppleCleanup.similarity(raw: raw, cleaned: text) >= 0.5 else {
            throw AppleCleanupError.declined("off-script output")
        }
        return text
    }

    private func fallback(_ raw: String, plan: DictationPlan) -> String {
        DictionaryReplacer.apply(raw, entries: plan.entries).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requireKey(_ endpoint: DirectEndpoint, needed: Bool) throws {
        if needed && (endpoint.apiKey ?? "").isEmpty { throw DirectError.missingKey(endpoint.providerName) }
    }

    private func cleanupLabel(_ plan: DictationPlan) -> String {
        switch plan.cleanup {
        case .direct: return "Direct: \(plan.cleanupEndpoint?.label ?? "provider")"
        case .apple: return "Apple on-device model"
        case .worker: return "Worker"
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case is CancellationError: return false
        case is PipelineError, DirectError.transport, BackendError.transport: return true
        case let error as URLError: return error.code != .cancelled
        case DirectError.http(_, let status, _), BackendError.http(let status, _):
            return status == 408 || status == 429 || status >= 500
        default: return false
        }
    }

    static func shortFailure(_ error: Error) -> String {
        switch error {
        case DirectError.http(let provider, let status, _): return "\(provider) \(status)"
        case BackendError.http(let status, _): return "Worker \(status)"
        case DirectError.transport, BackendError.transport, is URLError: return "no connection"
        case DirectError.missingKey(let provider): return "no \(provider) key"
        case is PipelineError: return "timed out"
        default: return String(error.localizedDescription.prefix(60))
        }
    }
}

func withPipelineTimeout<T: Sendable>(seconds: Double,
                                     operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw PipelineError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
