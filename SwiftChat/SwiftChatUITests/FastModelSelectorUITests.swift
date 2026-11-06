//
//  FastModelSelectorUITests.swift
//  SwiftChatUITests
//
//  Regression guard for the model picker living inside the input bar.
//
//  `attachButton` documents that a `Menu` bridged to a UIKit UIMenu does not present
//  reliably from inside the `.glassEffect` input bar, which is why it uses a
//  confirmationDialog instead. The model selector is a `Menu` in that same bar, so this
//  test fails loudly if that limitation ever applies to it too.
//

import XCTest

final class FastModelSelectorUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testModelSelectorPresentsInsideInputBar() throws {
        let app = XCUIApplication()
        app.launch()

        // The launch-time notification prompt can cover the input bar.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }

        let selector = app.buttons["Response model"]
        XCTAssertTrue(selector.waitForExistence(timeout: 15), "speedometer selector not found in the input bar")

        XCTAssertEqual(selector.value as? String, "Makima", "default model should be the main one")

        selector.tap()

        // A Menu that silently fails to present shows nothing at all.
        let fast = app.buttons["Makima Fast"]
        XCTAssertTrue(fast.waitForExistence(timeout: 5), "menu did not present inside the glassEffect input bar")
        fast.tap()

        XCTAssertEqual(selector.value as? String, "Makima Fast", "selection did not apply")

        // Toggle back so the test is idempotent across runs.
        selector.tap()
        let main = app.buttons["Makima"]
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        main.tap()
        XCTAssertEqual(selector.value as? String, "Makima")
    }
}
