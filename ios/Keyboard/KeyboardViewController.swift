import SwiftUI
import UIKit

/// The Aside keyboard. It cannot record — no iOS keyboard extension can, with or without
/// Full Access — so it writes a command file into the App Group, the app records and
/// transcribes, and the keyboard pastes the answer at the cursor.
///
/// Deliberately thin: no FluidAudio, no FoundationModels, no networking. A keyboard
/// extension is killed somewhere above 50 MB.
final class KeyboardViewController: UIInputViewController {
    private let model = KeyboardModel()
    private var host: UIHostingController<KeyboardRootView>?
    private var heightConstraint: NSLayoutConstraint?

    /// Enough for a status line, a big mic button and the bottom row.
    private static let keyboardHeight: CGFloat = 220

    override func viewDidLoad() {
        super.viewDidLoad()
        model.controller = self

        let host = UIHostingController(rootView: KeyboardRootView(model: model))
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        self.host = host

        // Not .required: the system briefly lays the input view out at other heights and a
        // required constraint would log a conflict every time.
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardViewController.keyboardHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true
        heightConstraint = height
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.showsGlobe = needsInputModeSwitchKey
        model.start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.stop()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.showsGlobe = needsInputModeSwitchKey
    }

    // MARK: - Things only the controller can do

    func advanceToNextKeyboard() {
        advanceToNextInputMode()
    }

    /// Opens the container app. `UIApplication.shared` is marked unavailable in extensions,
    /// but the extension process still has one, and its
    /// `openURL:options:completionHandler:` is what opens the app on iOS 18 and later
    /// (the old `openURL:` selector walked up the responder chain stopped working there;
    /// `NSExtensionContext.open` reports false for keyboards; a scene's own `openURL`
    /// swallows it). Verified end to end by `AsideUITests`. If no such object turns up,
    /// the responder chain is tried as a fallback.
    @discardableResult
    func openContainerApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
        let completion: @convention(block) (Bool) -> Void = { ok in
            KeyboardTrace.write("open \(url.absoluteString) -> \(ok)")
        }

        var target: NSObject?
        if let appClass = NSClassFromString("UIApplication") as? NSObject.Type,
           let shared = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
           shared.responds(to: selector) {
            target = shared
        } else {
            var responder: UIResponder? = next
            while let current = responder {
                if current.responds(to: selector) { target = current; break }
                responder = current.next
            }
        }
        guard let target else {
            KeyboardTrace.write("nothing in this process answers openURL:options:completionHandler:")
            return false
        }
        KeyboardTrace.write("opening \(url.absoluteString) through \(type(of: target))")
        let open = unsafeBitCast(target.method(for: selector), to: OpenURL.self)
        open(target, selector, url as NSURL, [:] as NSDictionary, unsafeBitCast(completion, to: AnyObject.self))
        return true
    }
}

/// A few lines in the App Group describing the last attempts to open the app, so a tap
/// that does nothing can be diagnosed from the app side (the keyboard's own log is hard
/// to reach). Capped at twenty lines.
enum KeyboardTrace {
    static func write(_ line: String) {
        guard let root = AsideIPC.containerURL() else { return }
        let url = root.appendingPathComponent("keyboard-trace.txt")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = (existing.split(separator: "\n").suffix(19) + ["\(stamp) \(line)"]).joined(separator: "\n")
        try? lines.write(to: url, atomically: true, encoding: .utf8)
    }
}
