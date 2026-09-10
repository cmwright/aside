import Foundation

/// Where the app keeps state that the keyboard extension also has to see.
///
/// Everything lives in the App Group container so the two processes share one dictionary,
/// one settings suite and one hand-off directory. If the container is missing — which
/// happens when the app is built without the entitlement, e.g. the unsigned CI build —
/// the app degrades to its own sandbox rather than crashing, and says so.
enum AppGroupStorage {
    /// The App Group container, or the app's own Application Support as a fallback.
    static let container: URL = {
        if let shared = AsideIPC.containerURL() { return shared }
        Log.store.error("App group \(AsideIPC.appGroupID, privacy: .public) is unavailable; falling back to the app sandbox")
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// True when the real shared container was found; the keyboard only works in that case.
    static var isShared: Bool { AsideIPC.containerURL() != nil }

    /// The same JSON file format the Mac app uses, in the shared container so the keyboard
    /// could read it later.
    static var dictionaryURL: URL { container.appendingPathComponent("dictionary.json") }

    /// Settings live in the group suite for the same reason. Computed, not stored:
    /// `UserDefaults` is not `Sendable`, so it cannot be a global constant under Swift 6.
    static var defaults: UserDefaults { UserDefaults(suiteName: AsideIPC.appGroupID) ?? .standard }

    /// The hand-off store, always rooted at the container so app and keyboard agree.
    static let ipc = AsideIPCStore(root: container)
}

/// How long a session stays alive without the user touching the app.
enum SessionLength: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    case untilEnded

    var id: String { rawValue }

    /// nil means "no expiry".
    var seconds: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .untilEnded: return nil
        }
    }

    var title: String {
        switch self {
        case .fiveMinutes: return "5 minutes"
        case .fifteenMinutes: return "15 minutes"
        case .oneHour: return "1 hour"
        case .untilEnded: return "Until I end it"
        }
    }
}

/// How long text put on the clipboard by a Control Center dictation stays there. iOS clears
/// it itself at the deadline; nothing in the app has to be running.
enum ClipboardExpiry: String, CaseIterable, Identifiable, Sendable {
    case fiveMinutes
    case thirtyMinutes
    case never

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .thirtyMinutes: return 30 * 60
        case .never: return nil
        }
    }

    var title: String {
        switch self {
        case .fiveMinutes: return "After 5 minutes"
        case .thirtyMinutes: return "After 30 minutes"
        case .never: return "Never"
        }
    }
}

/// The handful of preferences that only exist on the phone. Everything the Mac app also
/// has (backend, cleanup level, engines) comes from the shared `AppSettings`.
@MainActor
final class PhoneSettings: ObservableObject {
    static let shared = PhoneSettings()

    private enum Key {
        static let sessionLength = "sessionLength"
        static let askedForNotifications = "askedForNotifications"
        static let clipboardExpiry = "clipboardExpiry"
    }

    private let defaults: UserDefaults

    @Published var sessionLength: SessionLength {
        didSet { defaults.set(sessionLength.rawValue, forKey: Key.sessionLength) }
    }

    /// So the notification prompt is only ever raised once, on the first session.
    @Published var askedForNotifications: Bool {
        didSet { defaults.set(askedForNotifications, forKey: Key.askedForNotifications) }
    }

    @Published var clipboardExpiry: ClipboardExpiry {
        didSet { defaults.set(clipboardExpiry.rawValue, forKey: Key.clipboardExpiry) }
    }

    init(defaults: UserDefaults = AppGroupStorage.defaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.sessionLength: SessionLength.fifteenMinutes.rawValue,
            Key.clipboardExpiry: ClipboardExpiry.fiveMinutes.rawValue,
        ])
        sessionLength = SessionLength(rawValue: defaults.string(forKey: Key.sessionLength) ?? "") ?? .fifteenMinutes
        askedForNotifications = defaults.bool(forKey: Key.askedForNotifications)
        clipboardExpiry = ClipboardExpiry(rawValue: defaults.string(forKey: Key.clipboardExpiry) ?? "") ?? .fiveMinutes
    }
}
