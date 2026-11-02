import XCTest
import UIKit

/// Drives the real app through its screens while the workflow takes
/// `simctl io` screenshots. Sync is one-way: the test prints
/// `SHOT:<name>` / `APPEAR:light` to the runner log, then holds the
/// state for a fixed window so the capture always lands inside it.
final class Shots: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication(bundleIdentifier: "com.terminal.app")
    }

    // MARK: - Flow

    func testFlow() {
        app.launch()
        nap(5)
        shot("01-onboarding")

        // The connect form — fields are found by placeholder/label.
        type(into: ["server.example.com", "Host"], "localhost")
        type(into: ["root", "Username"], "runner")
        type(into: ["Optional", "Password"], "Term1n4lSh0ts", secure: true)

        // Tap the hero to drop focus, then connect.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        nap(1)
        tapAny(["connectButton", "Connect"])

        // Host-key trust dialog.
        let trust = app.buttons["Trust"].firstMatch
        if trust.waitForExistence(timeout: 60) {
            nap(2)
            trust.tap()
        } else {
            NSLog("NO-TRUST-DIALOG")
        }

        nap(20)
        shot("02-terminal")

        // Summon the keyboard to show the accessory bar.
        app.descendants(matching: .any)["terminalSurface"].firstMatch.tap()
        nap(4)
        shot("03-keyboard")

        // Type a command so the shell isn't empty in the shot.
        app.typeText("uname -a\n")
        nap(4)
        shot("04-terminal-live")

        // SFTP file browser through the workspace menu.
        for key in ["hide keyboard", "Hide keyboard", "keyboard.chevron.compact.down"] {
            let b = app.keyboards.buttons[key].firstMatch
            if b.exists { b.tap(); break }
        }
        nap(1)
        tapAny(["workspaceMenu", "ellipsis.circle", "More"])
        nap(1)
        tapAny(["Files"])
        nap(12)
        shot("05-files")

        // Dismiss the sheet, close the session, land on hosts.
        app.descendants(matching: .any)["filesBrowser"].firstMatch.swipeDown()
        nap(2)
        tapAny(["workspaceMenu", "ellipsis.circle", "More"])
        nap(1)
        tapAny(["Close"])
        nap(2)
        shot("06-hosts")

        tapAny(["settingsButton", "gearshape"])
        nap(2)
        shot("07-settings")

        app.descendants(matching: .any)["Theme"].firstMatch.tap()
        nap(2)
        shot("08-theme-picker")

        // Light mode: workflow flips simulator appearance on the marker.
        announce("APPEAR:light")
        nap(6)
        app.navigationBars.buttons.element(boundBy: 0).tap() // back to settings
        nap(1)
        app.swipeDown() // close the sheet
        nap(2)
        shot("09-hosts-light")

        // Onboarding once more, now in light — the argument-domain
        // default overrides the stored flag without wiping data.
        app.terminate()
        let light = XCUIApplication(bundleIdentifier: "com.terminal.app")
        light.launchArguments = ["-onboarding.done", "NO"]
        light.launch()
        nap(4)
        shot("10-onboarding-light")
    }

    // MARK: - Sync

    /// Mark a screenshot point, then hold the state for the workflow's
    /// log-tail + `simctl io` latency.
    private func shot(_ name: String) {
        announce("SHOT:\(name)")
        nap(10)
    }

    private func announce(_ marker: String) {
        FileHandle.standardError.write(Data((marker + "\n").utf8))
        NSLog("%@", marker)
    }

    // MARK: - Helpers

    private func nap(_ seconds: UInt32) { sleep(seconds) }

    private func tapAny(_ ids: [String]) {
        for id in ids {
            let el = app.buttons[id].firstMatch
            if el.waitForExistence(timeout: 3) { el.tap(); return }
        }
        for id in ids {
            let el = app.descendants(matching: .any)[id].firstMatch
            if el.waitForExistence(timeout: 2) && el.isHittable { el.tap(); return }
        }
        NSLog("TAP-MISS %@", ids.joined(separator: ","))
    }

    private func type(into ids: [String], _ text: String, secure: Bool = false) {
        let fields = secure ? app.secureTextFields : app.textFields
        for id in ids {
            let el = fields[id].firstMatch
            if el.waitForExistence(timeout: 4) {
                el.tap()
                nap(1)
                el.typeText(text)
                return
            }
        }
        NSLog("FIELD-MISS %@", ids.joined(separator: ","))
    }
}
