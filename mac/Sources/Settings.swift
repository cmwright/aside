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
        static let doubleTapToLatch = "doubleTapToLatch"
        static let transcriptionMode = "transcriptionMode"
        static let logDictationsToFile = "logDictationsToFile"
    }

    static let defaultBackendURL = "http://localhost:8787"

    private let defaults: UserDefaults

    @Published var backendURLString: String { didSet { defaults.set(backendURLString, forKey: Key.backendURL) } }
    @Published var backendToken: String { didSet { defaults.set(backendToken, forKey: Key.backendToken) } }
    @Published var cleanup: CleanupLevel { didSet { defaults.set(cleanup.rawValue, forKey: Key.cleanup) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    /// Hold-to-talk on Right Option. This is the default trigger; the KeyboardShortcuts
    /// combo below is an optional press-to-start / press-to-stop alternative.
    @Published var holdRightOption: Bool { didSet { defaults.set(holdRightOption, forKey: Key.holdRightOption) } }
    /// Double-tap Right Option to keep listening hands-free; tap once more to stop.
    @Published var doubleTapToLatch: Bool { didSet { defaults.set(doubleTapToLatch, forKey: Key.doubleTapToLatch) } }
    /// Where speech becomes text: the Worker's provider, or Parakeet on this Mac.
    @Published var transcriptionMode: TranscriptionMode { didSet { defaults.set(transcriptionMode.rawValue, forKey: Key.transcriptionMode) } }
    /// Opt-in: append raw and final text of every dictation to ~/Library/Logs/Aside/dictations.jsonl.
    @Published var logDictationsToFile: Bool { didSet { defaults.set(logDictationsToFile, forKey: Key.logDictationsToFile) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AppSettings.migrateFromVoiceToTextIfNeeded(into: defaults)
        defaults.register(defaults: [
            Key.backendURL: AppSettings.defaultBackendURL,
            Key.playSounds: true,
            Key.holdRightOption: true,
            Key.doubleTapToLatch: true,
            Key.transcriptionMode: TranscriptionMode.cloud.rawValue,
            Key.logDictationsToFile: false,
            Key.cleanup: CleanupLevel.medium.rawValue,
        ])
        backendURLString = defaults.string(forKey: Key.backendURL) ?? AppSettings.defaultBackendURL
        backendToken = defaults.string(forKey: Key.backendToken) ?? ""
        cleanup = CleanupLevel(rawValue: defaults.string(forKey: Key.cleanup) ?? "") ?? .medium
        playSounds = defaults.bool(forKey: Key.playSounds)
        holdRightOption = defaults.bool(forKey: Key.holdRightOption)
        doubleTapToLatch = defaults.bool(forKey: Key.doubleTapToLatch)
        transcriptionMode = TranscriptionMode(rawValue: defaults.string(forKey: Key.transcriptionMode) ?? "") ?? .cloud
        logDictationsToFile = defaults.bool(forKey: Key.logDictationsToFile)
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
                                 Key.holdRightOption, Key.doubleTapToLatch, Key.transcriptionMode]
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

    var trimmedToken: String? {
        let token = backendToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }
}

enum TranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case cloud
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: return "Cloud (the Worker's provider)"
        case .local: return "On this Mac (Parakeet v3)"
        }
    }
}
