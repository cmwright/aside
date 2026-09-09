import Foundation

/// The hand-off between the Aside iPhone app and its keyboard extension.
///
/// An iOS keyboard extension cannot touch the microphone, so the app does the recording and
/// the keyboard only asks for it and pastes the answer. Everything travels through the App
/// Group container as small JSON files rather than `UserDefaults`, because two processes
/// reading the same defaults suite see cached values at unpredictable moments, while the
/// file system is coherent. Every write is atomic, so a reader never sees half a file.
///
/// Layout inside the container:
///
///     session.json              written by the app
///     commands/<uuid>.json      written by the keyboard
///     results/<uuid>.json       written by the app, keyed by the command id
///
/// Foundation only: this file is compiled into the app, the keyboard extension and the Mac
/// unit-test target.
enum AsideIPC {
    static let appGroupID = "group.com.codywright.aside"

    /// Darwin notification names. They carry no payload and are best-effort — the kernel
    /// coalesces them and drops them for suspended processes — so both sides also poll.
    static let commandNotification = "com.codywright.aside.command"
    static let resultNotification = "com.codywright.aside.result"

    /// How often each side re-reads the directory while a dictation is in flight.
    static let pollInterval: TimeInterval = 0.25

    /// Command and result files older than this are swept on session start.
    static let staleAge: TimeInterval = 600

    /// How much text before the cursor the keyboard sends, for the leading-space decision.
    static let contextBeforeLimit = 40

    /// The App Group container, or nil when the caller has no entitlement for it — which is
    /// exactly what a keyboard extension without "Allow Full Access" sees.
    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    // MARK: - Pure decisions

    /// A session counts as usable when the file says active and its expiry, if any, is in
    /// the future. A missing file is no session.
    static func isActive(_ session: SessionState?, at now: Date) -> Bool {
        guard let session, session.active else { return false }
        guard let expiresAt = session.expiresAt else { return true }
        return expiresAt > now
    }

    /// Same rule as the Mac's `TextInserter.needsLeadingSpace`: add a space when the new
    /// text would otherwise be glued onto the end of a word. With no context (the keyboard
    /// could not read the document) nothing is guessed.
    static func needsLeadingSpace(contextBefore: String?, text: String) -> Bool {
        guard let previous = contextBefore?.last, let first = text.first else { return false }
        guard previous.isLetter || previous.isNumber else { return false }
        return first.isLetter
    }

    /// Oldest first. The id breaks ties so two commands written inside the same clock tick
    /// still have one stable order on both sides.
    static func ordered(_ commands: [DictationCommand]) -> [DictationCommand] {
        commands.sorted {
            $0.at == $1.at ? $0.id.uuidString < $1.id.uuidString : $0.at < $1.at
        }
    }

    /// The last `contextBeforeLimit` characters of what is in front of the cursor.
    static func trimContext(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(text.suffix(contextBeforeLimit))
    }
}

// MARK: - Wire types

/// `session.json`. `pid` is only for diagnostics: a stale file left by a killed app still
/// expires on its own.
struct SessionState: Codable, Equatable, Sendable {
    var active: Bool
    var startedAt: Date
    var expiresAt: Date?
    var pid: Int

    init(active: Bool, startedAt: Date, expiresAt: Date?, pid: Int = Int(ProcessInfo.processInfo.processIdentifier)) {
        self.active = active
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.pid = pid
    }
}

/// `commands/<uuid>.json`, written by the keyboard.
struct DictationCommand: Codable, Equatable, Sendable, Identifiable {
    enum Action: String, Codable, Sendable {
        case start
        case stop
        case cancel
    }

    var id: UUID
    var action: Action
    var at: Date
    /// The last ~40 characters before the cursor, so the app can decide on a leading space.
    var contextBefore: String?

    init(id: UUID = UUID(), action: Action, at: Date = Date(), contextBefore: String? = nil) {
        self.id = id
        self.action = action
        self.at = at
        self.contextBefore = contextBefore
    }
}

/// `results/<uuid>.json`, written by the app under the id of the `start` command.
struct DictationResult: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case recording
        case processing
        case done
        case failed
    }

    var id: UUID
    var status: Status
    var text: String?
    var rawText: String?
    var error: String?
    var engine: String?
    var cleanup: String?
    var sttMs: Int?
    var cleanupMs: Int?

    init(id: UUID, status: Status, text: String? = nil, rawText: String? = nil, error: String? = nil,
         engine: String? = nil, cleanup: String? = nil, sttMs: Int? = nil, cleanupMs: Int? = nil) {
        self.id = id
        self.status = status
        self.text = text
        self.rawText = rawText
        self.error = error
        self.engine = engine
        self.cleanup = cleanup
        self.sttMs = sttMs
        self.cleanupMs = cleanupMs
    }

    /// Nothing more will happen to this dictation.
    var isFinal: Bool { status == .done || status == .failed }
}

