import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var localTranscriber = LocalTranscriber.shared
    @ObservedObject private var appleCleanup = AppleCleanup.shared
    @State private var healthResult: String?
    @State private var checking = false
    @State private var chatKey = ""
    @State private var sttKey = ""
    @State private var chatTest: String?
    @State private var sttTest: String?

    var body: some View {
        Form {
            Section("Direct providers (your own API keys)") {
                directProviderRows(
                    title: "Cleanup provider", presets: ProviderPreset.all,
                    providerID: $settings.directChatProvider, baseURL: $settings.directChatBaseURL,
                    model: $settings.directChatModel, key: $chatKey, stt: false, result: $chatTest)
                Divider()
                directProviderRows(
                    title: "Speech provider", presets: ProviderPreset.sttCapable,
                    providerID: $settings.directSttProvider, baseURL: $settings.directSttBaseURL,
                    model: $settings.directSttModel, key: $sttKey, stt: true, result: $sttTest)
                Text("Any service that speaks the OpenAI API works. Keys are stored in your login keychain and are sent only to that provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { reloadKeys() }
            .onChange(of: settings.directChatProvider) { _, _ in reloadKeys(); chatTest = nil }
            .onChange(of: settings.directSttProvider) { _, _ in reloadKeys(); sttTest = nil }

            Section("Worker backend (optional, self-hosted)") {
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

                Picker("Cleanup engine", selection: $settings.cleanupEngine) {
                    ForEach(CleanupEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(settings.cleanup == .none)
                .onChange(of: settings.cleanupEngine) { _, engine in
                    appleCleanup.refresh()
                    if engine == .apple { appleCleanup.prewarm() }
                }
                if settings.cleanupEngine == .apple {
                    Text(appleCleanup.availability.label)
                        .font(.caption)
                        .foregroundStyle(appleCleanup.availability == .available ? .green : .red)
                    Text("Apple Intelligence's built-in model runs the cleanup pass and the dictionary is applied locally, so with on-device transcription nothing leaves this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    @ViewBuilder
    private func directProviderRows(
        title: String, presets: [ProviderPreset], providerID: Binding<String>, baseURL: Binding<String>,
        model: Binding<String>, key: Binding<String>, stt: Bool, result: Binding<String?>
    ) -> some View {
        let preset = ProviderPreset.preset(id: providerID.wrappedValue)
        Picker(title, selection: providerID) {
            ForEach(presets) { Text($0.name).tag($0.id) }
        }
        if preset.id == ProviderPreset.custom.id || (stt ? preset.sttBaseURL : preset.chatBaseURL) == nil {
            TextField("Base URL", text: baseURL, prompt: Text("https://host/v1"))
                .textFieldStyle(.roundedBorder)
        }
        TextField("Model", text: model, prompt: Text((stt ? preset.defaultSttModel : preset.defaultChatModel) ?? "model id"))
            .textFieldStyle(.roundedBorder)
        if preset.needsKey {
            HStack {
                SecureField("API key", text: key)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key.wrappedValue) { _, value in APIKeyStore.set(value, for: preset.id) }
                if let url = preset.keyURL, let link = URL(string: url) {
                    Link("Get a key", destination: link).font(.caption)
                }
            }
        }
        HStack {
            Button("Test") { testProvider(stt: stt, result: result) }
            if let text = result.wrappedValue {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(text.hasPrefix("OK") ? .green : .red)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func reloadKeys() {
        chatKey = APIKeyStore.key(for: settings.directChatProvider) ?? ""
        sttKey = APIKeyStore.key(for: settings.directSttProvider) ?? ""
    }

    private func testProvider(stt: Bool, result: Binding<String?>) {
        guard let endpoint = stt ? settings.directSttEndpoint() : settings.directChatEndpoint() else {
            result.wrappedValue = "Base URL or model is missing."
            return
        }
        let preset = ProviderPreset.preset(id: stt ? settings.directSttProvider : settings.directChatProvider)
        if preset.needsKey && (endpoint.apiKey ?? "").isEmpty {
            result.wrappedValue = "No API key stored for \(preset.name). Paste it in the field above."
            return
        }
        result.wrappedValue = "Checking…"
        Task { @MainActor in
            do {
                let models = try await DirectClient().listModels(endpoint: endpoint)
                if models.isEmpty {
                    result.wrappedValue = "OK: reachable (model list not exposed)"
                } else if models.contains(endpoint.model) {
                    result.wrappedValue = "OK: \(endpoint.model) available (\(models.count) models)"
                } else {
                    result.wrappedValue = "Reachable, but \(endpoint.model) is not in its \(models.count) models"
                }
            } catch {
                result.wrappedValue = error.localizedDescription
            }
        }
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
