import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var localTranscriber = LocalTranscriber.shared
    @State private var healthResult: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section("Backend") {
                TextField("URL", text: $settings.backendURLString, prompt: Text(AppSettings.defaultBackendURL))
                    .textFieldStyle(.roundedBorder)
                if settings.backendURL == nil {
                    Text("Needs to be an http:// or https:// URL.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                SecureField("Token (optional)", text: $settings.backendToken)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button(checking ? "Checking…" : "Test Connection") { checkHealth() }
                        .disabled(checking || settings.backendURL == nil)
                    if let healthResult {
                        Text(healthResult)
                            .font(.caption)
                            .foregroundStyle(healthResult.hasPrefix("OK") ? .green : .red)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            Section("Transcription") {
                Picker("Engine", selection: $settings.transcriptionMode) {
                    ForEach(TranscriptionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: settings.transcriptionMode) { _, mode in
                    if mode == .local { localTranscriber.prepare() }
                }
                if settings.transcriptionMode == .local {
                    HStack {
                        Text(localTranscriber.state.label)
                            .font(.caption)
                            .foregroundStyle(localTranscriber.state == .ready ? .green : .secondary)
                        if localTranscriber.state != .ready && localTranscriber.state != .loading {
                            Button("Download model") { localTranscriber.prepare() }
                        }
                    }
                    Text("Audio never leaves this Mac. First use downloads about 600 MB. The transcript still goes to the backend for cleanup and dictionary replacements unless Cleanup is None and no entry has a replacement.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Cleanup", selection: $settings.cleanup) {
                    ForEach(CleanupLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("Trigger") {
                Toggle("Hold Right Option to talk", isOn: $settings.holdRightOption)
                Text("Hold the key, speak, let go. Needs Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Double-tap Right Option to keep listening", isOn: $settings.doubleTapToLatch)
                    .disabled(!settings.holdRightOption)
                Text("Tap twice to go hands-free; tap once more to stop and send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                KeyboardShortcuts.Recorder("Or a shortcut that toggles:", name: .toggleDictation)
                Text("The shortcut is press-to-start, press-again-to-stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Feedback") {
                Toggle("Play a sound on start and stop", isOn: $settings.playSounds)
            }
        }
        .formStyle(.grouped)
    }

    private func checkHealth() {
        guard let url = settings.backendURL else { return }
        let token = settings.trimmedToken
        checking = true
        healthResult = nil
        Task { @MainActor in
            do {
                let body = try await BackendClient().health(baseURL: url, token: token)
                healthResult = "OK \(body.prefix(120))"
            } catch {
                healthResult = error.localizedDescription
            }
            checking = false
        }
    }
}
