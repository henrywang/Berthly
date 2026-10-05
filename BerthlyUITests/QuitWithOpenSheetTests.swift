// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// ⌘Q must quit Berthly while a sheet is up. AppKit lets a modally presented window veto
/// termination (`NSWindow.preventsApplicationTerminationWhenModal`, default YES, but windows made
/// by frameworks such as SwiftUI may override it per OS release), so these guard against a release
/// where an open Run/Create sheet turns ⌘Q into a silent no-op. The no-sheet case is the control:
/// if it fails, the quit mechanism under test is unreliable and the sheet results mean nothing.
final class QuitWithOpenSheetTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication.terminateRunningBerthly()
    }

    @MainActor
    func testCommandQQuitsWithNoSheetOpen() {
        let app = launch()
        assertQuitsOnCommandQ(app)
    }

    @MainActor
    func testCommandQQuitsWithRunContainerSheetOpen() {
        let app = launch()
        openFromRunMenu(app, choice: "Run Container")
        assertQuitsOnCommandQ(app)
    }

    @MainActor
    func testCommandQQuitsWithCreateMachineSheetOpen() {
        let app = launch()
        openFromRunMenu(app, choice: "Create Machine")
        assertQuitsOnCommandQ(app)
    }

    @MainActor
    func testCommandQQuitsWithDeleteConfirmationOpen() {
        let app = launch()
        let row = app.staticTexts["computeRow-edge-proxy"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()
        XCTAssertTrue(
            app.windows.buttons["containerDeleteConfirmButton"].firstMatch.waitForExistence(timeout: 5),
            "Delete confirmation should be open"
        )
        assertQuitsOnCommandQ(app)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["runToolbarButton"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func openFromRunMenu(_ app: XCUIApplication, choice: String) {
        app.buttons["runToolbarButton"].click()
        let item = app.buttons[choice]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
        XCTAssertTrue(app.staticTexts[choice].waitForExistence(timeout: 5), "\(choice) sheet should be open")
    }

    @MainActor
    private func assertQuitsOnCommandQ(_ app: XCUIApplication) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(
            app.wait(for: .notRunning, timeout: 10),
            "⌘Q should quit Berthly; app state is \(app.state.rawValue)"
        )
    }
}
