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
            if model.state == .noFullAccess || model.state == .noAppGroup {
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
        .background(Theme.bg)
    }

    // MARK: - Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            GlyphView(size: 16, color: model.state == .listening ? Theme.live : Theme.text2, live: model.state == .listening)
            if model.state.isTappableForSession {
                // Not a Button or Link: like the keys below, a plain gesture is what
                // reliably gets touches inside a keyboard extension.
                Label("Start a session", systemImage: "arrow.up.forward.app")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.violet)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in
                        model.openApp(KeyboardModel.startSessionURL)
                    })
                    .accessibilityAddTraits(.isButton)
            } else {
                MonoLabel(model.state.text, color: statusColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch model.state {
        case .error, .noFullAccess, .noAppGroup: return Theme.live
        case .listening: return Theme.live
        case .transcribing: return Theme.amber
        default: return Theme.text2
        }
    }

    // MARK: - Mic

    private var micButton: some View {
        VStack(spacing: 4) {
            if model.state.isTappableForSession {
                // No session yet: the mic itself opens the app to start one.
                micFace
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in
                        model.openApp(KeyboardModel.startSessionURL)
                    })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Open Aside to start a session")
            } else {
                micFace
                    .scaleEffect(holding ? 0.94 : 1)
                    .animation(.spring(duration: 0.25, bounce: 0.35), value: holding)
                    .animation(.easeInOut(duration: 0.3), value: model.state)
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
                    .accessibilityLabel(model.tapBehavior == .latch ? "Tap to dictate" : "Hold to dictate")
            }

            Text(micCaption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text2)
        }
    }

    private var micCaption: String {
        if model.state.isTappableForSession { return "Tap to open Aside and start a session" }
        if model.isLatched { return "Tap to stop" }
        switch model.tapBehavior {
        case .latch: return "Tap to talk · tap again to stop"
        case .doubleTapLatches: return "Hold to talk · double-tap to keep going"
        case .send: return "Hold to talk"
        }
    }

    private var micFace: some View {
        ZStack {
            MeterRing(size: 92, live: model.state == .listening, level: model.state == .listening ? 0.6 : 0)
            if model.state == .listening {
                Circle().stroke(Theme.live, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .phaseAnimator([0.0, 1.0]) { view, phase in
                        view.scaleEffect(1 + phase * 0.25).opacity(0.7 * (1 - phase))
                    } animation: { _ in .easeOut(duration: 1.4) }
                    .transition(.opacity)
            }
            ZStack {
                Circle().fill(Theme.surface2).opacity(model.state == .noSession ? 1 : 0)
                Circle().fill(Theme.violetDisc).opacity(model.state == .ready ? 1 : 0)
                Circle().fill(Theme.amber).opacity(model.state == .transcribing ? 1 : 0)
                Circle().fill(Theme.liveDisc).opacity(model.state == .listening ? 1 : 0)
            }
            .frame(width: 72, height: 72)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Theme.shadow, radius: 10, y: 8)
            Image(systemName: model.state == .listening ? "waveform" : model.state == .transcribing ? "ellipsis" : "mic.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(model.state == .noSession ? Theme.text3 : .white)
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.variableColor.iterative.reversing, isActive: model.state == .listening)
                .symbolEffect(.variableColor.iterative, isActive: model.state == .transcribing)
        }
        .frame(width: 92, height: 92)
        .contentShape(Circle())
    }

    // The disc is four crossfading circles above; error states fall back to the ready disc.

    private var fullAccessHelp: some View {
        Text(model.state == .noAppGroup
             ? "This copy of the keyboard has no App Group entitlement, so it cannot reach the Aside app. Reinstall a signed build."
             : "Turn on Allow Full Access in Settings > General > Keyboard > Keyboards > Aside. Aside needs it to reach the app that does the recording.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .foregroundStyle(Theme.text2)
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
            RoundedRectangle(cornerRadius: 8)
                .fill(pressed ? Theme.line2 : Theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                .shadow(color: Theme.shadow, radius: 0, y: 1)
            if let title {
                Text(title).font(.system(size: 16)).foregroundStyle(Theme.text)
            } else if let systemImage {
                Image(systemName: systemImage).font(.system(size: 17)).foregroundStyle(Theme.text)
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
