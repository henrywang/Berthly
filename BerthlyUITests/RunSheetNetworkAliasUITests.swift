// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

final class RunSheetNetworkAliasUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// #207: a malformed alias must block Run with an inline reason, before any image fetch.
    @MainActor
    func testMalformedNetworkAliasGatesSubmit() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 10))
        runButton.click()
        app.buttons["Run Container"].click()

        let imageField = app.windows.textFields["runImageField"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 5))
        imageField.click()
        imageField.typeText("local/web:1.4")

        app.buttons["runCategory-Network"].click()
        app.buttons["runNetworkAddButton"].click()
        let aliasesField = app.windows.textFields["runNetworkAliasesField"]
        XCTAssertTrue(aliasesField.waitForExistence(timeout: 5))
        let submit = app.windows.buttons["runSubmitButton"]
        XCTAssertTrue(submit.isEnabled)

        aliasesField.click()
        aliasesField.typeText("api-.test")
        XCTAssertTrue(app.windows.staticTexts["runNetworkAliasError"].waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled, "a malformed alias should disable Run")

        app.typeKey("a", modifierFlags: .command)
        aliasesField.typeText("api.test")
        XCTAssertTrue(app.windows.staticTexts["runNetworkAliasError"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)
    }
}