// MARK: - Store

enum AsideIPCError: LocalizedError {
    case noContainer

    var errorDescription: String? {
        switch self {
        case .noContainer:
            return "The Aside app group is not reachable. In the keyboard this means Allow Full Access is off."
        }
    }
}

/// Typed reads and writes over one directory. `root` is the App Group container in the app
/// and the extension, and a temporary directory in tests; `now` is the injected clock.
struct AsideIPCStore: Sendable {
    let root: URL
    private let now: @Sendable () -> Date

    init(root: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.root = root
        self.now = now
    }

    /// `FileManager.default` is documented as safe to use from multiple threads for these
    /// calls, and it is not `Sendable`, so it is reached for rather than stored.
    private var fileManager: FileManager { .default }

    /// The store for this process's App Group container, or nil without the entitlement.
    static func appGroup(now: @escaping @Sendable () -> Date = { Date() }) -> AsideIPCStore? {
        guard let container = AsideIPC.containerURL() else { return nil }
        return AsideIPCStore(root: container, now: now)
    }

    var sessionURL: URL { root.appendingPathComponent("session.json") }
    var commandsDirectory: URL { root.appendingPathComponent("commands", isDirectory: true) }
    var resultsDirectory: URL { root.appendingPathComponent("results", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Session

    func writeSession(_ session: SessionState) throws {
        try write(session, to: sessionURL)
    }

    func readSession() -> SessionState? {
        read(SessionState.self, from: sessionURL)
    }

    /// The session if it is active and unexpired, else nil.
    func activeSession() -> SessionState? {
        let session = readSession()
        return AsideIPC.isActive(session, at: now()) ? session : nil
    }

    /// Marks the session inactive, keeping the timestamps so the keyboard can say why.
    func endSession() throws {
        let existing = readSession()
        try writeSession(SessionState(
            active: false,
            startedAt: existing?.startedAt ?? now(),
            expiresAt: existing?.expiresAt,
            pid: existing?.pid ?? Int(ProcessInfo.processInfo.processIdentifier)
        ))
    }

    // MARK: Commands

    func writeCommand(_ command: DictationCommand) throws {
        try write(command, to: commandsDirectory.appendingPathComponent("\(command.id.uuidString).json"))
    }

    /// Every command file still on disk, oldest first.
    func pendingCommands() -> [DictationCommand] {
        AsideIPC.ordered(readAll(DictationCommand.self, in: commandsDirectory))
    }

    func removeCommand(id: UUID) {
        try? fileManager.removeItem(at: commandsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    // MARK: Results

    func writeResult(_ result: DictationResult) throws {
        try write(result, to: resultsDirectory.appendingPathComponent("\(result.id.uuidString).json"))
    }

    func readResult(id: UUID) -> DictationResult? {
        read(DictationResult.self, from: resultsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    func removeResult(id: UUID) {
        try? fileManager.removeItem(at: resultsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    // MARK: Housekeeping

    /// Deletes command and result files older than `age`. Returns how many went. Called on
    /// session start so a crash mid-dictation cannot leave a transcript on disk forever.
    @discardableResult
    func purge(olderThan age: TimeInterval = AsideIPC.staleAge) -> Int {
        let cutoff = now().addingTimeInterval(-age)
        var removed = 0
        for directory in [commandsDirectory, resultsDirectory] {
            let urls = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in urls where url.pathExtension == "json" {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified < cutoff else { continue }
                if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        return removed
    }

    /// Removes everything: both directories and the session file.
    func removeAll() {
        try? fileManager.removeItem(at: commandsDirectory)
        try? fileManager.removeItem(at: resultsDirectory)
        try? fileManager.removeItem(at: sessionURL)
    }

    // MARK: Plumbing

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AsideIPCStore.encoder.encode(value).write(to: url, options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? AsideIPCStore.decoder.decode(type, from: data)
    }

    private func readAll<T: Decodable>(_ type: T.Type, in directory: URL) -> [T] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { read(type, from: $0) }
    }
}

// MARK: - Darwin notifications

/// Cross-process wake-ups. Darwin notifications are the only broadcast an app extension and
/// its container app can both use; they carry no payload and may be coalesced, so they are
/// a hint to look at the directory, never the message itself.
enum DarwinNotifier {
    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

/// Keeps one Darwin observer alive; deregisters on deinit. The callback fires on the run
/// loop of the thread that created it, so create it on the main thread.
final class DarwinObserver: @unchecked Sendable {
    private let name: String
    private let handler: @Sendable () -> Void

    init(name: String, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.handler = handler
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            pointer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<DarwinObserver>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
