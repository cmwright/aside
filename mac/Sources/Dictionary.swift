import Foundation
import SwiftUI

/// One vocabulary hint. `term` is what the user says; `replacement`, when present, is what
/// should be written instead ("hyper comply" -> "HyperComply").
struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var term: String
    var replacement: String?

    init(id: UUID = UUID(), term: String, replacement: String? = nil) {
        self.id = id
        self.term = term
        self.replacement = replacement
    }

    /// Wire form for the `dictionary` multipart field: only `term` and `replacement`.
    struct Wire: Codable, Sendable {
        var term: String
        var replacement: String?
    }

    var wire: Wire {
        let trimmed = replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Wire(term: term.trimmingCharacters(in: .whitespacesAndNewlines),
                    replacement: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }
}

enum DictionaryCodec {
    /// The JSON string that goes into the `dictionary` multipart field. Entries with an
    /// empty term are dropped so a half-finished table row never reaches the backend.
    static func encodeForRequest(_ entries: [DictionaryEntry]) -> String {
        let wire = entries.map(\.wire).filter { !$0.term.isEmpty }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(wire), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    /// Pretty JSON for export. Round-trips through `decode`.
    static func encodeForFile(_ entries: [DictionaryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries.map(\.wire).filter { !$0.term.isEmpty })
    }

    /// Accepts either the app's own export or a bare `[{"term": ...}]` array.
    static func decode(_ data: Data) throws -> [DictionaryEntry] {
        let wire = try JSONDecoder().decode([DictionaryEntry.Wire].self, from: data)
        return wire
            .map { DictionaryEntry(term: $0.term, replacement: $0.replacement) }
            .filter { !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Loads and saves `~/Library/Application Support/VoiceToText/dictionary.json`.
@MainActor
final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published var entries: [DictionaryEntry] = []
    @Published var lastError: String?

    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? DictionaryStore.defaultFileURL()
        load()
    }

    static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VoiceToText", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            entries = try DictionaryCodec.decode(Data(contentsOf: fileURL))
            Log.store.info("Loaded \(self.entries.count, privacy: .public) dictionary entries")
        } catch {
            lastError = "Could not read dictionary.json: \(error.localizedDescription)"
            Log.store.error("Dictionary load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try DictionaryCodec.encodeForFile(entries).write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not write dictionary.json: \(error.localizedDescription)"
            Log.store.error("Dictionary save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds a blank row and returns its id, unless a blank row already exists, in which
    /// case that row's id is returned so the caller can focus it instead of stacking up
    /// empty rows.
    @discardableResult
    func add() -> DictionaryEntry.ID {
        if let blank = entries.first(where: { $0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return blank.id
        }
        let entry = DictionaryEntry(term: "", replacement: nil)
        entries.append(entry)
        return entry.id
    }

    func remove(ids: Set<DictionaryEntry.ID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func importJSON(from url: URL) {
        do {
            let imported = try DictionaryCodec.decode(Data(contentsOf: url))
            entries = DictionaryStore.merge(existing: entries, imported: imported)
            save()
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportJSON(to url: URL) {
        do {
            try DictionaryCodec.encodeForFile(entries).write(to: url, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
        }
    }

    /// Imported entries win on a case-insensitive term collision; new terms are appended.
    nonisolated static func merge(existing: [DictionaryEntry], imported: [DictionaryEntry]) -> [DictionaryEntry] {
        var result = existing
        for entry in imported {
            let key = entry.term.lowercased()
            if let index = result.firstIndex(where: { $0.term.lowercased() == key }) {
                result[index].replacement = entry.replacement
            } else {
                result.append(entry)
            }
        }
        return result
    }
}
