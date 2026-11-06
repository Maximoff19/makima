//
//  ChatSwitchVisibilityUITests.swift
//  SwiftChatUITests
//
//  Regression guard: switching to another chat and back left the message list
//  invisible. `ChatListView` set `tableOpacity = 0` on every chat switch but only
//  restored it for blank chats, so any chat with messages stayed at alpha 0.
//
//  `isHittable` is the assertion that catches it: an element rendered at opacity 0
//  still exists in the tree but is not hittable, which is exactly what the user saw.
//

import XCTest

final class ChatSwitchVisibilityUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launchAndAllowNotifications() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }
        return app
    }

    @MainActor
    func testMessagesStayVisibleAfterSwitchingChats() throws {
        let app = launchAndAllowNotifications()

        // Seed two chats with content, so the switch has something to lose.
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "input field not found")

        for seed in ["primer mensaje de prueba", "segundo mensaje de prueba"] {
            let box = app.textViews.firstMatch
            XCTAssertTrue(box.waitForExistence(timeout: 10))
            box.tap()
            box.typeText(seed)
            app.buttons["Send message"].firstMatch.tap()
            _ = app.staticTexts[seed].waitForExistence(timeout: 20)
        }

        // Build a second chat.
        let newChat = app.buttons["New chat"]
        if newChat.exists { newChat.tap() }
        let box = app.textViews.firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 10))
        box.tap()
        box.typeText("contenido del segundo chat")
        app.buttons["Send message"].firstMatch.tap()
        _ = app.staticTexts["contenido del segundo chat"].waitForExistence(timeout: 20)

        // Go to chat 1, then chat 2, then back to chat 1.
        app.buttons["Open sidebar"].tap()
        let first = app.staticTexts["primer mensaje de prueba"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "chat 1 not listed")
        first.tap()

        app.buttons["Open sidebar"].tap()
        let second = app.staticTexts["contenido del segundo chat"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10), "chat 2 not listed")
        second.tap()

        app.buttons["Open sidebar"].tap()
        first.tap()

        // The regression: the list came back at alpha 0 and nothing was visible.
        let marker = app.staticTexts["primer mensaje de prueba"].firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "message missing after switching back")
        XCTAssertTrue(marker.isHittable, "message list is present but not visible (opacity stuck at 0)")
    }
}
