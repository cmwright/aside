import AppKit
import SwiftUI

/// A small floating pill near the bottom of the screen. It is a non-activating panel and
/// can never become key, so the app the user is typing into keeps focus.
@MainActor
final class StatusOverlay {
    static let shared = StatusOverlay()

    private var panel: NSPanel?
    private let model = OverlayModel()
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ text: String, tone: OverlayTone) {
        hideWorkItem?.cancel()
        model.text = text
        model.tone = tone
        panel(makeIfNeeded: true)?.orderFrontRegardless()
        reposition()
    }

    /// Shows the text and fades it away after `after` seconds.
    func flash(_ text: String, tone: OverlayTone, after seconds: TimeInterval = 2.5) {
        show(text, tone: tone)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel?.orderOut(nil)
    }

    private func panel(makeIfNeeded: Bool) -> NSPanel? {
        if let panel { return panel }
        guard makeIfNeeded else { return nil }

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
        self.panel = panel
        return panel
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 44)
        let width = max(size.width, 160)
        let height = max(size.height, 40)
        panel.setContentSize(NSSize(width: width, height: height))
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - width / 2,
            y: frame.minY + 96
        )
        panel.setFrameOrigin(origin)
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OverlayTone {
    case listening
    case working
    case failure

    var color: Color {
        switch self {
        case .listening: return .red
        case .working: return .accentColor
        case .failure: return .orange
        }
    }

    var symbol: String {
        switch self {
        case .listening: return "mic.fill"
        case .working: return "waveform"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var text: String = ""
    @Published var tone: OverlayTone = .listening
}

private struct OverlayView: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.tone.symbol)
                .foregroundStyle(model.tone.color)
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 160, maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
    }
}
