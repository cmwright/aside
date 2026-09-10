import SwiftUI

/// Recent dictations: what the speech model heard versus what was pasted.
struct HistoryView: View {
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: DictationRecord.ID?
    @State private var filter = ""

    private var shown: [DictationRecord] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return history.records }
        return history.records.filter {
            $0.finalText.localizedCaseInsensitiveContains(needle) || $0.rawText.localizedCaseInsensitiveContains(needle)
        }
    }

    private var selected: DictationRecord? {
        shown.first { $0.id == selection } ?? shown.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(shown, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.finalText.isEmpty ? "(nothing)" : record.finalText)
                        .lineLimit(2)
                    Text("\(record.date.formatted(date: .omitted, time: .standard)) · \(record.engine == .local ? "local" : record.engine == .direct ? "direct" : "worker")\(record.changed ? " · edited by cleanup" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(record.id)
                .contextMenu {
                    Button("Copy") { copy(record.finalText) }
                    Button("Delete") { history.remove(ids: [record.id]) }
                }
            }
            }
            .frame(minWidth: 220, idealWidth: 260)

            VStack(alignment: .leading, spacing: 10) {
                if let record = selected {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        GridRow { Text("Engine").foregroundStyle(.secondary); Text(record.engineLabel) }
                        GridRow { Text("Cleanup").foregroundStyle(.secondary); Text(record.cleanupLabel) }
                        GridRow { Text("App").foregroundStyle(.secondary); Text(record.appName ?? "unknown") }
                        GridRow {
                            Text("Timing").foregroundStyle(.secondary)
                            Text("speech \(record.sttMs) ms · cleanup \(record.cleanupMs > 0 ? "\(record.cleanupMs) ms" : "skipped")")
                        }
                        GridRow { Text("Inserted via").foregroundStyle(.secondary); Text(record.insertion ?? "—") }
                    }
                    .font(.callout)

                    pane("Raw, from the speech model", record.rawText)
                    pane("Final, after cleanup and dictionary", record.finalText)
                } else {
                    Spacer()
                    Text("No dictations yet. Hold Right Option and say something.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }

                HStack {
                    Picker("Keep history", selection: $settings.historyRetention) {
                        ForEach(HistoryRetention.allCases) { retention in
                            Text(retention.title).tag(retention)
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Clear") { history.clear() }.disabled(history.records.isEmpty)
                }
                Text(settings.historyRetention.persists
                     ? "\(history.records.count) dictations stored on this Mac in \(history.fileURL.path)"
                     : "The last \(DictationHistory.sessionCapacity) stay in memory until Aside quits; nothing is written.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Toggle("Also append every dictation to a log file", isOn: $settings.logDictationsToFile)
                if settings.logDictationsToFile {
                    Text("tail -f \"\(DictationHistory.logFileURL.path)\"")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
            .frame(minWidth: 380)
        }
        .onAppear { if selection == nil { selection = history.records.first?.id } }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copy(text) }
                    .controlSize(.small)
            }
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 70)
        }
    }
}
