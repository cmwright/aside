import AppKit
import SwiftUI

/// The sections of the one settings window, in sidebar order.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, engines, providers, dictionary, history, permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .engines: return "Engines"
        case .providers: return "Providers"
        case .dictionary: return "Dictionary"
        case .history: return "Recent Dictations"
        case .permissions: return "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .engines: return "waveform"
        case .providers: return "key"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        }
    }
}

/// Which section is showing. Shared so the menu bar and the app delegate can jump to one.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var section: SettingsSection = .general
}

/// One AppKit window for everything that used to be four SwiftUI `Window` scenes. AppKit
/// rather than a scene so `AppDelegate` can open it at launch, where SwiftUI's
/// `openWindow` is out of reach, and so LSUIElement activation is in one place.
@MainActor
final class MainWindow {
    static let shared = MainWindow()

    let navigation = SettingsNavigation()
    private var window: NSWindow?

    private init() {}

    func show(_ section: SettingsSection) {
        navigation.section = section
        let window = self.window ?? makeWindow()
        self.window = window
        // No Dock icon, so the window needs an explicit activation to come to the front.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A remembered frame from an earlier oversized launch would otherwise come back.
    private func clampToScreen(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = window.frame
        guard frame.height > visible.height || frame.width > visible.width
                || frame.minY < visible.minY || frame.maxY > visible.maxY else { return }
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        window.setFrame(frame, display: false)
    }

    private func makeWindow() -> NSWindow {
        let root = MainView()
            .environmentObject(navigation)
            .environmentObject(AppSettings.shared)
            .environmentObject(DictionaryStore.shared)
            .environmentObject(Permissions.shared)
        // A hosting view with sizing options off never pushes its own size on the window.
        // With the defaults the SwiftUI content's ideal size (unbounded for a Table or a
        // List) became auto-layout constraints, which first grew the window past the
        // screen and, once the frame was clamped, left the content taller than the window
        // with its top clipped off.
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Aside"
        window.contentView = hosting
        window.minSize = NSSize(width: 700, height: 440)
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("AsideMain") { window.center() }
        window.setFrameAutosaveName("AsideMain")
        clampToScreen(window)
        return window
    }
}

struct MainView: View {
    @EnvironmentObject private var navigation: SettingsNavigation
    @EnvironmentObject private var permissions: Permissions

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.section) { section in
                Label {
                    HStack {
                        Text(section.title)
                        if section == .permissions && !permissions.allGranted {
                            Spacer()
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } icon: {
                    Image(systemName: section.symbol)
                }
                .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detail
                // The split view sizes its columns from the content's ideal size, and a
                // Table (Dictionary) reports an unbounded one. Without an explicit ideal
                // height the column grew past the window and its top was clipped off.
                .frame(minWidth: 480, idealWidth: 600, maxWidth: .infinity,
                       minHeight: 380, idealHeight: 480, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(navigation.section.title)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.section {
        case .general: GeneralSettingsView()
        case .engines: EnginesSettingsView()
        case .providers: ProvidersSettingsView()
        case .dictionary: DictionaryView()
        case .history: HistoryView()
        case .permissions: PermissionsView()
        }
    }
}
