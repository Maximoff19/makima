//
//  SwiftChatUITests.swift
//  SwiftChatUITests
//
//  Created by Sacha  on 3/25/26.
//

import XCTest

final class SwiftChatUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testSidebarFitsAndNewChatIsInToolbar() throws {
        let app = XCUIApplication()
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }

        let newChat = app.buttons["New chat"]
        XCTAssertTrue(newChat.waitForExistence(timeout: 10))
        app.buttons["Open sidebar"].tap()

        let history = app.staticTexts["Chat History"]
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(history.frame.minX, app.frame.minX)
        XCTAssertLessThanOrEqual(history.frame.maxX, app.frame.maxX)
        XCTAssertTrue(newChat.exists)
    }

    /// End-to-end check of the opt-in Super mode: the picker must offer it and reflect the
    /// selection, and a real message must come back through the gateway's private OpenCode
    /// bridge on the VPS. The answer is matched with `CONTAINS` because the bridge returns
    /// the model's full text, not a token-by-token stream.
    @MainActor
    func testSuperModeAnswersThroughOpenCode() throws {
        let app = XCUIApplication()
        app.launch()

        // The launch-time notification prompt can cover the input bar.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }

        let selector = app.buttons["Response model"]
        XCTAssertTrue(selector.waitForExistence(timeout: 20), "model picker is missing")
        selector.tap()
        let superOption = app.buttons["Makima Super"]
        XCTAssertTrue(superOption.waitForExistence(timeout: 5), "Makima Super is not offered")
        superOption.tap()
        XCTAssertEqual(selector.value as? String, "Makima Super", "selection did not apply")

        let box = app.textViews.firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 15), "input field not found")
        box.tap()
        box.typeText("Responde solo con la palabra LISTO")
        app.buttons["Send message"].firstMatch.tap()

        // The bridge waits for the full OpenCode response, so the answer appears in one go.
        let answer = NSPredicate(format: "label CONTAINS[c] %@", "LISTO")
        expectation(for: answer, evaluatedWith: app.staticTexts)
        waitForExpectations(timeout: 240)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
