import Foundation

/// One atomic file per completed Messages dictation, imported by the main app.
/// Separate files avoid two processes overwriting each other's history arrays.
@MainActor
enum MessagesHistory {
    static var directory: URL? {
        AsideIPC.containerURL()?.appendingPathComponent("MessagesHistory", isDirectory: true)
    }

    static func store(_ record: DictationRecord) throws {
        guard let directory else { return }
        let defaults = UserDefaults(suiteName: AsideIPC.appGroupID)
        let retention = defaults?.string(forKey: "historyRetention").flatMap(HistoryRetention.init(rawValue:)) ?? .sessionOnly
        try store(record, directory: directory, retention: retention)
    }

    static func store(_ record: DictationRecord, directory: URL, retention: HistoryRetention) throws {
        guard retention.persists else {
            discardPending(directory: directory)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: directory.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
        _ = pending(directory: directory, retention: retention)
    }

    static func importPending(into history: DictationHistory, retention: HistoryRetention) {
        guard let directory else { return }
        importPending(into: history, directory: directory, retention: retention)
    }

    static func importPending(into history: DictationHistory, directory: URL, retention: HistoryRetention) {
        for (url, record) in pending(directory: directory, retention: retention) {
            // add replaces matching IDs, making retries after a failed file deletion safe.
            if history.add(record) { try? FileManager.default.removeItem(at: url) }
        }
    }

    static func pending(directory: URL, retention: HistoryRetention, now: Date = Date()) -> [(URL, DictationRecord)] {
        guard retention.persists else {
            discardPending(directory: directory)
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [(URL, DictationRecord)] = []
        for url in files(directory) {
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(DictationRecord.self, from: data) else { continue }
            if let age = retention.maxAge, record.date < now.addingTimeInterval(-age) {
                try? FileManager.default.removeItem(at: url)
            } else {
                result.append((url, record))
            }
        }
        result.sort { $0.1.date > $1.1.date }
        for (url, _) in result.dropFirst(DictationHistory.storedCapacity) {
            try? FileManager.default.removeItem(at: url)
        }
        return Array(result.prefix(DictationHistory.storedCapacity))
    }

    private static func files(_ directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
    }

    private static func discardPending(directory: URL) {
        for url in files(directory) { try? FileManager.default.removeItem(at: url) }
    }
}
