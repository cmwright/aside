import Foundation

/// A hosted (or local) service that speaks the OpenAI API shape. Anything with a
/// `/chat/completions` endpoint works for cleanup; anything with `/audio/transcriptions`
/// works for speech. Base URLs and models are editable in Settings; these are defaults.
struct ProviderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let chatBaseURL: String?
    let defaultChatModel: String?
    let sttBaseURL: String?
    let defaultSttModel: String?
    /// Where to create an API key. Nil means no key is needed (local servers).
    let keyURL: String?

    var needsKey: Bool { keyURL != nil }
    var supportsSTT: Bool { sttBaseURL != nil || id == ProviderPreset.custom.id }

    static let cerebras = ProviderPreset(
        id: "cerebras", name: "Cerebras",
        chatBaseURL: "https://api.cerebras.ai/v1", defaultChatModel: "gpt-oss-120b",
        sttBaseURL: nil, defaultSttModel: nil,
        keyURL: "https://cloud.cerebras.ai")
    static let groq = ProviderPreset(
        id: "groq", name: "Groq",
        chatBaseURL: "https://api.groq.com/openai/v1", defaultChatModel: "openai/gpt-oss-120b",
        sttBaseURL: "https://api.groq.com/openai/v1", defaultSttModel: "whisper-large-v3-turbo",
        keyURL: "https://console.groq.com/keys")
    static let fireworks = ProviderPreset(
        id: "fireworks", name: "Fireworks",
        chatBaseURL: "https://api.fireworks.ai/inference/v1", defaultChatModel: "accounts/fireworks/models/gpt-oss-120b",
        sttBaseURL: "https://audio-prod.us-virginia-1.fireworks.ai/v1", defaultSttModel: "whisper-v3-turbo",
        keyURL: "https://fireworks.ai/account/api-keys")
    static let openai = ProviderPreset(
        id: "openai", name: "OpenAI",
        chatBaseURL: "https://api.openai.com/v1", defaultChatModel: "gpt-4.1-mini",
        sttBaseURL: "https://api.openai.com/v1", defaultSttModel: "gpt-4o-mini-transcribe",
        keyURL: "https://platform.openai.com/api-keys")
    static let ollama = ProviderPreset(
        id: "ollama", name: "Ollama (this Mac)",
        chatBaseURL: "http://localhost:11434/v1", defaultChatModel: "qwen3:8b",
        sttBaseURL: nil, defaultSttModel: nil,
        keyURL: nil)
    static let custom = ProviderPreset(
        id: "custom", name: "Custom OpenAI-compatible",
        chatBaseURL: nil, defaultChatModel: nil,
        sttBaseURL: nil, defaultSttModel: nil,
        keyURL: "")

    static let all: [ProviderPreset] = [cerebras, groq, fireworks, openai, ollama, custom]
    static let sttCapable: [ProviderPreset] = all.filter(\.supportsSTT)

    static func preset(id: String) -> ProviderPreset {
        all.first { $0.id == id } ?? .custom
    }
}

/// A fully resolved endpoint: what the client actually calls.
struct DirectEndpoint: Sendable {
    var providerName: String
    var baseURL: URL
    var apiKey: String?
    var model: String

    var label: String { "\(providerName) · \(model)" }
}
