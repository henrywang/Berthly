// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

final class CommitContainerSheetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// #206: the detail's Commit button opens the sheet, an invalid reference blocks Commit with
    /// a reason, and a valid one finishes with the created reference.
    @MainActor
    func testCommitSheetValidatesThenCommits() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let row = app.staticTexts["computeRow-web-frontend"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let commitButton = app.buttons["containerCommitButton"]
        XCTAssertTrue(commitButton.waitForExistence(timeout: 5))
        commitButton.click()

        let field = app.windows.textFields["commitTargetField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let submit = app.windows.buttons["commitSubmitButton"]
        XCTAssertTrue(submit.isEnabled, "the prefilled reference should be committable")

        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText("Not A Reference")
        XCTAssertTrue(app.windows.descendants(matching: .any)["commitTargetIssue"].waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "an invalid reference should disable Commit")

        app.typeKey("a", modifierFlags: .command)
        field.typeText("team/web:snap")
        XCTAssertTrue(submit.isEnabled)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.windows.buttons["Done"].waitForExistence(timeout: 5))
    }
}
