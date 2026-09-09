import SwiftUI

/// The same preferences the Mac app has, plus session length, backed by the App Group
/// defaults suite so the keyboard could read them later.
struct PhoneSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var phone: PhoneSettings
    @EnvironmentObject private var controller: SessionController
    @StateObject private var transcriber = LocalTranscriber.shared
    @StateObject private var appleCleanup = AppleCleanup.shared

    @State private var healthResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Transcription", selection: $settings.transcriptionMode) {
                        Text("On this iPhone (Parakeet v3)").tag(TranscriptionMode.local)
                        Text("A provider, directly with your API key").tag(TranscriptionMode.direct)
                        Text("The Worker (self-hosted backend)").tag(TranscriptionMode.cloud)
                    }
                    if settings.transcriptionMode == .local {
                        HStack {
                            Text(parakeetStatus).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            if transcriber.state == .notLoaded || isFailed(transcriber.state) {
                                Button("Load") { transcriber.prepare() }.font(.footnote)
                            }
                        }
                    }
                } header: {
                    Text("Speech to text")
                } footer: {
                    if settings.transcriptionMode == .local {
                        Text("Runs offline on the Neural Engine after a one-time ~600 MB download.")
                    }
                }

                Section("Cleanup") {
                    Picker("Level", selection: $settings.cleanup) {
                        Text("None — raw transcript").tag(CleanupLevel.none)
                        Text("Light — punctuation, dictionary").tag(CleanupLevel.light)
                        Text("Medium — also fillers and grammar").tag(CleanupLevel.medium)
                    }
                    Picker("Engine", selection: $settings.cleanupEngine) {
                        Text("A provider, directly").tag(CleanupEngine.direct)
                        Text("Apple on-device model").tag(CleanupEngine.apple)
                        Text("The Worker").tag(CleanupEngine.worker)
                    }
                    .disabled(settings.cleanup == .none)
                    if settings.cleanupEngine == .apple, settings.cleanup != .none {
                        Text(appleStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if usesDirect {
                    if settings.cleanupEngine == .direct, settings.cleanup != .none {
                        DirectProviderSection(
                            title: "Cleanup provider",
                            presets: ProviderPreset.all,
                            providerID: $settings.directChatProvider,
                            model: $settings.directChatModel,
                            baseURL: $settings.directChatBaseURL,
                            endpoint: settings.directChatEndpoint(),
                            stt: false)
                    }
                    if settings.transcriptionMode == .direct {
                        DirectProviderSection(
                            title: "Speech provider",
                            presets: ProviderPreset.sttCapable,
                            providerID: $settings.directSttProvider,
                            model: $settings.directSttModel,
                            baseURL: $settings.directSttBaseURL,
                            endpoint: settings.directSttEndpoint(),
                            stt: true)
                    }
                }

                if usesWorker {
                    Section {
                        TextField("http://localhost:8787", text: $settings.backendURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        SecureField("Token (optional)", text: $settings.backendToken)
                        Button(testing ? "Testing…" : "Test Connection") { test() }
                            .disabled(testing || settings.backendURL == nil)
                        if let healthResult {
                            Text(healthResult).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Worker")
                    } footer: {
                        Text("A phone cannot reach your Mac's localhost — use the Mac's LAN address or a deployed Worker.")
                    }
                }

                Section {
                    Picker("Session length", selection: $phone.sessionLength) {
                        ForEach(SessionLength.allCases) { length in
                            Text(length.title).tag(length)
                        }
                    }
                } header: {
                    Text("Session")
                } footer: {
                    Text("A session keeps the microphone alive in the background so the keyboard can dictate without another app switch. Changing this applies to the next session.")
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.transcriptionMode) { _, _ in controller.prepareEngines() }
            .onChange(of: settings.cleanupEngine) { _, _ in controller.prepareEngines() }
        }
    }

    private var usesDirect: Bool {
        settings.transcriptionMode == .direct || (settings.cleanupEngine == .direct && settings.cleanup != .none)
    }

    private var usesWorker: Bool {
        settings.transcriptionMode == .cloud || (settings.cleanupEngine == .worker && settings.cleanup != .none)
    }

    private var parakeetStatus: String {
        switch transcriber.state {
        case .notLoaded: return "Model not downloaded yet (~600 MB, once)."
        case .loading: return "Downloading / loading Parakeet v3…"
        case .ready: return "Parakeet v3 ready."
        case .failed(let message): return "Model failed: \(message)"
        }
    }

    private func isFailed(_ state: LocalTranscriber.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// `AppleCleanup` is shared with the Mac app and phrases its reasons for a Mac; this is
    /// the one place that has to say "iPhone" instead. The shared file is not edited for it.
    private var appleStatus: String {
        switch appleCleanup.availability {
        case .available:
            return "Apple on-device model: available."
        case .unsupportedOS:
            return "Apple on-device model needs iOS 26 or later."
        case .unavailable(let why):
            return "Apple on-device model unavailable: "
                + why.replacingOccurrences(of: "this Mac", with: "this iPhone")
                    .replacingOccurrences(of: "System Settings", with: "Settings")
        }
    }

    private func test() {
        guard let baseURL = settings.backendURL else { return }
        testing = true
        healthResult = nil
        let token = settings.trimmedToken
        Task {
            do {
                healthResult = try await BackendClient().health(baseURL: baseURL, token: token)
            } catch {
                healthResult = error.localizedDescription
            }
            testing = false
        }
    }
}

/// One provider's settings: which service, which model, which base URL, and the API key —
/// which goes to the keychain, never to `UserDefaults`.
private struct DirectProviderSection: View {
    let title: String
    let presets: [ProviderPreset]
    @Binding var providerID: String
    @Binding var model: String
    @Binding var baseURL: String
    let endpoint: DirectEndpoint?
    let stt: Bool

    @State private var apiKey = ""
    @State private var status: String?
    @State private var testing = false

    private var preset: ProviderPreset { ProviderPreset.preset(id: providerID) }

    var body: some View {
        Section {
            Picker("Provider", selection: $providerID) {
                ForEach(presets) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            TextField(placeholderModel, text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(placeholderBaseURL, text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            if preset.needsKey {
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, value in
                        APIKeyStore.set(value, for: preset.id)
                    }
            }
            Button(testing ? "Testing…" : "Test") { test() }
                .disabled(testing || endpoint == nil)
            if let status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text(title)
        } footer: {
            Text(stt
                 ? "Audio is posted straight to this provider from your phone. Leave the model and base URL empty to use the provider's defaults."
                 : "The transcript is sent to this provider for cleanup. Leave the model and base URL empty to use the provider's defaults.")
        }
        .onAppear { apiKey = APIKeyStore.key(for: preset.id) ?? "" }
        .onChange(of: providerID) { _, id in
            apiKey = APIKeyStore.key(for: id) ?? ""
            status = nil
        }
    }

    private var placeholderModel: String {
        (stt ? preset.defaultSttModel : preset.defaultChatModel) ?? "model"
    }

    private var placeholderBaseURL: String {
        (stt ? preset.sttBaseURL : preset.chatBaseURL) ?? "https://…/v1"
    }

    /// `GET /models` is the cheapest call that proves the key and the base URL.
    private func test() {
        guard let endpoint else { return }
        testing = true
        status = nil
        Task {
            do {
                let models = try await DirectClient().listModels(endpoint: endpoint)
                status = models.contains(endpoint.model)
                    ? "OK — \(endpoint.model) is available."
                    : "Reached \(endpoint.providerName); it listed \(models.count) models but not \(endpoint.model)."
            } catch {
                status = error.localizedDescription
            }
            testing = false
        }
    }
}
