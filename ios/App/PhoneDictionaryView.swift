import SwiftUI

/// The same `dictionary.json` the Mac app writes, edited on a phone. The file lives in the
/// App Group container so the keyboard could read it later.
struct PhoneDictionaryView: View {
    @EnvironmentObject private var store: DictionaryStore
    @State private var editing: DictionaryEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.entries) { entry in
                        Button {
                            editing = entry
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.term.isEmpty ? "(empty)" : entry.term)
                                    .foregroundStyle(entry.term.isEmpty ? .secondary : .primary)
                                if let replacement = entry.wire.replacement {
                                    Text("→ \(replacement)")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in
                        store.remove(ids: Set(offsets.map { store.entries[$0].id }))
                    }
                } footer: {
                    Text("A term on its own teaches the spelling. Add a replacement to rewrite what was heard — \"hyper comply\" → \"HyperComply\".")
                }
                if let error = store.lastError {
                    Section { Text(error).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Dictionary")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        let entry = DictionaryEntry(term: "", replacement: nil)
                        store.entries.append(entry)
                        editing = entry
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .topBarLeading) { EditButton() }
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView("No words yet", systemImage: "character.book.closed",
                                           description: Text("Add names and jargon the transcriber keeps getting wrong."))
                }
            }
            .sheet(item: $editing) { entry in
                DictionaryEntrySheet(entry: entry)
                    .environmentObject(store)
            }
        }
    }
}

private struct DictionaryEntrySheet: View {
    @EnvironmentObject private var store: DictionaryStore
    @Environment(\.dismiss) private var dismiss

    let entry: DictionaryEntry
    @State private var term: String = ""
    @State private var replacement: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Term") {
                    TextField("hyper comply", text: $term)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Replacement (optional)") {
                    TextField("HyperComply", text: $replacement)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle("Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        // A brand-new blank row should not survive a cancel.
                        if entry.term.isEmpty { store.entries.removeAll { $0.id == entry.id } }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                term = entry.term
                replacement = entry.replacement ?? ""
            }
        }
    }

    private func save() {
        guard let index = store.entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        store.entries[index].term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        store.entries[index].replacement = trimmedReplacement.isEmpty ? nil : trimmedReplacement
        store.save()
        dismiss()
    }
}
