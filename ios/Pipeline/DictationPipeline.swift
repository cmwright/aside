import Foundation

/// Shared by the main iOS app and Messages; provider selection and cleanup behavior
/// must not drift between entry points. A plan freezes settings for one recording.
@MainActor
enum DictationPipeline {
    enum PipelineError: LocalizedError {
        case unsupportedEngine
        var errorDescription: String? { "The Worker is not available on iPhone. Pick another engine." }
    }
    struct CleanupPlan {
        var engine: CleanupEngine
        var level: CleanupLevel
        var entries: [DictionaryEntry]
        var direct: DirectEndpoint?
        var directNeedsKey: Bool
    }
    struct Plan {
        var mode: TranscriptionMode
        var speech: DirectEndpoint?
        var speechNeedsKey: Bool
        var speechProvider: String
        var cleanup: CleanupPlan
    }
    static func plan(settings: AppSettings, entries: [DictionaryEntry]) -> Plan {
        let preset = ProviderPreset.preset(id: settings.directSttProvider)
        return Plan(mode: settings.transcriptionMode, speech: settings.directSttEndpoint(),
                    speechNeedsKey: preset.needsKey, speechProvider: preset.name,
                    cleanup: CleanupPlan(engine: settings.cleanupEngine, level: settings.cleanup,
                        entries: entries, direct: settings.directChatEndpoint(),
                        directNeedsKey: ProviderPreset.preset(id: settings.directChatProvider).needsKey))
    }
    static func transcribe(audio: Data, plan: Plan, direct: DirectClient = DirectClient()) async throws -> String {
        switch plan.mode {
        case .local:
            return try await LocalTranscriber.shared.transcribe(pcm16: WAV.pcm16(fromFile: audio))
        case .direct:
            guard let endpoint = plan.speech else {
                throw DirectError.badResponse("a speech provider with a model and base URL (check Settings)")
            }
            if plan.speechNeedsKey && (endpoint.apiKey ?? "").isEmpty {
                throw DirectError.missingKey(plan.speechProvider)
            }
            return try await direct.transcribe(audio: audio, endpoint: endpoint,
                vocabulary: DirectClient.vocabulary(from: plan.cleanup.entries))
        case .cloud:
            throw PipelineError.unsupportedEngine
        }
    }
    static func clean(raw: String, plan: CleanupPlan, direct: DirectClient = DirectClient()) async throws -> (text: String, ms: Int, label: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", 0, "none") }
        guard plan.level != .none else {
            return (DictionaryReplacer.apply(trimmed, entries: plan.entries)
                .trimmingCharacters(in: .whitespacesAndNewlines), 0, "none")
        }
        let started = Date()
        switch plan.engine {
        case .worker:
            throw PipelineError.unsupportedEngine
        case .direct:
            guard let endpoint = plan.direct else {
                throw DirectError.badResponse("a usable cleanup provider (check Settings)")
            }
            if plan.directNeedsKey && (endpoint.apiKey ?? "").isEmpty {
                throw DirectError.missingKey(endpoint.providerName)
            }
            let reply = try await direct.chat(
                endpoint: endpoint,
                system: CleanupPrompt.instructions(level: plan.level, entries: plan.entries),
                user: CleanupPrompt.userPrompt(trimmed))
            var text = CleanupPrompt.sanitize(reply)
            var label = "Direct: \(endpoint.label)"
            if text.isEmpty || AppleCleanup.similarity(raw: trimmed, cleaned: text) < 0.5 {
                label += " (off-script; raw text kept)"
                text = trimmed
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return (DictionaryReplacer.apply(text, entries: plan.entries)
                .trimmingCharacters(in: .whitespacesAndNewlines), ms, label)
        case .apple:
            var text = trimmed
            var label = "Apple on-device model"
            do {
                text = try await AppleCleanup.shared.clean(trimmed, level: plan.level, entries: plan.entries)
            } catch let error as AppleCleanupError {
                if case .declined(let why) = error {
                    label = "Apple model declined (\(why)); raw text kept"
                    Log.app.notice("Apple cleanup declined: \(why, privacy: .public)")
                } else {
                    throw error
                }
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return (DictionaryReplacer.apply(text, entries: plan.entries)
                .trimmingCharacters(in: .whitespacesAndNewlines), ms, label)
        }
    }

}
