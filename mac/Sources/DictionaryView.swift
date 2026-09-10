import SwiftUI
import UniformTypeIdentifiers

/// Table of vocabulary hints, saved to disk on every edit.
struct DictionaryView: View {
    @EnvironmentObject private var store: DictionaryStore
    @State private var selection: Set<DictionaryEntry.ID> = []
    @State private var importing = false
    @State private var exporting = false
    @FocusState private var focusedTerm: DictionaryEntry.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Words the transcriber should get right. Leave Replacement empty to just teach it the spelling; fill it in to rewrite what it heard (say “hyper comply”, write “HyperComply”).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Table(of: Binding<DictionaryEntry>.self, selection: $selection) {
                TableColumn("Term") { $entry in
                    TextField("term", text: $entry.term)
                        .textFieldStyle(.plain)
                        .focused($focusedTerm, equals: entry.id)
                        .onSubmit { store.save() }
                }
                TableColumn("Replacement (optional)") { $entry in
                    TextField("", text: Binding(
                        get: { entry.replacement ?? "" },
                        set: { entry.replacement = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.plain)
                    .onSubmit { store.save() }
                }
            } rows: {
                ForEach($store.entries) { $entry in
                    TableRow($entry)
                }
            }
            .frame(minHeight: 160, idealHeight: 280, maxHeight: .infinity)

            HStack {
                Button {
                    addRow()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .keyboardShortcut("n")
                Button {
                    store.remove(ids: selection)
                    selection = []
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selection.isEmpty)

                Spacer()

                Button("Import…") { importing = true }
                Button("Export…") { exporting = true }
                Button("Save") { store.save() }
                    .keyboardShortcut("s")
            }

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Stored at \(store.fileURL.path)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(16)
        .onDisappear { store.save() }
        .onChange(of: focusedTerm) { _, _ in store.save() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                store.importJSON(from: url)
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: DictionaryDocument(entries: store.entries),
            contentType: .json,
            defaultFilename: "dictionary"
        ) { _ in }
    }
}

extension DictionaryView {
    /// Add (or reuse the existing blank row), select it, and put the cursor in its Term
    /// field. The focus change is deferred one run-loop turn because the Table creates
    /// the new row's cells lazily and focus cannot land on a field that does not exist yet.
    private func addRow() {
        let id = store.add()
        selection = [id]
        DispatchQueue.main.async { focusedTerm = id }
    }
}

/// Minimal `FileDocument` so `fileExporter` can write the same JSON the store saves.
struct DictionaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var entries: [DictionaryEntry]

    init(entries: [DictionaryEntry]) {
        self.entries = entries
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        entries = try DictionaryCodec.decode(data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try DictionaryCodec.encodeForFile(entries))
    }
}
