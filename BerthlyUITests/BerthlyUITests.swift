//
//  BerthlyUITests.swift
//  BerthlyUITests
//
//  Created by Henry Wang on 6/28/26.
//

import XCTest

final class BerthlyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Kill any stray instance left over from a manual launch, a crash, or a
        // previous run that never reached tearDown — XCUIApplication().launch()
        // can't reliably adopt an instance it didn't start itself, which leads to
        // a window that never appears and every assertion below failing/skipping.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killer.arguments = ["-9", "Berthly"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        if (try? killer.run()) != nil {
            killer.waitUntilExit()
        }
    }

    /// Environment-independent: sidebar/toolbar render regardless of daemon connection state,
    /// so this never depends on `container system` being installed or running.
    @MainActor
    func testMainWindowLaunchesWithSidebarAndToolbar() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Images"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Build"].exists)
        XCTAssertTrue(app.buttons["Pull"].exists)
    }

    /// Exercises the Build sheet open/close path — this is the exact interaction that
    /// previously crashed (SwiftUI environment propagation into a sheet's NSWindow).
    /// Skips instead of failing when no daemon is connected, since the Build button is
    /// disabled in that state and this shouldn't be flaky in environments without `container`.
    @MainActor
    func testBuildSheetOpensAndClosesWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launch()

        let buildButton = app.buttons["Build"]
        guard buildButton.waitForExistence(timeout: 10), buildButton.isEnabled else {
            throw XCTSkip("No connected container daemon in this environment; skipping sheet interaction")
        }

        buildButton.click()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Build sheet should appear")

        cancelButton.click()

        // App must still be alive and responsive after the sheet is dismissed.
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Same crash class as the Build sheet, exercised for Run instead.
    @MainActor
    func testRunSheetOpensAndClosesWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launch()

        let runButton = app.buttons["Run"]
        guard runButton.waitForExistence(timeout: 10), runButton.isEnabled else {
            throw XCTSkip("No connected container daemon in this environment; skipping sheet interaction")
        }

        runButton.click()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Run sheet should appear")

        cancelButton.click()

        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
