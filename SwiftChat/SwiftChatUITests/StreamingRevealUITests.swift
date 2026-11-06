//
//  StreamingRevealUITests.swift
//  SwiftChatUITests
//
//  Verifies that assistant text does not land as a single block.
//
//  This is a regression guard for a real bug: the word-by-word reveal view was wired into
//  the branch that only renders when the message content is EMPTY, so it never executed and
//  every reply appeared instantly. The test asserts on progressive growth — the visible
//  text after one second must be shorter than the text after three seconds. A block dump
//  fails that; a reveal passes it.
//

import XCTest

final class StreamingRevealUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAssistantTextRevealsProgressively() throws {
        let app = XCUIApplication()
        app.launch()

        // The launch-time notification prompt can cover the input bar.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let allow = springboard.buttons["Allow"]
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }

        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15), "input field not found")
        field.tap()
        field.typeText("Escribime un texto largo de al menos 150 palabras sobre diseño de interfaces.")

        let send = app.buttons["Send message"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "send button not found")
        send.tap()

        // Sample the rendered text twice while the reply is still streaming.
        func visibleText() -> String {
            var out = ""
            for staticText in app.staticTexts.allElementsBoundByIndex {
                let s = staticText.label
                if s.count > out.count && !s.isEmpty {
                    out = s
                }
            }
            return out
        }

        Thread.sleep(forTimeInterval: 2.0)
        let early = visibleText()
        Thread.sleep(forTimeInterval: 3.0)
        let later = visibleText()

        print("EARLY_LEN=\(early.count) LATER_LEN=\(later.count)")

        XCTAssertFalse(early.isEmpty, "no assistant text visible while streaming")
        XCTAssertLessThan(
            early.count, later.count,
            "text should keep growing during streaming; early=\(early.count) later=\(later.count)"
        )
    }
}
