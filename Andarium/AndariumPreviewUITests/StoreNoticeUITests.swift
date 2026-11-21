// SPDX-License-Identifier: GPL-2.0-or-later

#if TESTFLIGHT_STORE_LINK

import XCTest

/// The App Store notice of a TestFlight build, in the Simulator preview built with
/// `STORE_LINK_ID=id0000000000` on the xcodebuild line (a run without it does not
/// build this file). The preview stands an alert in for the system's `open`, so
/// the button's address is read without leaving the application and without a
/// network; every launch starts with the card up.
final class StoreNoticeUITests: XCTestCase {
    private static let title = "Andarium is on the App Store"
    private static let button = "View in App Store"
    private static let row = "Andarium on the App Store"
    private static let address = "https://apps.apple.com/app/id0000000000"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ screen: String, _ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = previewTestLanguage + ["-screen", screen] + arguments
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20), "\(screen) did not open")
        return app
    }

    @MainActor
    private func openInfo(in app: XCUIApplication) {
        let info = app.buttons["Info"]
        XCTAssertTrue(info.waitForExistence(timeout: 10), "Home has no Info button")
        info.tap()
    }

    @MainActor
    func testTheCardShowsTheButtonHandsTheAddressToTheSystemAndTheCloseMarkPutsItAwayForGood() {
        let app = launch("home")
        let card = app.descendants(matching: .any)["store-notice"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Home has no App Store card")
        // The title and the message read as one element.
        let message = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", Self.title)).firstMatch
        XCTAssertTrue(message.exists, "the card does not read with its title first")

        // The button is the way to the App Store page: it hands the page's address to the
        // system (here an alert says which), and the card stays.
        let button = app.buttons[Self.button]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the card has no button")
        XCTAssertTrue(button.isHittable)
        button.tap()
        let alert = app.alerts["Opens the App Store"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "the button opened nothing")
        XCTAssertTrue(alert.staticTexts[Self.address].exists, "the alert named \(alert.debugDescription)")
        alert.buttons["OK"].tap()
        XCTAssertTrue(card.exists, "a tap on the button put the card away")

        // The close mark puts it away, and Info keeps the way back: a link.
        let close = card.buttons["Dismiss"].exists ? card.buttons["Dismiss"] : app.buttons["Dismiss"]
        XCTAssertTrue(close.exists, "the card has no close mark")
        close.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), "the close mark left the card up")
        XCTAssertFalse(app.buttons[Self.button].exists)
        openInfo(in: app)
        let link = app.links[Self.row]
        XCTAssertTrue(link.waitForExistence(timeout: 10), "Info lost its row")
        XCTAssertTrue(
            app.staticTexts["New features arrive in this TestFlight beta first. The App\u{00A0}Store version is more stable."]
                .exists)
    }

    @MainActor
    func testADismissedCardStaysAwayAndInfoKeepsItsRow() {
        let app = launch("home", "-storeNotice", "dismissed")
        XCTAssertTrue(app.buttons["Info"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["store-notice"].exists)
        XCTAssertFalse(app.buttons[Self.button].exists)
        openInfo(in: app)
        XCTAssertTrue(app.links[Self.row].waitForExistence(timeout: 10), "Info has no row")
    }

    @MainActor
    func testWelcomeShowsTheCardBeforeAnyVirtualMachineExists() {
        let app = launch("welcome")
        XCTAssertTrue(app.staticTexts["No virtual machine yet"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["store-notice"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[Self.button].exists)
        XCTAssertTrue(app.buttons["Set up virtual machine"].exists, "the card hides Set up virtual machine")
    }
}

#endif
