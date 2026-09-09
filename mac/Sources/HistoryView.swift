import SwiftUI

/// Recent dictations: what the speech model heard versus what was pasted.
struct HistoryView: View {
    @ObservedObject private var history = DictationHistory.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var selection: DictationRecord.ID?

    private var selected: DictationRecord? {
        history.records.first { $0.id == selection } ?? history.records.first
    }

    var body: some View {
        HSplitView {
            List(history.records, selection: $selection) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.finalText.isEmpty ? "(nothing)" : record.finalText)
                        .lineLimit(2)
                    Text("\(record.date.formatted(date: .omitted, time: .standard)) · \(record.engine == .local ? "local" : "cloud")\(record.changed ? " · edited by cleanup" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .tag(record.id)
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
                        GridRow { Text("Inserted via").foregroundStyle(.secondary); Text(record.insertion) }
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
                    Toggle("Also append every dictation to a log file", isOn: $settings.logDictationsToFile)
                    Spacer()
                    Button("Clear") { history.clear() }.disabled(history.records.isEmpty)
                }
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

    private func pane(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
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
