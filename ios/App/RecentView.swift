import SwiftUI

/// The last 50 dictations, raw next to final, so it is obvious what cleanup changed.
struct RecentView: View {
    @EnvironmentObject private var recent: RecentDictations

    var body: some View {
        NavigationStack {
            List {
                ForEach(recent.records) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(record.date, style: .time)
                            Text("·")
                            Text(record.engineLabel)
                            Spacer()
                            Text("\(record.sttMs) ms")
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

                        Text("\(record.cleanupLabel) · \(record.cleanupMs) ms · from the \(record.source)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Recent")
            .toolbar {
                if !recent.records.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear") { recent.clear() }
                    }
                }
            }
            .overlay {
                if recent.records.isEmpty {
                    ContentUnavailableView("Nothing yet", systemImage: "clock",
                                           description: Text("Dictations from this launch show up here. Nothing is written to disk."))
                }
            }
        }
    }
}
