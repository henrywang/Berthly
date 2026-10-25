// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

final class MachineCreateSheetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// #208: an invalid account field must block Create rather than silently fall back to the
    /// host user, and the sheet must say why.
    @MainActor
    func testMachineCreateAccountFieldValidationGatesSubmit() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let searchField = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("create machine")
        app.typeKey(.return, modifierFlags: [])

        let imageField = app.windows.textFields["machineImageField"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 5))
        imageField.click()
        imageField.typeText("ubuntu:24.04")

        app.windows.buttons["machineAdvancedDisclosure"].click()
        let uidField = app.windows.textFields["machineUIDField"]
        XCTAssertTrue(uidField.waitForExistence(timeout: 5))
        // The Advanced section extends past the sheet's capped scroll height.
        app.windows.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -500)
        let submit = app.windows.buttons["machineCreateSubmitButton"]
        XCTAssertTrue(submit.isEnabled)

        uidField.click()
        uidField.typeText("abc")
        XCTAssertTrue(app.windows.staticTexts["machineAccountError"].waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "a non-numeric UID should disable Create")

        app.typeKey("a", modifierFlags: .command)
        uidField.typeText("4242")
        XCTAssertTrue(app.windows.staticTexts["machineAccountError"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)

        submit.click()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5), "a valid account should submit")
    }
}
