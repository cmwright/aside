import SwiftUI

/// Recent dictations, raw next to final, grouped by day. How long they are kept is chosen
/// here: in memory for this launch, or on this iPhone for a week up to forever.
struct RecentView: View {
    @EnvironmentObject private var history: DictationHistory
    @EnvironmentObject private var settings: AppSettings
    @State private var filter = ""
    @State private var copiedID: UUID?

    private var shown: [DictationRecord] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return history.records }
        return history.records.filter {
            $0.finalText.localizedCaseInsensitiveContains(needle) || $0.rawText.localizedCaseInsensitiveContains(needle)
        }
    }

    /// Newest day first; records within a day are already newest first.
    private var days: [(day: Date, records: [DictationRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: shown) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days, id: \.day) { day in
                    Section(day.day.formatted(date: .abbreviated, time: .omitted)) {
                        ForEach(day.records) { record in
                            row(record)
                        }
                        .onDelete { offsets in
                            history.remove(ids: Set(offsets.map { day.records[$0].id }))
                        }
                    }
                }
                Section {
                    Picker("Keep history", selection: $settings.historyRetention) {
                        ForEach(HistoryRetention.allCases) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                } footer: {
                    Text(settings.historyRetention.persists
                         ? "\(history.records.count) dictations are stored on this iPhone and pruned by age. Nothing leaves the device."
                         : "The last \(DictationHistory.sessionCapacity) stay in memory until Aside is closed; nothing is written to disk.")
                }
            }
            .searchable(text: $filter, prompt: "Search dictations")
            .navigationTitle("Recent")
            .toolbar {
                if !history.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear", role: .destructive) { history.clear() }
                    }
                }
            }
            .overlay {
                if history.records.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "clock",
                                           description: Text("Dictations show up here. Choose below how long to keep them."))
                }
            }
        }
    }

    private func row(_ record: DictationRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.date, style: .time)
                Text("·")
                Text(record.engineLabel)
                Spacer()
                Button(copiedID == record.id ? "Copied" : "Copy") {
                    UIPasteboard.general.string = record.finalText
                    copiedID = record.id
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(record.finalText)
                .font(.body)
                .textSelection(.enabled)

            if record.changed {
                Text(record.rawText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("\(record.cleanupLabel) · speech \(record.sttMs) ms · cleanup \(record.cleanupMs) ms · from the \(record.source ?? "app")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Copy") { UIPasteboard.general.string = record.finalText }
            if record.changed {
                Button("Copy raw transcript") { UIPasteboard.general.string = record.rawText }
            }
            Button("Delete", role: .destructive) { history.remove(ids: [record.id]) }
        }
    }
}
