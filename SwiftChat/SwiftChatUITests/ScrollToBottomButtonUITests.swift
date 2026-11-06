//
//  ScrollToBottomButtonUITests.swift
//  SwiftChatUITests
//
//  Regression guard for the scroll-to-bottom button never appearing.
//
//  The sentinel that reports how far the content extends past the viewport lived inside
//  the LazyVStack. A LazyVStack only materialises rows near the viewport, so as soon as the
//  user scrolled up the sentinel was destroyed and stopped emitting its preference — leaving
//  `isAtBottom` frozen at `true` and the button permanently hidden.
//
//  The fix moves the sentinel out of the LazyVStack. This test creates a conversation tall
//  enough to scroll, scrolls back up, and asserts the button is on screen and hittable.
//

import XCTest

final class ScrollToBottomButtonUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchAllowingNotifications() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }
        return app
    }

    @MainActor
    func testScrollToBottomButtonAppearsAfterScrollingUp() throws {
        let app = launchAllowingNotifications()

        let box = app.textViews.firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 20), "input field not found")

        // Enough messages to make the list taller than the viewport. The replies never have to
        // arrive: each user bubble alone is enough to push the content past the screen.
        for index in 1...8 {
            box.tap()
            box.typeText("Mensaje de prueba numero \(index) para generar una conversacion larga")
            app.buttons["Send message"].firstMatch.tap()
            _ = app.staticTexts["Mensaje de prueba numero \(index)"].waitForExistence(timeout: 15)
        }

        // Dismiss the keyboard so the list owns the full screen, then drag downwards to scroll
        // back to the top of the conversation.
        if app.keyboards.buttons["Return"].exists || app.keyboards.count > 0 {
            app.swipeDown()
        }
        let list = app.scrollViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "message list not found")
        list.swipeDown()
        list.swipeDown()

        let button = app.buttons["Scroll to bottom"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 5),
            "scroll-to-bottom button did not appear after scrolling up"
        )
        XCTAssertTrue(button.isHittable, "scroll-to-bottom button exists but is not tappable")

        // And it must actually work.
        button.tap()
        let newest = app.staticTexts["Mensaje de prueba numero 8"]
        XCTAssertTrue(
            newest.waitForExistence(timeout: 10),
            "tapping scroll-to-bottom did not bring the latest message into view"
        )
    }
}
