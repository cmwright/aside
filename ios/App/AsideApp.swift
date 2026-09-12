import SwiftUI
import UIKit

@main
struct AsideApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = SessionController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(controller)
                .environmentObject(controller.settings)
                .environmentObject(controller.dictionary)
                .environmentObject(controller.phone)
                .environmentObject(controller.history)
                // The keyboard opens aside://session/start; the control aside://control/start.
                .onOpenURL { controller.handle(url: $0) }
                // `onChange(of: scenePhase)` does not fire for the initial value, so a cold
                // launch also has to look for a session or commands left by an extension.
                .task { controller.refresh() }
                .tint(Theme.violet)
        }
        .onChange(of: scenePhase) { _, phase in
            // A session can expire while the app is suspended; catch up on the way back in.
            if phase == .active { controller.refresh() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        APIKeyStore.migrateLegacyKeys()
        #if DEBUG
        // Simulator/test convenience: `xcrun simctl launch` can pass
        // SIMCTL_CHILD_ASIDE_SEED_KEY_<provider>=<key> to put an API key in the keychain
        // without typing it on screen. Debug builds only.
        for (name, value) in ProcessInfo.processInfo.environment where name.hasPrefix("ASIDE_SEED_KEY_") {
            APIKeyStore.set(value, for: String(name.dropFirst("ASIDE_SEED_KEY_".count)).lowercased())
        }
        // SIMCTL_CHILD_ASIDE_TAB=settings|recent|dictionary opens on that tab, for screenshots.
        let tabs: [String: SessionController.Tab] = ["home": .home, "dictionary": .dictionary, "settings": .settings, "recent": .recent]
        if let tab = ProcessInfo.processInfo.environment["ASIDE_TAB"].flatMap({ tabs[$0] }) {
            MainActor.assumeIsolated { SessionController.shared.selectedTab = tab }
        }
        // SIMCTL_CHILD_ASIDE_DEBUG_TALK=1 taps the Home talk button twice, three seconds
        // apart, once the engines are ready: the no-session dictation path, on a simulator.
        if ProcessInfo.processInfo.environment["ASIDE_DEBUG_TALK"] == "1" {
            Task { @MainActor in
                let controller = SessionController.shared
                while controller.configurationProblem() != nil { try? await Task.sleep(for: .seconds(1)) }
                try? await Task.sleep(for: .seconds(1))
                // Event-stamped like a real touch: a 60 ms tap, whatever the handlers cost.
                var t = Date().timeIntervalSinceReferenceDate
                Log.app.notice("debug talk: tap 1")
                controller.pushToTalkDown(at: t); controller.pushToTalkUp(at: t + 0.06)
                try? await Task.sleep(for: .seconds(3))
                Log.app.notice("debug talk: tap 2, phase \(String(describing: controller.phase), privacy: .public)")
                t = Date().timeIntervalSinceReferenceDate
                controller.pushToTalkDown(at: t); controller.pushToTalkUp(at: t + 0.06)
            }
        }
        #endif
        MainActor.assumeIsolated {
            SessionController.shared.prepareEngines()
            Log.app.info("Aside for iPhone launched")
        }
        return true
    }
}

struct RootView: View {
    @EnvironmentObject private var controller: SessionController

    var body: some View {
        TabView(selection: $controller.selectedTab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "mic") }
                .tag(SessionController.Tab.home)
            PhoneDictionaryView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
                .tag(SessionController.Tab.dictionary)
            PhoneSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(SessionController.Tab.settings)
            RecentView()
                .tabItem { Label("Recent", systemImage: "clock") }
                .tag(SessionController.Tab.recent)
        }
    }
}
