import XCTest
import UIKit

/// Drives the real app through its screens while the workflow takes
/// `simctl io` screenshots. Sync: the test prints `SHOT:<name>` to the
/// log, then blocks until the workflow writes `DONE:<name>` to the
/// simulator pasteboard (`simctl pbcopy`). `APPEAR:light` asks the
/// workflow to switch simulator appearance first.
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
        checkpoint("01-onboarding")

        // The connect form — fields are found by placeholder/label.
        type(into: ["server.example.com", "Host"], "test.rebex.net")
        type(into: ["root", "Username"], "demo")
        type(into: ["Optional", "Password"], "password", secure: true)

        // Tap the hero to drop focus, then connect.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        nap(1)
        tapAny(["connectButton", "Connect"])

        // Host-key trust dialog.
        let trust = app.buttons["Trust"].firstMatch
        _ = trust.waitForExistence(timeout: 60)
        trust.tap()

        nap(18)
        checkpoint("02-terminal")

        // Summon the keyboard to show the accessory bar.
        app.descendants(matching: .any)["terminalSurface"].firstMatch.tap()
        nap(3)
        checkpoint("03-keyboard")

        // SFTP file browser through the workspace menu.
        tapAny(["workspaceMenu", "ellipsis.circle", "More"])
        nap(1)
        tapAny(["Files"])
        nap(10)
        checkpoint("04-files")

        // Dismiss the sheet, close the session, land on hosts.
        app.descendants(matching: .any)["filesBrowser"].firstMatch.swipeDown()
        nap(2)
        tapAny(["workspaceMenu", "ellipsis.circle", "More"])
        nap(1)
        tapAny(["Close"])
        nap(2)
        checkpoint("05-hosts")

        tapAny(["settingsButton", "gearshape"])
        nap(2)
        checkpoint("06-settings")

        app.descendants(matching: .any)["Theme"].firstMatch.tap()
        nap(2)
        checkpoint("07-theme-picker")

        // Light mode: workflow flips simulator appearance.
        announce("APPEAR:light")
        waitPaste("DONE:light")
        nap(2)
        app.navigationBars.buttons.element(boundBy: 0).tap() // back
        nap(1)
        app.swipeDown() // close settings sheet
        nap(2)
        checkpoint("08-hosts-light")

        // Onboarding once more, now in light — argument-domain default
        // overrides the stored flag without wiping data.
        app.terminate()
        let light = XCUIApplication(bundleIdentifier: "com.terminal.app")
        light.launchArguments = ["-onboarding.done", "NO"]
        light.launch()
        nap(4)
        checkpoint("09-onboarding-light")
    }

    // MARK: - Sync

    private func checkpoint(_ name: String) {
        announce("SHOT:\(name)")
        waitPaste("DONE:\(name)")
        nap(3) // let the pasteboard toast slide away
    }

    private func announce(_ marker: String) {
        FileHandle.standardError.write(Data((marker + "\n").utf8))
        NSLog("%@", marker)
    }

    private func waitPaste(_ token: String, timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if UIPasteboard.general.string == token { return }
            usleep(200_000)
        }
        NSLog("WAIT-TIMEOUT %@", token)
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
