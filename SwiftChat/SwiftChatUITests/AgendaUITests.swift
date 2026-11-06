import XCTest

final class AgendaUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSidebarAgendaNavigationAndEditorsLeaveNoMenuBelowChatInput() {
        let app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "System permissions") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            if alert.buttons["OK"].exists { alert.buttons["OK"].tap(); return true }
            return false
        }
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            if springboard.buttons["Allow"].waitForExistence(timeout: 1) { springboard.buttons["Allow"].tap() }
            if springboard.buttons["OK"].exists { springboard.buttons["OK"].tap() }
        }

        let sidebar = app.buttons["Open sidebar"]
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "No navigation menu may appear below the input")
        sidebar.tap()
        let calendar = app.buttons["sidebar.calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        let sidebarShot = XCTAttachment(screenshot: app.screenshot())
        sidebarShot.name = "Sidebar navigation"
        sidebarShot.lifetime = .keepAlways
        add(sidebarShot)
        calendar.tap()
        XCTAssertTrue(app.navigationBars["Calendar"].waitForExistence(timeout: 5))
        let calendarShot = XCTAttachment(screenshot: app.screenshot())
        calendarShot.name = "Calendar"
        calendarShot.lifetime = .keepAlways
        add(calendarShot)

        app.buttons["Add event"].tap()
        XCTAssertTrue(app.navigationBars["New event"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Remind me"].value as? String, "1")
        XCTAssertFalse(app.buttons["Save"].isEnabled)
        let title = app.textFields["Title"]
        title.tap()
        title.typeText("Agenda UI verification (not saved)")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Cancel"].tap()

        app.buttons["Open sidebar"].tap()
        app.buttons["sidebar.todo"].tap()
        XCTAssertTrue(app.navigationBars["To-do"].waitForExistence(timeout: 5))
        let todoShot = XCTAttachment(screenshot: app.screenshot())
        todoShot.name = "To-do"
        todoShot.lifetime = .keepAlways
        add(todoShot)
        app.buttons["Add task"].tap()
        XCTAssertTrue(app.navigationBars["New task"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Remind me"].value as? String, "1")
        XCTAssertTrue(app.switches["Completed"].exists)
        app.buttons["Cancel"].tap()

        app.buttons["Schedule a check-in"].tap()
        XCTAssertTrue(app.navigationBars["New check-in"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["First reminder"].exists)
        app.buttons["Cancel"].tap()
        app.buttons["Open sidebar"].tap()
        app.buttons["sidebar.chat"].tap()
        XCTAssertTrue(app.buttons["Response model"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.buttons["New chat"].tap()
        app.buttons["Open sidebar"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-row.blank.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeRight()
        let deleteAction = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteAction.waitForExistence(timeout: 5), "Rightward swipe must reveal Delete")
        deleteAction.tap()
        let confirmation = app.alerts["Delete Chat"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Delete"].tap()
        app.buttons["Close sidebar"].tap()
        XCTAssertTrue(app.buttons["Response model"].waitForExistence(timeout: 5))
    }
}
