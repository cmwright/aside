import SwiftUI

/// Session status, the session button, and a hold-to-talk button that works on its own so
/// the pipeline can be exercised without ever enabling the keyboard.
struct HomeView: View {
    @EnvironmentObject private var controller: SessionController
    @EnvironmentObject private var phone: PhoneSettings
    @State private var holding = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let banner = controller.banner {
                        bannerView(banner)
                    }
                    if !controller.appGroupAvailable {
                        warning("The app group is not available in this build, so the keyboard cannot reach the app. Run the app from Xcode with your own team so it gets the App Group entitlement.")
                    }
                    sessionCard
                    talkCard
                    if !controller.lastText.isEmpty { lastResultCard }
                }
                .padding()
            }
            .navigationTitle("Aside")
        }
    }

    // MARK: - Session

    private var sessionCard: some View {
        Card {
            HStack {
                Circle()
                    .fill(controller.isSessionActive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 10, height: 10)
                Text(controller.sessionStatus)
                    .font(.headline)
                Spacer()
            }
            Text(controller.isSessionActive
                 ? "The microphone is live. Switch to the Aside keyboard in any app and hold its mic button."
                 : "Start a session, then switch to the Aside keyboard in whatever app you are typing in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                controller.banner = nil
                if controller.isSessionActive { controller.endSession() } else { controller.startSession() }
            } label: {
                Text(controller.isSessionActive ? "End Session" : "Start Session")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(controller.isSessionActive ? .red : .accentColor)

            Text("Session length: \(phone.sessionLength.title) — change it in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hold to talk

    private var talkCard: some View {
        Card {
            Text("Hold to talk")
                .font(.headline)
            Text("Works right here, with or without a session.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button {
                // Everything happens in the gesture below; the button is the hit target.
            } label: {
                ZStack {
                    Circle()
                        .fill(holding ? Color.red : Color.accentColor)
                        .frame(width: 110, height: 110)
                    Image(systemName: holding ? "waveform" : "mic.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !holding else { return }
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
            .accessibilityLabel("Hold to talk")

            Text(controller.phase.label)
                .font(.subheadline)
                .foregroundStyle(phaseColor)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private var phaseColor: Color {
        switch controller.phase {
        case .failed: return .red
        case .listening: return .red
        case .processing: return .orange
        case .idle: return .secondary
        }
    }

    // MARK: - Last result

    private var lastResultCard: some View {
        Card {
            HStack {
                Text("Last result").font(.headline)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = controller.lastText
                    copied = true
                }
                .font(.subheadline)
            }
            Text(controller.lastText)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let summary = controller.lastSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bits

    private func bannerView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.uturn.backward.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.banner = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .padding()
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A plain rounded panel, so the four screens look like one app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
