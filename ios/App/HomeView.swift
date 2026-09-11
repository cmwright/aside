import SwiftUI

/// The instrument panel: word mark and session state up top, the mic control inside its
/// meter ring, the level strip, and the last result. The talk button works on its own, with
/// or without a session, so the pipeline can be exercised without ever enabling the keyboard.
struct HomeView: View {
    @EnvironmentObject private var controller: SessionController
    @EnvironmentObject private var phone: PhoneSettings
    @EnvironmentObject private var settings: AppSettings
    // Observed so the gate re-evaluates as the model downloads or Apple Intelligence changes.
    @ObservedObject private var transcriber = LocalTranscriber.shared
    @ObservedObject private var appleCleanup = AppleCleanup.shared
    @Environment(\.openURL) private var openURL
    @State private var holding = false
    @State private var copied = false
    @State private var listeningSince: Date?

    private var problem: SessionController.ConfigurationProblem? { controller.configurationProblem() }
    private var listening: Bool { controller.phase == .listening }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    VStack(spacing: 12) {
                        if let banner = controller.banner { bannerView(banner) }
                        if !controller.appGroupAvailable {
                            warning("The app group is not available in this build, so the keyboard cannot reach the app. Run the app from Xcode with your own team so it gets the App Group entitlement.")
                        }
                        if let problem { configurationCard(problem) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    hero
                    levels
                    if !controller.lastText.isEmpty { lastResultCard.padding(.horizontal, 20).padding(.top, 22) }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onChange(of: controller.phase) { _, phase in
            listeningSince = phase == .listening ? Date() : nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Wordmark(height: 18)
            Spacer()
            Button {
                controller.banner = nil
                if controller.isSessionActive { controller.endSession() } else { controller.startSession() }
            } label: {
                if controller.isSessionActive {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Pill(text: "Session · \(remaining(at: context.date))", dot: Theme.violet)
                    }
                } else {
                    Pill(text: "Start session", dot: Theme.text3, textColor: Theme.text)
                }
            }
            .buttonStyle(.plain)
            .disabled(problem != nil && !controller.isSessionActive)
            .accessibilityLabel(controller.isSessionActive ? "End session" : "Start session")
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func remaining(at now: Date) -> String {
        guard let expiresAt = controller.session?.expiresAt else { return "until ended" }
        let seconds = max(0, Int(expiresAt.timeIntervalSince(now)))
        return String(format: "%d:%02d left", seconds / 60, seconds % 60)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: 14) {
            Button {
                // Everything happens in the gesture below; the button is the hit target.
            } label: {
                ZStack {
                    MeterRing(size: 208, live: listening, level: controller.levels.last ?? 0)
                    Circle()
                        .fill(listening ? AnyShapeStyle(Theme.liveDisc)
                              : problem == nil ? AnyShapeStyle(Theme.violetDisc) : AnyShapeStyle(Theme.surface2))
                        .frame(width: 164, height: 164)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.5), radius: 22, y: 18)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(problem == nil || listening ? Color.white : Theme.text3)
                }
            }
            .buttonStyle(.plain)
            .disabled(problem != nil)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding, problem == nil else { return }
                        holding = true
                        copied = false
                        controller.pushToTalkDown()
                    }
                    .onEnded { _ in
                        guard holding else { return }
                        holding = false
                        controller.pushToTalkUp()
                    }
            )
            .accessibilityLabel(settings.tapBehavior == .latch ? "Tap to talk" : "Hold to talk")

            VStack(spacing: 6) {
                MonoLabel(statusText, color: statusColor, size: 12)
                if listening {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(elapsed(at: context.date))
                            .font(Theme.mono(28, medium: true))
                            .tracking(1)
                            .foregroundStyle(Theme.text)
                    }
                } else {
                    Text(settings.tapBehavior == .latch ? "Tap to talk" : "Hold to talk")
                        .font(Theme.display(30))
                        .foregroundStyle(Theme.text)
                }
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32)
        }
        .padding(.top, 30)
    }

    private var statusText: String {
        switch controller.phase {
        case .idle: return problem == nil ? "Ready" : "Not ready"
        case .listening: return "Listening"
        case .processing: return "Transcribing"
        case .failed(let message): return message
        }
    }

    private var statusColor: Color {
        switch controller.phase {
        case .idle: return Theme.text2
        case .listening: return Theme.live
        case .processing: return Theme.amber
        case .failed: return Theme.live
        }
    }

    private var hint: String {
        if listening {
            return settings.tapBehavior == .latch ? "Tap again to stop and send" : "Let go to stop and send"
        }
        switch settings.tapBehavior {
        case .latch: return "Keeps listening until you tap again. Holding works too."
        case .doubleTapLatches: return "Hold, speak, let go. Double-tap to keep listening."
        case .send: return "Hold, speak, let go."
        }
    }

    private func elapsed(at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(listeningSince ?? now)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Levels

    private var levels: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                MonoLabel("Input")
                Spacer()
                MonoLabel(AudioTrace.currentInput, color: Theme.text2)
            }
            LevelStrip(values: controller.levels, color: listening ? Theme.live : Theme.line2)
            Text(sessionNote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
    }

    private var sessionNote: String {
        controller.isSessionActive
            ? "The microphone stays live for the Aside keyboard and the Control Center control. \(phone.sessionLength.title) per session; change it in Settings."
            : "Start a session to dictate from the Aside keyboard in any app, or from Control Center."
    }

    // MARK: - Last result

    private var lastResultCard: some View {
        Card {
            HStack {
                MonoLabel("Last result", color: Theme.text2)
                Spacer()
                Button {
                    UIPasteboard.general.string = controller.lastText
                    copied = true
                } label: {
                    Pill(text: copied ? "Copied" : "Copy", systemImage: "doc.on.doc", textColor: Theme.text)
                }
                .buttonStyle(.plain)
            }
            Text(controller.lastText)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let summary = controller.lastSummary {
                MonoLabel(summary)
            }
        }
    }

    // MARK: - Configuration

    /// Shown instead of letting a recording start that cannot finish. The download bar is
    /// FluidAudio's byte count for the file it is fetching, not an animation.
    private func configurationCard(_ problem: SessionController.ConfigurationProblem) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
                VStack(alignment: .leading, spacing: 8) {
                    MonoLabel("Not ready to dictate", color: Theme.amber, size: 12)
                    if problem.fix != .wait {
                        Text(problem.message)
                            .font(.footnote)
                            .foregroundStyle(Theme.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch problem.fix {
                    case .systemSettings:
                        Button("Open iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                        .buttonStyle(.bordered)
                    case .loadModel:
                        Button(problem == .modelNotLoaded ? "Download Parakeet v3" : "Try Again") {
                            transcriber.prepare()
                        }
                        .buttonStyle(.bordered)
                    case .appSettings:
                        Button("Open Settings") { controller.selectedTab = .settings }
                            .buttonStyle(.bordered)
                    case .wait:
                        ModelLoadingView(progress: transcriber.progress)
                    }
                }
            }
        }
    }

    // MARK: - Bits

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Theme.violet)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.text3)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.text)
        .padding()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.amber)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(Theme.text)
        .padding()
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line))
    }
}

/// The live model-loading line: a determinate bar while bytes are arriving (FluidAudio's
/// own count for the current file), a spinner for the steps that have no finer progress.
struct ModelLoadingView: View {
    let progress: LocalTranscriber.LoadProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !isDownloading { ProgressView().controlSize(.small) }
                Text(progress?.label ?? "Loading Parakeet v3…")
                    .font(.footnote)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isDownloading, let progress {
                ProgressView(value: progress.downloadFraction)
                    .progressViewStyle(.linear)
                    .tint(Theme.violet)
            }
        }
    }

    private var isDownloading: Bool { progress?.stage == .downloading }
}
