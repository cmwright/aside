import Combine
import Foundation

/// How long finished dictations are kept. `.sessionOnly` is the original behaviour: the
/// last 50 in memory, nothing written. Everything else stores them as JSON in the app's
/// Application Support folder and prunes by age on every write and launch.
enum HistoryRetention: String, CaseIterable, Identifiable, Sendable {
    case sessionOnly
    case sevenDays
    case thirtyDays
    case ninetyDays
    case oneYear
    case forever

    var id: String { rawValue }

    /// False for `.sessionOnly`: nothing touches the disk.
    var persists: Bool { self != .sessionOnly }

    /// Records older than this are dropped; nil means no age limit.
    var maxAge: TimeInterval? {
        switch self {
        case .sessionOnly, .forever: return nil
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .ninetyDays: return 90 * 86_400
        case .oneYear: return 365 * 86_400
        }
    }

    var title: String {
        switch self {
        case .sessionOnly: return "This launch only"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        case .ninetyDays: return "90 days"
        case .oneYear: return "1 year"
        case .forever: return "Forever"
        }
    }
}

/// One finished dictation, kept so the raw speech-model output can be compared with the
/// text after cleanup. The same record on both platforms; `appName` and `insertion` are
/// the Mac's, `source` (app / keyboard / control) is the iPhone's.
struct DictationRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    let date: Date
    let engine: TranscriptionMode
    var appName: String?
    var source: String?
    let rawText: String
    let finalText: String
    let sttMs: Int
    let cleanupMs: Int
    var insertion: String?
    let cleanupLabel: String

    init(id: UUID = UUID(), date: Date, engine: TranscriptionMode, appName: String? = nil, source: String? = nil,
         rawText: String, finalText: String, sttMs: Int, cleanupMs: Int, insertion: String? = nil, cleanupLabel: String) {
        self.id = id
        self.date = date
        self.engine = engine
        self.appName = appName
        self.source = source
        self.rawText = rawText
        self.finalText = finalText
        self.sttMs = sttMs
        self.cleanupMs = cleanupMs
        self.insertion = insertion
        self.cleanupLabel = cleanupLabel
    }

    var engineLabel: String {
        switch engine {
        case .local:
            #if os(iOS)
            return "Parakeet v3 (on this iPhone)"
            #else
            return "Parakeet v3 (on this Mac)"
            #endif
        case .direct: return "provider, direct"
        case .cloud: return "Worker"
        }
    }

    var changed: Bool { rawText.trimmingCharacters(in: .whitespacesAndNewlines) != finalText }
}

/// The dictation history: a ring buffer in memory, and, when the retention setting says
/// so, a JSON file that survives relaunches. Records are pruned by age on load and on
/// every addition, so the file never holds more than the user asked to keep. Changing the
/// retention re-prunes at once; choosing "this launch only" deletes the file.
@MainActor
final class DictationHistory: ObservableObject {
    /// In-memory size when nothing is stored.
    static let sessionCapacity = 50
    /// A hard ceiling for the stored file, well above a year of heavy use.
    static let storedCapacity = 20_000

    @Published private(set) var records: [DictationRecord] = []

    let fileURL: URL
    private let settings: AppSettings
    private var retentionObserver: AnyCancellable?

    /// `~/Library/Application Support/Aside/history.json` on the Mac; the app's own
    /// Application Support on the iPhone (not the App Group: the extensions never need it).
    nonisolated static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Aside", isDirectory: true).appendingPathComponent("history.json")
    }

    #if os(macOS)
    static let shared = DictationHistory(fileURL: DictationHistory.defaultFileURL, settings: AppSettings.shared)

    /// The opt-in JSON-lines log for `tail -f` while experimenting; separate from retention.
    nonisolated static var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Aside", isDirectory: true)
            .appendingPathComponent("dictations.jsonl")
    }
    #endif

    init(fileURL: URL, settings: AppSettings) {
        self.fileURL = fileURL
        self.settings = settings
        load()
        retentionObserver = settings.$historyRetention
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.retentionChanged() }
            }
    }

    var retention: HistoryRetention { settings.historyRetention }

    func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        prune()
        save()
        #if os(macOS)
        if settings.logDictationsToFile { appendToLog(record) }
        #endif
    }

    func remove(ids: Set<UUID>) {
        records.removeAll { ids.contains($0.id) }
        save()
    }

    func clear() {
        records.removeAll()
        save()
    }

    /// The retention picker changed: drop what is now too old, and start or stop storing.
    func retentionChanged() {
        prune()
        save()
    }

    // MARK: - Storage

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

    private func prune() {
        let retention = retention
        guard retention.persists else {
            if records.count > DictationHistory.sessionCapacity {
                records.removeLast(records.count - DictationHistory.sessionCapacity)
            }
            return
        }
        if let maxAge = retention.maxAge {
            let cutoff = Date().addingTimeInterval(-maxAge)
            records.removeAll { $0.date < cutoff }
        }
        if records.count > DictationHistory.storedCapacity {
            records.removeLast(records.count - DictationHistory.storedCapacity)
        }
    }

    private func load() {
        guard retention.persists else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            records = try DictationHistory.decoder.decode([DictationRecord].self, from: data)
                .sorted { $0.date > $1.date }
            let before = records.count
            prune()
            if records.count != before { save() }
        } catch {
            Log.store.error("Could not read history.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        guard retention.persists, !records.isEmpty else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try DictationHistory.encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            Log.store.error("Could not write history.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    #if os(macOS)
    private func appendToLog(_ record: DictationRecord) {
        struct Line: Encodable {
            let time: String, engine: String, app: String?, raw: String, final: String
            let stt_ms: Int, cleanup_ms: Int, insertion: String?, cleanup: String
        }
        let line = Line(
            time: ISO8601DateFormatter().string(from: record.date), engine: record.engine.rawValue,
            app: record.appName, raw: record.rawText, final: record.finalText,
            stt_ms: record.sttMs, cleanup_ms: record.cleanupMs, insertion: record.insertion,
            cleanup: record.cleanupLabel)
        do {
            let url = DictationHistory.logFileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(line)
            data.append(0x0A)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            Log.store.error("Could not append to dictations.jsonl: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
