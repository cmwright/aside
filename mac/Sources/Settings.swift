import Foundation
import SwiftUI

/// How hard the backend should work on the transcript. Matches the `cleanup` field of the
/// HTTP contract exactly.
enum CleanupLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case none
    case light
    case medium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None — raw transcript"
        case .light: return "Light — punctuation, capitalization, dictionary"
        case .medium: return "Medium — also fillers, false starts, grammar"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let backendURL = "backendURL"
        static let backendToken = "backendToken"
        static let cleanup = "cleanupLevel"
        static let playSounds = "playSounds"
        static let holdRightOption = "holdRightOption"
        /// Pre-0.3 Boolean, only read to map an explicit "off" onto `tapBehavior`.
        static let doubleTapToLatch = "doubleTapToLatch"
        static let tapBehavior = TriggerLogic.TapBehavior.defaultsKey
        static let transcriptionMode = "transcriptionMode"
        static let logDictationsToFile = "logDictationsToFile"
        static let cleanupEngine = "cleanupEngine"
        static let historyRetention = "historyRetention"
        static let directChatProvider = "directChatProvider"
        static let directChatModel = "directChatModel"
        static let directChatBaseURL = "directChatBaseURL"
        static let directSttProvider = "directSttProvider"
        static let directSttModel = "directSttModel"
        static let directSttBaseURL = "directSttBaseURL"
    }

    static let defaultBackendURL = "http://localhost:8787"

    /// What a fresh install uses. The iPhone app has no Worker option and starts fully
    /// on-device; a Worker value left by an older build or a shared defaults suite is
    /// mapped the same way when it is read.
    #if os(iOS)
    static let defaultTranscriptionMode: TranscriptionMode = .local
    static let defaultCleanupEngine: CleanupEngine = .apple
    #else
    static let defaultTranscriptionMode: TranscriptionMode = .cloud
    static let defaultCleanupEngine: CleanupEngine = .worker
    #endif

    nonisolated static func supported(_ mode: TranscriptionMode) -> TranscriptionMode {
        #if os(iOS)
        return mode == .cloud ? .local : mode
        #else
        return mode
        #endif
    }

    nonisolated static func supported(_ engine: CleanupEngine) -> CleanupEngine {
        #if os(iOS)
        return engine == .worker ? .apple : engine
        #else
        return engine
        #endif
    }

    private let defaults: UserDefaults

    @Published var backendURLString: String { didSet { defaults.set(backendURLString, forKey: Key.backendURL) } }
    @Published var backendToken: String { didSet { defaults.set(backendToken, forKey: Key.backendToken) } }
    @Published var cleanup: CleanupLevel { didSet { defaults.set(cleanup.rawValue, forKey: Key.cleanup) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    /// Right Option is the dictation key. This is the default trigger; the KeyboardShortcuts
    /// combo below is an optional press-to-start / press-to-stop alternative.
    @Published var holdRightOption: Bool { didSet { defaults.set(holdRightOption, forKey: Key.holdRightOption) } }
    /// What a quick tap of the dictation key does; holding always works. On the phone this
    /// lives in the App Group suite, where the keyboard extension reads it directly.
    @Published var tapBehavior: TriggerLogic.TapBehavior { didSet { defaults.set(tapBehavior.rawValue, forKey: Key.tapBehavior) } }
    /// Where speech becomes text: the Worker's provider, or Parakeet on this Mac.
    @Published var transcriptionMode: TranscriptionMode { didSet { defaults.set(transcriptionMode.rawValue, forKey: Key.transcriptionMode) } }
    /// Opt-in: append raw and final text of every dictation to ~/Library/Logs/Aside/dictations.jsonl.
    @Published var logDictationsToFile: Bool { didSet { defaults.set(logDictationsToFile, forKey: Key.logDictationsToFile) } }
    /// Who runs the cleanup pass: the Worker's model, or Apple's on-device model.
    @Published var cleanupEngine: CleanupEngine { didSet { defaults.set(cleanupEngine.rawValue, forKey: Key.cleanupEngine) } }
    /// How long Recent Dictations are kept on disk. Off by default: transcripts stay in memory.
    @Published var historyRetention: HistoryRetention { didSet { defaults.set(historyRetention.rawValue, forKey: Key.historyRetention) } }
    /// Direct mode: which OpenAI-compatible service runs cleanup, and which one runs speech.
    /// Empty model / base URL strings mean "use the preset's default".
    @Published var directChatProvider: String { didSet { defaults.set(directChatProvider, forKey: Key.directChatProvider) } }
    @Published var directChatModel: String { didSet { defaults.set(directChatModel, forKey: Key.directChatModel) } }
    @Published var directChatBaseURL: String { didSet { defaults.set(directChatBaseURL, forKey: Key.directChatBaseURL) } }
    @Published var directSttProvider: String { didSet { defaults.set(directSttProvider, forKey: Key.directSttProvider) } }
    @Published var directSttModel: String { didSet { defaults.set(directSttModel, forKey: Key.directSttModel) } }
    @Published var directSttBaseURL: String { didSet { defaults.set(directSttBaseURL, forKey: Key.directSttBaseURL) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AppSettings.migrateFromVoiceToTextIfNeeded(into: defaults)
        defaults.register(defaults: [
            Key.backendURL: AppSettings.defaultBackendURL,
            Key.playSounds: true,
            Key.holdRightOption: true,
            Key.transcriptionMode: AppSettings.defaultTranscriptionMode.rawValue,
            Key.logDictationsToFile: false,
            Key.cleanupEngine: AppSettings.defaultCleanupEngine.rawValue,
            Key.cleanup: CleanupLevel.medium.rawValue,
            Key.directChatProvider: ProviderPreset.cerebras.id,
            Key.directSttProvider: ProviderPreset.groq.id,
        ])
        backendURLString = defaults.string(forKey: Key.backendURL) ?? AppSettings.defaultBackendURL
        backendToken = defaults.string(forKey: Key.backendToken) ?? ""
        cleanup = CleanupLevel(rawValue: defaults.string(forKey: Key.cleanup) ?? "") ?? .medium
        playSounds = defaults.bool(forKey: Key.playSounds)
        holdRightOption = defaults.bool(forKey: Key.holdRightOption)
        if defaults.object(forKey: Key.tapBehavior) == nil, defaults.object(forKey: Key.doubleTapToLatch) as? Bool == false {
            // Whoever switched the double-tap off before 0.3 wanted a tap to send, not to latch.
            tapBehavior = .send
        } else {
            tapBehavior = TriggerLogic.TapBehavior.stored(in: defaults)
        }
        transcriptionMode = AppSettings.supported(
            TranscriptionMode(rawValue: defaults.string(forKey: Key.transcriptionMode) ?? "") ?? AppSettings.defaultTranscriptionMode)
        logDictationsToFile = defaults.bool(forKey: Key.logDictationsToFile)
        cleanupEngine = AppSettings.supported(
            CleanupEngine(rawValue: defaults.string(forKey: Key.cleanupEngine) ?? "") ?? AppSettings.defaultCleanupEngine)
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: Key.historyRetention) ?? "") ?? .sessionOnly
        directChatProvider = defaults.string(forKey: Key.directChatProvider) ?? ProviderPreset.cerebras.id
        directChatModel = defaults.string(forKey: Key.directChatModel) ?? ""
        directChatBaseURL = defaults.string(forKey: Key.directChatBaseURL) ?? ""
        directSttProvider = defaults.string(forKey: Key.directSttProvider) ?? ProviderPreset.groq.id
        directSttModel = defaults.string(forKey: Key.directSttModel) ?? ""
        directSttBaseURL = defaults.string(forKey: Key.directSttBaseURL) ?? ""
    }

    /// The bundle id was com.codywright.voicetotext before 2026-09-08, which is a separate
    /// preferences domain. Copy our keys (and the KeyboardShortcuts recording) across once.
    private static let migrationMarker = "migratedFromVoiceToText"

    static func migrateFromVoiceToTextIfNeeded(into defaults: UserDefaults) {
        guard defaults.object(forKey: migrationMarker) == nil else { return }
        defaults.set(true, forKey: migrationMarker)
        guard defaults === UserDefaults.standard,
              let legacy = UserDefaults(suiteName: "com.codywright.voicetotext")?.dictionaryRepresentation(),
              !legacy.isEmpty else { return }
        let ours: Set<String> = [Key.backendURL, Key.backendToken, Key.cleanup, Key.playSounds,
                                 Key.holdRightOption, Key.doubleTapToLatch, Key.tapBehavior, Key.transcriptionMode]
        var copied = 0
        for (key, value) in legacy where ours.contains(key) || key.hasPrefix("KeyboardShortcuts_") {
            if defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
                copied += 1
            }
        }
        if copied > 0 { Log.app.notice("Migrated \(copied, privacy: .public) settings from VoiceToText") }
    }

    /// `backendURLString` with whitespace and a trailing slash removed, or nil if unusable.
    var backendURL: URL? {
        AppSettings.normalizedURL(from: backendURLString)
    }

    /// Pure, testable: trims the string, drops trailing slashes, requires an http(s) scheme.
    nonisolated static func normalizedURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// Resolved cleanup endpoint for Direct mode, or nil when the base URL is unusable.
    func directChatEndpoint() -> DirectEndpoint? {
        AppSettings.resolve(preset: ProviderPreset.preset(id: directChatProvider),
                            baseURLOverride: directChatBaseURL, modelOverride: directChatModel, stt: false)
    }

    /// Resolved speech endpoint for Direct mode, or nil when the provider has no STT or the URL is unusable.
    func directSttEndpoint() -> DirectEndpoint? {
        AppSettings.resolve(preset: ProviderPreset.preset(id: directSttProvider),
                            baseURLOverride: directSttBaseURL, modelOverride: directSttModel, stt: true)
    }

    nonisolated static func resolve(preset: ProviderPreset, baseURLOverride: String, modelOverride: String, stt: Bool) -> DirectEndpoint? {
        let base = baseURLOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (stt ? preset.sttBaseURL : preset.chatBaseURL) ?? ""
            : baseURLOverride
        let model = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (stt ? preset.defaultSttModel : preset.defaultChatModel) ?? ""
            : modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedURL(from: base), !model.isEmpty else { return nil }
        return DirectEndpoint(providerName: preset.name, baseURL: url, apiKey: APIKeyStore.key(for: preset.id), model: model)
    }

    var trimmedToken: String? {
        let token = backendToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

extension TriggerLogic.TapBehavior {
    /// Picker label. The key is "Right Option" on the Mac and the mic button on the phone.
    var title: String {
        switch self {
        case .latch: return "Starts listening; tap again to stop"
        case .doubleTapLatches: return "Nothing; double-tap to keep listening"
        case .send: return "Sends the short recording"
        }
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case local
    case direct
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: return "On this Mac (Parakeet v3)"
        case .direct: return "A provider, directly with your API key"
        case .cloud: return "The Worker (self-hosted backend)"
        }
    }
}

enum CleanupEngine: String, CaseIterable, Identifiable, Sendable {
    case direct
    case apple
    case worker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "A provider, directly with your API key"
        case .apple: return "Apple on-device model"
        case .worker: return "The Worker (self-hosted backend)"
        }
    }
}
