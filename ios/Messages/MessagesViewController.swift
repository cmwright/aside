import Messages
import SwiftUI

@MainActor
final class MessagesViewController: MSMessagesAppViewController {
    private let model = MessageComposerModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self
        view.backgroundColor = UIColor(Theme.bg)
        let host = UIHostingController(rootView: AsideMessageComposer(model: model))
        addChild(host)
        host.view.backgroundColor = UIColor(Theme.bg)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        model.reset()
    }

    override func didBecomeActive(with conversation: MSConversation) {
        super.didBecomeActive(with: conversation)
        model.record()
    }

    override func willResignActive(with conversation: MSConversation) {
        model.reset()
        super.willResignActive(with: conversation)
    }
}

@MainActor
final class MessageComposerModel: ObservableObject {
    weak var controller: MessagesViewController?
    @Published var text = ""
    @Published private(set) var busy = false
    @Published private(set) var status = "Tap Record to speak with Aside."
    private var task: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var request: UUID?
    @Published private(set) var recording = false
    @Published private(set) var level: Float = 0
    private let recorder = SessionRecorder()
    private var recordingMonitor: Task<Void, Never>?
    private var endpoint = SilenceEndpoint()
    private var pipelinePlan: DictationPipeline.Plan?
    private var recordingID = UUID()
    private var sttMilliseconds = 0
    private var playSounds = true
    private let sounds = RecordingSounds()
    @Published private(set) var silenceCountdown: Int?

    init() {
        recorder.levelHandler = { [weak self] value in
            Task { @MainActor in self?.receivedLevel(value) }
        }
    }

    private func receivedLevel(_ value: Float) {
        guard recording else { return }
        level = value
        let shouldFinish = endpoint.update(level: value, at: ProcessInfo.processInfo.systemUptime)
        if silenceCountdown != endpoint.countdown { silenceCountdown = endpoint.countdown }
        if shouldFinish { finishRecording() }
    }

    func keepRecording() {
        guard recording else { return }
        endpoint.keepRecording()
        silenceCountdown = nil
        status = "Listening… Take your time, or tap Stop."
    }

    func record() {
        guard !busy else { return }
        if recording { finishRecording(); return }
        let id = UUID()
        request = id
        busy = true
        status = "Preparing microphone…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if SessionRecorder.microphonePermission == .undetermined {
                    guard await SessionRecorder.requestMicrophone() else { throw RecorderError.microphoneDenied }
                }
                guard !Task.isCancelled, self.request == id else { return }
                guard let root = AsideIPC.containerURL(),
                      let defaults = UserDefaults(suiteName: AsideIPC.appGroupID) else {
                    throw DirectError.badResponse("shared Aside settings; open the main app first")
                }
                let url = root.appendingPathComponent("dictionary.json")
                let entries = FileManager.default.fileExists(atPath: url.path)
                    ? try DictionaryCodec.decode(Data(contentsOf: url)) : []
                let settings = AppSettings(defaults: defaults)
                self.playSounds = settings.playSounds
                self.recordingID = UUID()
                self.sttMilliseconds = 0
                self.text = ""
                let plan = DictationPipeline.plan(settings: settings, entries: entries)
                self.pipelinePlan = plan
                if plan.mode == .local {
                    LocalTranscriber.shared.prepare()
                    while LocalTranscriber.shared.state == .loading {
                        self.status = LocalTranscriber.shared.statusLine
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    guard LocalTranscriber.shared.state == .ready else {
                        throw LocalTranscriberError.modelUnavailable(LocalTranscriber.shared.statusLine)
                    }
                }
                // Messages may still be handing audio back after opening its drawer.
                // Retry only activation failures; cancellation prevents a delayed start
                // after the user closes the panel or cancels preparation.
                for attempt in 0..<4 {
                    try Task.checkCancellation()
                    guard self.request == id else { return }
                    do {
                        try self.recorder.startSession()
                        break
                    } catch RecorderError.activationFailed where attempt < 3 {
                        self.status = "Waiting for the microphone…"
                        try await Task.sleep(for: .milliseconds(600))
                    }
                }
                // Verify actual captured audio, not just AVAudioEngine.isRunning.
                // A startup route rebuild may discard the first capture; retry
                // before telling the user that the microphone is listening.
                for _ in 0..<80 {
                    try Task.checkCancellation()
                    guard self.request == id else { return }
                    if self.recorder.isInputReady {
                        if !self.recorder.isDictating { try self.recorder.beginDictation() }
                        if self.recorder.capturedSeconds >= 0.1 { break }
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard self.recorder.isDictating, self.recorder.isInputReady,
                      self.recorder.capturedSeconds >= 0.1 else {
                    throw RecorderError.inputNotReady(AudioTrace.currentInput)
                }
                guard !Task.isCancelled, self.request == id else { return }
                if self.playSounds {
                    self.recorder.cancelDictation()
                    await self.sounds.playStart()
                    try Task.checkCancellation()
                    guard self.request == id else { return }
                    try self.recorder.beginDictation()
                }
                self.endpoint = SilenceEndpoint()
                self.silenceCountdown = nil
                self.recording = true
                self.busy = false
                self.status = "Listening… I’ll give you a countdown when you pause."
                self.recordingMonitor = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled, let self else { return }
                        guard self.recorder.isDictating else {
                            self.cancel()
                            self.status = "The microphone was interrupted. Tap Record to try again."
                            return
                        }
                    }
                }
            } catch {
                guard self.request == id else { return }
                self.cancel()
                self.status = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard recording, let plan = pipelinePlan else { return }
        silenceCountdown = nil
        recordingMonitor?.cancel()
        recordingMonitor = nil
        do {
            let audio = try recorder.endDictation()
            recorder.stopSession()
            if playSounds { sounds.playStop() }
            recording = false
            busy = true
            level = 0
            status = "Transcribing with Aside…"
            let id = UUID()
            request = id
            task = Task { [weak self] in
                do {
                    let started = Date()
                    let raw = try await DictationPipeline.transcribe(audio: audio, plan: plan)
                    guard let self, !Task.isCancelled, self.request == id else { return }
                    self.sttMilliseconds = Int(Date().timeIntervalSince(started) * 1000)
                    self.text = raw
                    self.busy = false
                    if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.status = "No speech detected. Try recording again."
                    } else {
                        self.cleanAndInsert()
                    }
                } catch {
                    guard let self, self.request == id else { return }
                    self.cancel()
                    self.status = error.localizedDescription
                }
            }
        } catch {
            cancel()
            status = error.localizedDescription
        }
    }

    func reset() {
        cancel()
        text = ""
        pipelinePlan = nil
        status = "Tap Record to speak with Aside."
    }

    func cancel() {
        recordingMonitor?.cancel()
        recordingMonitor = nil
        recorder.cancelDictation()
        recorder.stopSession()
        recording = false
        endpoint = SilenceEndpoint()
        silenceCountdown = nil
        level = 0
        request = nil
        task?.cancel()
        deadline?.cancel()
        task = nil
        deadline = nil
        busy = false
    }

    func cleanAndInsert() {
        guard !busy, let conversation = controller?.activeConversation else { return }
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        guard let plan = pipelinePlan else { return }
        controller?.view.endEditing(true)
        let id = UUID()
        request = id
        busy = true
        status = "Cleaning your reply…"
        task = Task { [weak self] in
            do {
                let result = try await DictationPipeline.clean(raw: raw, plan: plan.cleanup)
                let reply = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let self, !Task.isCancelled, self.request == id,
                      self.controller?.activeConversation === conversation else { return }
                guard !reply.isEmpty else {
                    self.cancel()
                    self.status = "Cleanup returned empty text. Your draft is still here."
                    return
                }
                let record = DictationRecord(id: self.recordingID, date: Date(), engine: plan.mode,
                    source: "messages", rawText: raw, finalText: reply,
                    sttMs: self.sttMilliseconds, cleanupMs: result.ms, cleanupLabel: result.label)
                self.text = reply
                self.status = "Adding to your message…"
                conversation.insertText(reply) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.request == id else { return }
                        self.cancel()
                        if let error {
                            self.status = "Could not insert: \(error.localizedDescription)"
                        } else {
                            do {
                                try MessagesHistory.store(record)
                            } catch {
                                Log.store.error("Could not save Messages history: \(error.localizedDescription, privacy: .public)")
                            }
                            self.text = ""
                            self.status = "Added to Messages. Tap Send when you’re ready."
                            self.controller?.dismiss()
                        }
                    }
                }
            } catch {
                guard let self, !Task.isCancelled, self.request == id else { return }
                self.cancel()
                self.status = "Could not clean up: \(error.localizedDescription)"
            }
        }
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.request == id else { return }
            self.cancel()
            self.status = "Cleanup timed out. Your draft is still here."
        }
    }
}

