import SwiftUI

/// The whole keyboard: a status line, one big mic button, and the four keys a dictation
/// keyboard still needs. Nothing else — this keyboard is for talking, not typing.
struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    @State private var holding = false

    var body: some View {
        VStack(spacing: 8) {
            statusLine
            Spacer(minLength: 0)
            if model.state == .noFullAccess {
                fullAccessHelp
            } else {
                micButton
            }
            Spacer(minLength: 0)
            bottomRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 6) {
            Text("Aside")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            if model.state.isTappableForSession {
                // A SwiftUI Link is the one thing a keyboard extension can still use to
                // open its app: iOS 18 shut the old responder-chain `openURL:` route.
                Link(destination: KeyboardModel.startSessionURL) {
                    Label("Start a session", systemImage: "arrow.up.forward.app")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            } else {
                Text(model.state.text)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch model.state {
        case .error, .noFullAccess: return .red
        case .listening: return .red
        case .transcribing: return .orange
        default: return .secondary
        }
    }

    // MARK: - Mic

    private var micButton: some View {
        VStack(spacing: 4) {
            if model.state.isTappableForSession {
                // No session yet: the mic itself opens the app to start one.
                Link(destination: KeyboardModel.startSessionURL) { micFace }
                    .accessibilityLabel("Open Aside to start a session")
            } else {
                micFace
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !holding else { return }
                                holding = true
                                model.micDown()
                            }
                            .onEnded { _ in
                                guard holding else { return }
                                holding = false
                                model.micUp()
                            }
                    )
                    .accessibilityLabel("Hold to dictate")
            }

            Text(micCaption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var micCaption: String {
        if model.state.isTappableForSession { return "Tap to open Aside and start a session" }
        return model.isLatched ? "Tap to stop" : "Hold to talk · double-tap to keep going"
    }

    private var micFace: some View {
        ZStack {
            Circle()
                .fill(micColor)
                .frame(width: 92, height: 92)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(model.isLatched ? 0.9 : 0), lineWidth: 3)
                )
            Image(systemName: model.state == .listening ? "waveform" : "mic.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
        }
        .contentShape(Circle())
    }

    private var micColor: Color {
        switch model.state {
        case .listening: return .red
        case .transcribing: return .orange
        case .noSession: return .gray
        default: return .accentColor
        }
    }

    private var fullAccessHelp: some View {
        Text("Turn on Allow Full Access in Settings > General > Keyboard > Keyboards > Aside. Aside needs it to reach the app that does the recording.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }

    // MARK: - Bottom row

    private var bottomRow: some View {
        HStack(spacing: 6) {
            if model.showsGlobe {
                KeyButton(systemImage: "globe", width: 44) { model.nextKeyboard() }
            }
            KeyButton(title: "space") { model.insertSpace() }
            KeyButton(systemImage: "delete.left", width: 56, repeats: true) { model.deleteBackward() }
            KeyButton(systemImage: "return", width: 56) { model.insertReturn() }
        }
        .frame(height: 42)
    }
}

/// One key. `repeats` gives the press-and-hold repeat that backspace needs.
private struct KeyButton: View {
    var title: String?
    var systemImage: String?
    var width: CGFloat?
    var repeats = false
    var action: () -> Void

    @State private var pressed = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.secondarySystemBackground).opacity(pressed ? 0.5 : 1))
                .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
            if let title {
                Text(title).font(.system(size: 16))
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 17))
            }
        }
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !pressed else { return }
                    pressed = true
                    action()
                    if repeats { startRepeating() }
                }
                .onEnded { _ in
                    pressed = false
                    repeatTask?.cancel()
                    repeatTask = nil
                }
        )
        .accessibilityLabel(title ?? systemImage ?? "key")
    }

    private func startRepeating() {
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.45))
            while !Task.isCancelled {
                action()
                try? await Task.sleep(for: .seconds(0.08))
            }
        }
    }
}
