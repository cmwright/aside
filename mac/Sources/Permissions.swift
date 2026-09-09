import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// Live status of the two permissions this app needs. macOS gives no notification when a
/// grant changes, so this polls once a second whenever something is still missing (or a
/// window is watching) and stops as soon as everything is granted.
@MainActor
final class Permissions: ObservableObject {
    static let shared = Permissions()

    enum State: Equatable, Sendable {
        case granted
        case denied
        case notDetermined

        var symbol: String {
            switch self {
            case .granted: return "checkmark.circle.fill"
            case .denied: return "xmark.octagon.fill"
            case .notDetermined: return "questionmark.circle.fill"
            }
        }

        var label: String {
            switch self {
            case .granted: return "Granted"
            case .denied: return "Not granted"
            case .notDetermined: return "Not asked yet"
            }
        }
    }

    @Published private(set) var microphone: State = .notDetermined
    @Published private(set) var accessibility: State = .denied

    private var timer: Timer?
    private var watchers = 0
    private var window: NSWindow?

    private init() {
        refresh()
    }

    var allGranted: Bool { microphone == .granted && accessibility == .granted }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        accessibility = AXIsProcessTrusted() ? .granted : .denied
        updateTimer()
    }

    /// Poll while anything is still outstanding — the trigger cannot work until
    /// Accessibility lands, and nothing tells us when the user grants it — or while a
    /// window is watching. Stop once there is nothing left to wait for.
    private var needsPolling: Bool {
        watchers > 0 || accessibility != .granted || microphone == .notDetermined
    }

    private func updateTimer() {
        if needsPolling { startTimer() } else { stopTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Reference-counted so several windows can watch without stomping on each other.
    func beginWatching() {
        watchers += 1
        refresh()
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        updateTimer()
    }

    // MARK: - Window

    /// The Permissions checklist lives in an AppKit window instead of a SwiftUI `Window`
    /// scene so that `AppDelegate` can open it on first launch, where SwiftUI's
    /// `openWindow` environment value is not reachable.
    func showWindow() {
        let window = self.window ?? makeWindow()
        self.window = window
        let wasVisible = window.isVisible
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // One watcher per *open*, balanced by `windowWillClose`.
        if !wasVisible { beginWatching() }
    }

    private func makeWindow() -> NSWindow {
        let controller = NSHostingController(rootView: PermissionsView().environmentObject(self))
        let window = NSWindow(contentViewController: controller)
        window.title = "Permissions"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 400))
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = windowDelegate
        return window
    }

    /// Balances the `beginWatching()` in `showWindow()` when the window is closed, so the
    /// poll can stop once everything is granted.
    private lazy var windowDelegate = WindowDelegate(owner: self)

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private weak var owner: Permissions?
        init(owner: Permissions) { self.owner = owner }
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { owner?.endWatching() }
        }
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor in Permissions.shared.refresh() }
        }
    }

    /// Shows the system "open System Settings" prompt for Accessibility. Accessibility has
    /// no Info.plist usage string; this is the only way to ask.
    func requestAccessibility() {
        // The literal avoids touching `kAXTrustedCheckOptionPrompt`, a mutable global that
        // Swift 6 will not let us read from a concurrency-checked context.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    /// One sentence, shown wherever the Accessibility row appears.
    static let adHocSigningNote = """
    This build is ad-hoc signed, so macOS ties the Accessibility grant to the exact binary: \
    after every rebuild you may have to remove VoiceToText from System Settings > Privacy & \
    Security > Accessibility with the "-" button and add it again.
    """
}
