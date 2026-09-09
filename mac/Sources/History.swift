import AppKit
import Foundation

/// One finished dictation, kept so the raw speech-model output can be compared with the
/// text after cleanup. Lives in memory only unless the file log is switched on.
struct DictationRecord: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let engine: TranscriptionMode
    let appName: String?
    let rawText: String
    let finalText: String
    let sttMs: Int
    let cleanupMs: Int
    let insertion: String
    let cleanupLabel: String

    var engineLabel: String {
        switch engine {
        case .local: return "Parakeet v3 (on this Mac)"
        case .direct: return "provider, direct"
        case .cloud: return "cloud (Worker)"
        }
    }
    var changed: Bool { rawText.trimmingCharacters(in: .whitespacesAndNewlines) != finalText }
}

/// Ring buffer of recent dictations plus an opt-in JSON-lines file at
/// ~/Library/Logs/Aside/dictations.jsonl for `tail -f` while experimenting.
@MainActor
final class DictationHistory: ObservableObject {
    static let shared = DictationHistory()
    static let capacity = 50

    @Published private(set) var records: [DictationRecord] = []

    nonisolated static var logFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/Aside", isDirectory: true)
            .appendingPathComponent("dictations.jsonl")
    }

    private init() {}

    func add(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > DictationHistory.capacity { records.removeLast() }
        if AppSettings.shared.logDictationsToFile { appendToFile(record) }
    }

    func clear() { records.removeAll() }

    private func appendToFile(_ record: DictationRecord) {
        struct Line: Encodable {
            let time: String, engine: String, app: String?, raw: String, final: String
            let stt_ms: Int, cleanup_ms: Int, insertion: String, cleanup: String
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
}
