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

    /// Same crash class as the Build sheet, exercised for Run instead. Run now opens a popover
    /// (PopoverAnchor/RunTypeMenuContent) before the sheet, since Container/Machine are separate
    /// sheets.
    @MainActor
    func testRunSheetOpensAndClosesWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launch()

        let runButton = app.buttons["Run"]
        guard runButton.waitForExistence(timeout: 10), runButton.isEnabled else {
            throw XCTSkip("No connected container daemon in this environment; skipping sheet interaction")
        }

        runButton.click()

        let containerOption = app.buttons["Run Container"]
        XCTAssertTrue(containerOption.waitForExistence(timeout: 5), "Run menu popover should appear")
        containerOption.click()

        let cancelButton = app.buttons["Cancel"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "Run container sheet should appear")

        cancelButton.click()

        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Deterministic via `MockContainerService` (`UITEST_USE_MOCK_SERVICE`) — unlike the tests
    /// above, this doesn't depend on whether a real daemon is installed or its actual
    /// running/stopped state, so it can assert the disconnected screen and the transition it
    /// triggers without needing to force that state in a live `container` install.
    @MainActor
    func testDaemonStoppedShowsStartButtonAndConnectsOnTap() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["UITEST_INITIAL_DAEMON_STATE"] = "installedButStopped"
        app.launch()

        XCTAssertTrue(app.staticTexts["Container System Stopped"].waitForExistence(timeout: 10))
        let startButton = app.buttons["Start Container System"]
        XCTAssertTrue(startButton.exists)

        startButton.click()

        // MockContainerService.startDaemon() moves installedButStopped -> connecting -> connected;
        // once connected, the gated content pane swaps to the seeded compute list.
        XCTAssertTrue(app.staticTexts["web-frontend"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start Container System"].exists)
    }

    /// The Run button opens a popover with both choices before landing on either sheet — pure UI
    /// state with no daemon operation involved, so the mock just needs the toolbar's Run button
    /// enabled. Covers both routes: Container -> RunContainerSheet, Machine -> MachineCreateSheet.
    @MainActor
    func testRunMenuOpensEitherContainerOrMachineSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let runButton = app.buttons["Run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 10))
        runButton.click()

        XCTAssertTrue(app.buttons["Run Container"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Machine"].exists)

        app.buttons["Create Machine"].click()
        XCTAssertTrue(app.staticTexts["Create machine"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()

        runButton.click()
        XCTAssertTrue(app.buttons["Run Container"].waitForExistence(timeout: 5))
        app.buttons["Run Container"].click()
        XCTAssertTrue(app.staticTexts["Run container"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
    }

    // MARK: - Menu Bar Extra

    /// Launches with the mock service and clicks the status item open — every menu bar test
    /// starts here, since `XCUIApplication` traverses every window the app owns, so the
    /// popover's content becomes queryable through the same `app` object once it's open.
    @MainActor
    @discardableResult
    private func launchAndOpenMenuBarExtra() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10))
        statusItem.click()
        return app
    }

    @MainActor
    func testMenuBarExtraShowsRunningSummaryAndDaemonStatus() throws {
        let app = try launchAndOpenMenuBarExtra()

        XCTAssertTrue(app.staticTexts["Containers"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Machines"].exists)
        XCTAssertTrue(app.staticTexts["Container daemon"].exists)
    }

    /// Regression test: a `menuBarExtraStyle(.window)` popover has no built-in dismissal like a
    /// native `NSStatusItem` menu does — `openOrFocusMainWindow` closes it manually via a captured
    /// `NSWindow` reference (`WindowAccessor`). Also covers the "Run…" submenu routing to the
    /// container sheet.
    @MainActor
    func testMenuBarExtraRunSubmenuOpensContainerSheetAndClosesPopover() throws {
        let app = try launchAndOpenMenuBarExtra()

        let runSubmenu = app.buttons["Run…"]
        XCTAssertTrue(runSubmenu.waitForExistence(timeout: 5))
        runSubmenu.click()

        let runContainer = app.buttons["Run Container…"]
        XCTAssertTrue(runContainer.waitForExistence(timeout: 5))
        runContainer.click()

        XCTAssertTrue(app.staticTexts["Run container"].waitForExistence(timeout: 5), "Sheet should open in the main window")
        XCTAssertFalse(app.staticTexts["Container daemon"].exists, "Menu bar popover should close after selecting an action")

        app.buttons["Cancel"].click()
    }

    /// Regression test: `openWindow(id:)` has no built-in single-instance behavior for a plain
    /// `WindowGroup` — without `bridge.isMainWindowOpen` gating it, "Open Berthly" would open a
    /// duplicate window every time one already exists instead of focusing it.
    @MainActor
    func testMenuBarExtraOpenBerthlyDoesNotDuplicateMainWindow() throws {
        let app = try launchAndOpenMenuBarExtra()

        let openBerthly = app.buttons["Open Berthly"]
        XCTAssertTrue(openBerthly.waitForExistence(timeout: 5))
        openBerthly.click()

        let mainWindows = app.windows.matching(NSPredicate(format: "title == %@", "Compute"))
        XCTAssertEqual(mainWindows.count, 1, "Open Berthly should focus the existing window, not open a duplicate")
    }

    /// The daemon toggle's stop path shows an inline confirmation rather than a system `.alert` —
    /// alerts presented from inside a `menuBarExtraStyle(.window)` panel were found to be
    /// unreliable in practice (the confirmation could disappear without its action ever running).
    @MainActor
    func testMenuBarExtraDaemonToggleShowsInlineStopConfirmation() throws {
        let app = try launchAndOpenMenuBarExtra()

        let toggle = app.checkBoxes["menuBarDaemonToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.click()

        // Plain "Stop"/"Cancel" would be ambiguous — every running row has its own "Stop" button
        // (auto-labeled from the "stop.fill" SF Symbol), so the confirmation's buttons need their
        // own identifiers to query unambiguously.
        let stopButton = app.buttons["menuBarStopConfirmStop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5), "Inline stop confirmation should appear")
        XCTAssertTrue(app.staticTexts["Container daemon"].exists, "Popover should stay open for the confirmation")

        app.buttons["menuBarStopConfirmCancel"].click()

        // A plain `.exists` check here would race the app's own UI update after the click —
        // wait for the condition instead of asserting on it immediately.
        let disappeared = NSPredicate(format: "exists == false")
        expectation(for: disappeared, evaluatedWith: stopButton)
        waitForExpectations(timeout: 5)
    }

    /// Repeated sheet open/close is a classic leak source (an `@Observable` view model or a
    /// `Task` that outlives dismissal), so it's what we churn here rather than idling. Mock mode
    /// keeps this deterministic and fast — it's measuring the cost of the sheet lifecycle itself,
    /// not the real daemon. XCTMemoryMetric/XCTCPUMetric have no built-in pass/fail threshold:
    /// Xcode records a baseline on first run and flags future measurements that regress against
    /// it (Test Report > set baseline), so this needs a baseline set once after landing.
    @MainActor
    func testMemoryAndCPUUsageDuringSheetChurn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let runButton = app.buttons["Run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 10))

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTMemoryMetric(), XCTCPUMetric()], options: options) {
            for _ in 0..<5 {
                runButton.click()
                let containerOption = app.buttons["Run Container"]
                _ = containerOption.waitForExistence(timeout: 5)
                containerOption.click()
                let cancelButton = app.buttons["Cancel"]
                _ = cancelButton.waitForExistence(timeout: 5)
                cancelButton.click()
            }
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
