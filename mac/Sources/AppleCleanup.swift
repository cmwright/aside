import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Cleanup with Apple's on-device language model (Apple Intelligence, macOS 26+). Nothing
/// leaves the Mac. A fresh session per dictation keeps earlier transcripts out of the
/// model's context; the system keeps the model itself loaded between calls.
@MainActor
final class AppleCleanup: ObservableObject {
    static let shared = AppleCleanup()

    enum Availability: Equatable {
        case available
        case unavailable(String)
        case unsupportedOS

        var label: String {
            switch self {
            case .available: return "Apple on-device model: available"
            case .unavailable(let why): return "Apple on-device model unavailable: \(why)"
            case .unsupportedOS: return "Apple on-device model needs macOS 26 or later"
            }
        }
    }

    @Published private(set) var availability: Availability = .unsupportedOS

    private init() { refresh() }

    func refresh() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                availability = .available
            case .unavailable(let reason):
                let why: String
                switch reason {
                case .deviceNotEligible: why = "this Mac cannot run Apple Intelligence"
                case .appleIntelligenceNotEnabled: why = "Apple Intelligence is off in System Settings"
                case .modelNotReady: why = "the model is still downloading; try again in a minute"
                @unknown default: why = "not available"
                }
                availability = .unavailable(why)
            }
            return
        }
        #endif
        availability = .unsupportedOS
    }

    /// Load the model ahead of the first dictation.
    func prewarm() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), availability == .available {
            Task.detached(priority: .utility) {
                LanguageModelSession(instructions: CleanupPrompt.instructions(level: .medium, entries: [])).prewarm()
            }
        }
        #endif
    }

    /// Returns the cleaned text. Throws `AppleCleanupError.declined` when the model's
    /// guardrails refuse the transcript so the caller can keep the raw text instead.
    func clean(_ rawText: String, level: CleanupLevel, entries: [DictionaryEntry]) async throws -> String {
        refresh()
        guard availability == .available else { throw AppleCleanupError.unavailable(availability.label) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let instructions = CleanupPrompt.instructions(level: level, entries: entries)
            let prompt = CleanupPrompt.userPrompt(rawText)
            do {
                let output = try await AppleCleanup.respond(instructions: instructions, prompt: prompt)
                let cleaned = CleanupPrompt.sanitize(output)
                if cleaned.isEmpty { return rawText }
                if AppleCleanup.similarity(raw: rawText, cleaned: cleaned) < 0.5 {
                    throw AppleCleanupError.declined("off-script output")
                }
                return cleaned
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .guardrailViolation: throw AppleCleanupError.declined("guardrails")
                case .refusal: throw AppleCleanupError.declined("refused")
                case .exceededContextWindowSize: throw AppleCleanupError.declined("transcript too long")
                default: throw AppleCleanupError.failed(error.localizedDescription)
                }
            }
        }
        #endif
        throw AppleCleanupError.unavailable(availability.label)
    }

    #if canImport(FoundationModels)
    /// Guided generation: the model fills in a "corrected transcript" field instead of
    /// replying in chat form. Without this the 3B model answers questions it finds in the
    /// transcript ("Sure, I can help with that!") instead of transcribing them.
    @available(macOS 26.0, *)
    @Generable
    struct CorrectedTranscript {
        @Guide(description: "The transcript with the requested corrections applied, and nothing else. Never a reply to the transcript.")
        var text: String
    }

    @available(macOS 26.0, *)
    private nonisolated static func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(
            to: prompt,
            generating: CorrectedTranscript.self,
            options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 1024)
        )
        return response.content.text
    }
    #endif

    /// Share of the raw transcript's words that survive in the output. A cleanup that keeps
    /// fewer than half of them is a rewrite or a reply, not a correction.
    nonisolated static func similarity(raw: String, cleaned: String) -> Double {
        func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        }
        let a = words(raw)
        guard !a.isEmpty else { return 1 }
        return Double(a.intersection(words(cleaned)).count) / Double(a.count)
    }
}

enum AppleCleanupError: LocalizedError {
    case unavailable(String)
    case declined(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .declined(let why): return "Apple model declined (\(why))"
        case .failed(let why): return "Apple model failed: \(why)"
        }
    }
}
