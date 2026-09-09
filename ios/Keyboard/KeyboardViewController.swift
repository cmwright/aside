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

    /// An app extension has no `UIApplication`, so the URL is handed up the responder chain
    /// to the one that is really there. `openURL:` is the old selector, still the only way
    /// a keyboard can open its container app.
    func openContainerApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector), current !== self {
                _ = current.perform(selector, with: url)
                return
            }
            responder = current.next
        }
    }
}