private struct AsideMessageComposer: View {
    @ObservedObject var model: MessageComposerModel

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 360
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 12 : 20) {
                    HStack(spacing: 8) {
                        GlyphView(size: 24, color: Theme.violet, live: false)
                        Text("Aside").font(Theme.display(28)).foregroundStyle(Theme.text)
                        Spacer()
                        if model.busy {
                            ProgressView()
                            Button("Cancel") { model.cancel() }
                        }
                    }

                    if compact {
                        HStack(spacing: 20) {
                            recordButton(size: 80)
                            status.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        status
                        Spacer(minLength: 0)
                        recordButton(size: 120).frame(maxWidth: .infinity)
                    }

                    if !model.text.isEmpty {
                        Text(model.text)
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if !model.busy && !model.recording {
                            Button("Retry cleanup & insert") { model.cleanAndInsert() }
                        }
                    }

                    Spacer(minLength: 0)
                    Text("Adds text to your message. You choose when to send.")
                        .font(.caption).foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .topLeading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.violet)
    }

    @ViewBuilder
    private var status: some View {
        if let seconds = model.silenceCountdown, model.recording {
            Button { model.keepRecording() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quiet here… stopping in \(seconds)…")
                        .font(.callout).foregroundStyle(Theme.text)
                        .monospacedDigit()
                    Text("Tap to keep recording")
                        .font(.caption).foregroundStyle(Theme.violet)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stopping in \(seconds) seconds. Keep recording")
        } else {
            Text(model.status)
                .font(.callout).foregroundStyle(Theme.text2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func recordButton(size: CGFloat) -> some View {
        Button { model.record() } label: {
            VStack(spacing: 8) {
                ZStack {
                    MeterRing(size: size, live: model.recording, level: model.level)
                    Circle()
                        .fill(model.recording ? AnyShapeStyle(Theme.liveDisc) : AnyShapeStyle(Theme.violetDisc))
                        .frame(width: size * 0.77, height: size * 0.77)
                    Image(systemName: model.recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: size * 0.28, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
                Text(model.recording ? "Stop" : "Record")
                    .font(.headline).foregroundStyle(Theme.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
        .accessibilityLabel(model.recording ? "Stop recording and insert transcript" : "Record with Aside")
    }
}
