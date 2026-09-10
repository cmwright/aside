import XCTest

/// Drives the simulator end to end: turns on Full Access for the Aside keyboard in
/// Settings if needed, focuses a text field in Safari, brings up the Aside keyboard, taps
/// "Start a session", and checks that the Aside app comes to the foreground with a session.
/// Needs the Aside keyboard already added under Settings > General > Keyboard > Keyboards.
@MainActor
final class KeyboardOpensAppUITests: XCTestCase {
    private let asideID = "com.codywright.aside.ios"

    func testStartSessionLinkOpensApp() throws {
        let aside = XCUIApplication(bundleIdentifier: asideID)
        aside.terminate()

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        try focusTextField(in: safari)
        try showAsideKeyboard(in: safari)

        if element(in: safari, labelled: "Turn on Allow Full Access").waitForExistence(timeout: 2) {
            try allowFullAccess()
            safari.activate()
            try focusTextField(in: safari)
            try showAsideKeyboard(in: safari)
        }

        let link = element(in: safari, labelled: "Start a session")
        XCTAssertTrue(link.waitForExistence(timeout: 5), "no Start a session link\n\(safari.debugDescription)")
        link.tap()

        XCTAssertTrue(aside.wait(for: .runningForeground, timeout: 10), "Aside did not come to the foreground")
        // The app either starts the session or explains why it could not (model still
        // downloading on a fresh install); both prove the URL reached it.
        let handled = aside.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'End session' OR label BEGINSWITH 'Could not start a session'")).firstMatch
        XCTAssertTrue(handled.waitForExistence(timeout: 10), "Aside opened but did not handle the URL\n\(aside.debugDescription)")
    }

    // MARK: - Steps

    private func element(in app: XCUIApplication, labelled label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func focusTextField(in safari: XCUIApplication) throws {
        // Any page with a text area does; the address bar is a fallback.
        if safari.textViews.firstMatch.waitForExistence(timeout: 2) {
            safari.textViews.firstMatch.tap()
        } else {
            let address = element(in: safari, labelled: "Address")
            XCTAssertTrue(address.waitForExistence(timeout: 5), "nothing to type into in Safari\n\(safari.debugDescription)")
            address.tap()
            if !element(in: safari, labelled: "Next keyboard").waitForExistence(timeout: 3) {
                safari.textFields.firstMatch.tap()
            }
        }
        XCTAssertTrue(element(in: safari, labelled: "Next keyboard").waitForExistence(timeout: 5),
                      "no keyboard came up\n\(safari.debugDescription)")
    }

    private func showAsideKeyboard(in safari: XCUIApplication) throws {
        if element(in: safari, labelled: "Aside").waitForExistence(timeout: 1) { return }
        let globe = element(in: safari, labelled: "Next keyboard")
        globe.press(forDuration: 1.2)
        let pick = safari.staticTexts["Aside"].firstMatch
        XCTAssertTrue(pick.waitForExistence(timeout: 3), "Aside not in the keyboard picker\n\(safari.debugDescription)")
        pick.tap()
        XCTAssertTrue(element(in: safari, labelled: "Aside").waitForExistence(timeout: 3), "Aside keyboard did not show")
    }

    private func allowFullAccess() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        for step in ["General", "Keyboard", "Keyboards", "Aside"] {
            // Cells, not static texts: the navigation bar title matches the same word.
            let row = settings.cells.containing(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", step, step + ",")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Settings: no \(step) row\n\(settings.debugDescription)")
            row.tap()
        }
        let toggle = settings.switches["Allow Full Access"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Allow Full Access switch\n\(settings.debugDescription)")
        // Settings can show the switch on while the grant itself was lost by a reinstall,
        // so always cycle it: off, then on again.
        if (toggle.value as? String) == "1" {
            toggle.tap()
            sleep(1)
        }
        toggle.tap()
        let allow = settings.alerts.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        sleep(1)
        XCTAssertEqual(toggle.value as? String, "1", "Full Access still off\n\(settings.debugDescription)")
    }
}
