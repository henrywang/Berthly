//
//  BerthlyUITests.swift
//  BerthlyUITests
//
//  Created by Henry Wang on 6/28/26.
//

import XCTest

extension XCUIApplication {
    /// Every test must launch through this. Berthly is a menu-bar app — closing the main window
    /// leaves it running, and quitting it in that state makes macOS window restoration relaunch
    /// it with *zero* windows. A test launching plainly then times out against an invisible app,
    /// purely because of how the app was last quit on this machine. Ignoring persisted state
    /// keeps launches deterministic (CLAUDE.md: control all inputs, reset state every launch).
    static func berthly() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }
}

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
        let app = XCUIApplication.berthly()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Images"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Build"].exists)
        XCTAssertTrue(app.buttons["Pull"].exists)
    }

    /// Regression test for the simplified Daemon Logs box (`DaemonLogView`): confirms the mock
    /// `streamDaemonLogs` events actually reach the page and render. Text surfaces via the
    /// `value` attribute, not `label` (confirmed via `XCUIApplication.debugDescription` — a plain
    /// SwiftUI `Text` inside an `HStack`, unlike a button's title, reports through AXValue on
    /// macOS), and this page's Form isn't a lazy List, so rows exist in the accessibility tree
    /// without needing to scroll them into view first.
    @MainActor
    func testSystemPageShowsDaemonLogEvents() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        app.staticTexts["System"].click()

        func logRow(containing text: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
        }

        XCTAssertTrue(logRow(containing: "apiserver started").waitForExistence(timeout: 5))
        XCTAssertTrue(logRow(containing: "xpc client handler connection error").exists)
    }

    /// Exercises the Build sheet open/close path — this is the exact interaction that
    /// previously crashed (SwiftUI environment propagation into a sheet's NSWindow).
    /// Skips instead of failing when no daemon is connected, since the Build button is
    /// disabled in that state and this shouldn't be flaky in environments without `container`.
    @MainActor
    func testBuildSheetOpensAndClosesWithoutCrashing() throws {
        let app = XCUIApplication.berthly()
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
        let app = XCUIApplication.berthly()
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
        let app = XCUIApplication.berthly()
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

    /// First-launch guided install: the notInstalled gate offers an in-app install, which (in
    /// the mock) fakes download/verify/install and then connects. Asserts the full path from
    /// "Container Not Installed" through the confirm alert to connected content.
    @MainActor
    func testNotInstalledGateInstallsAndConnects() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["UITEST_INITIAL_DAEMON_STATE"] = "notInstalled"
        app.launch()

        XCTAssertTrue(app.staticTexts["notInstalledGateTitle"].waitForExistence(timeout: 10))
        let installButton = app.buttons["installContainerButton"]
        XCTAssertTrue(installButton.exists)

        installButton.click()

        // The confirmation alert's Install button — matched by title within the alert sheet
        // (a bare app.buttons["Install"] also matches the TouchBar's copy of the default button),
        // since SwiftUI alert buttons don't reliably surface accessibility identifiers on macOS.
        let confirmButton = app.sheets.firstMatch.buttons["Install"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Install confirmation alert should appear")
        confirmButton.click()

        // Mock installContainer streams fake progress, then startDaemon() lands on connected —
        // the gate swaps to the seeded compute list.
        XCTAssertTrue(app.staticTexts["web-frontend"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["installContainerButton"].exists)
    }

    /// Regression: the update's progress screen must survive the daemonState transitions the
    /// update itself causes. `upgradeContainer` stops the daemon first, and progress state that
    /// lived inside the versionMismatch gate got torn down at that transition — users saw
    /// "Container System Stopped" while the update silently kept running.
    @MainActor
    func testVersionMismatchGateUpdatesAndConnects() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["UITEST_INITIAL_DAEMON_STATE"] = "versionMismatch"
        app.launch()

        XCTAssertTrue(app.staticTexts["updateRequiredGateTitle"].waitForExistence(timeout: 10))
        app.buttons["updateContainerButton"].click()

        let confirmButton = app.sheets.firstMatch.buttons["Update"]
        // Matched by identifier (label/value exposure of SwiftUI Text is unreliable on macOS),
        // built before clicking so waitForExistence starts sampling immediately — the progress
        // window is only as long as the mock's simulated update.
        let progressText = app.staticTexts["operationProgressMessage"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "Update confirmation alert should appear")
        confirmButton.click()

        // The progress screen persists through the mock's stopped→connecting transitions; with
        // the old per-gate state this text vanished as soon as the daemon state changed.
        XCTAssertTrue(
            progressText.waitForExistence(timeout: 3),
            "Update progress screen should appear and survive daemon state changes"
        )

        XCTAssertTrue(app.staticTexts["web-frontend"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["updateContainerButton"].exists)
    }

    /// The Run button opens a popover with both choices before landing on either sheet — pure UI
    /// state with no daemon operation involved, so the mock just needs the toolbar's Run button
    /// enabled. Covers both routes: Container -> RunContainerSheet, Machine -> MachineCreateSheet.
    @MainActor
    func testRunMenuOpensEitherContainerOrMachineSheet() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let runButton = app.buttons["Run"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 10))
        runButton.click()

        XCTAssertTrue(app.buttons["Run Container"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Create Machine"].exists)

        app.buttons["Create Machine"].click()
        XCTAssertTrue(app.staticTexts["Create Machine"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()

        runButton.click()
        XCTAssertTrue(app.buttons["Run Container"].waitForExistence(timeout: 5))
        app.buttons["Run Container"].click()
        XCTAssertTrue(app.staticTexts["Run Container"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
    }

    /// Command palette (⌘K): opens, filters live via the ranked matcher, dispatches the selected
    /// action on Return, and dismisses. Deterministic via `MockContainerService` (connected, with
    /// seeded containers). This locks in the keyboard-driven surface that the manual screenshot
    /// pass verified — screenshots are ephemeral, so the regression guard lives here.
    @MainActor
    func testCommandPaletteOpensFiltersAndDispatches() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Open with ⌘K.
        app.typeKey("k", modifierFlags: .command)
        let searchField = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        // Typing filters: "system" should surface the System nav row and drop the Compute one.
        searchField.typeText("system")
        let systemRow = app.descendants(matching: .any)["palette.nav.system"]
        XCTAssertTrue(systemRow.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["palette.nav.compute"].exists)

        // Return dispatches the top result and dismisses the palette.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(searchField.waitForExistence(timeout: 2), "Palette should dismiss after Return")
        // The navigation actually happened: a System-page-only section appears.
        XCTAssertTrue(app.staticTexts["Disk Usage"].waitForExistence(timeout: 5))
    }

    /// Regression: ⌘K must present the palette even when it arrives *before a window exists*.
    /// Berthly is a menu-bar app, so the main window is often closed; the menu shortcut then bumps
    /// the token and opens a window, and the freshly-mounted view must still present the palette
    /// (via `.onAppear`, since `.onChange` won't fire for a token bumped before it mounted).
    @MainActor
    func testCommandPalettePresentsWhenTriggeredWithNoWindowOpen() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Close the main window; the app keeps running (MenuBarExtra), no window present.
        app.typeKey("w", modifierFlags: .command)
        // ⌘K now: reopens a window AND must present the palette on that fresh mount.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(app.textFields["commandPaletteSearchField"].waitForExistence(timeout: 5),
                      "⌘K with no window open should reopen the window and present the palette")
    }

    /// Regression: selecting a container via the palette *from a non-Compute section* must open
    /// its detail. The dispatch sets `sidebarSelection = .compute`, which fires
    /// `MainWindowView`'s `.onChange(of: sidebarSelection)` clearing `selectedCompute`; without the
    /// one-runloop defer in `selectCompute(_:)` the selection is wiped and nothing opens. Starting
    /// on the System page is what makes the section actually change and exposes the bug.
    @MainActor
    func testCommandPaletteSelectContainerFromNonComputeSection() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Move off Compute first, so the palette's `sidebarSelection = .compute` is a real change.
        app.staticTexts["System"].click()
        XCTAssertTrue(app.staticTexts["Disk Usage"].waitForExistence(timeout: 5))

        app.typeKey("k", modifierFlags: .command)
        let searchField = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        // Select the web-frontend container (mock seeds it). Top result for this query.
        searchField.typeText("open web-frontend")
        XCTAssertTrue(app.descendants(matching: .any)["palette.container.select.3f9a2b7c1d"].waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])

        // The detail pane opened: its Overview/Logs/Terminal tab picker (radioButtons) is present,
        // which only renders when a compute item is selected. This fails without the defer fix.
        XCTAssertTrue(app.radioButtons["Terminal"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.radioButtons["Overview"].exists)
    }

    /// Regression: palette "Open Shell in X" from a non-detail section must open X's detail *and*
    /// land on the Terminal tab. The tab lives in a freshly-mounted detail view, so the request is
    /// consumed on `.onAppear` (not just `.onChange`) — without that, it silently stays on Overview.
    @MainActor
    func testCommandPaletteOpenShellRoutesToTerminalTab() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        // Start on System so opening a container's shell is a fresh detail mount.
        app.staticTexts["System"].click()
        XCTAssertTrue(app.staticTexts["Disk Usage"].waitForExistence(timeout: 5))

        app.typeKey("k", modifierFlags: .command)
        let searchField = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("shell web-frontend") // web-frontend is a running container in the mock
        app.typeKey(.return, modifierFlags: [])

        // Detail opened on Terminal, not the default Overview. The segmented picker exposes
        // selection via its `value` (1 = selected), and the tab switch happens on the detail's
        // onAppear — so wait for value == 1 rather than reading it once (avoids a mount race).
        let terminal = app.radioButtons["Terminal"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: terminal)
        waitForExpectations(timeout: 5)
    }

    /// Palette "Delete X" never deletes directly — it must confirm first, then remove the item.
    @MainActor
    func testCommandPaletteDeleteConfirmsThenRemoves() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        // `worker` is a stopped container in the mock (so Delete is offered).
        XCTAssertTrue(app.staticTexts["worker"].waitForExistence(timeout: 5))

        app.typeKey("k", modifierFlags: .command)
        let searchField = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.typeText("delete worker")
        app.typeKey(.return, modifierFlags: [])

        // A confirmation appears rather than deleting outright. Scope to the window's button —
        // `app.buttons["Delete"]` also matches a Touch Bar element, which isn't clickable.
        let confirmDelete = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 5), "Delete must confirm before removing")
        confirmDelete.click()

        // The container is gone.
        XCTAssertTrue(app.staticTexts["worker"].waitForNonExistence(timeout: 5))
    }

    /// ⎋ dismisses the palette without dispatching, and a non-matching query shows the empty state.
    @MainActor
    func testCommandPaletteEscapeDismissesAndEmptyState() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey("k", modifierFlags: .command)
        let searchField = app.textFields["commandPaletteSearchField"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))

        searchField.typeText("zzzznomatch")
        XCTAssertTrue(app.staticTexts["No matching commands"].waitForExistence(timeout: 5))

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(searchField.waitForExistence(timeout: 2), "Palette should dismiss on Escape")
    }

    /// End-to-end background-build flow: start a rebuild (prefilled from the mock's saved
    /// build context, so no NSOpenPanel is involved), send it to the background, keep using
    /// the app, then find the finished result via the toolbar Builds indicator and reopen
    /// its log. Mock mode: `MockContainerService.buildImage` streams scripted log lines and
    /// succeeds after ~5s, which is what makes the "Succeeded in …" wait deterministic.
    @MainActor
    func testBuildContinuesInBackgroundAndSurfacesInBuildsIndicator() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        // Rebuild a built image whose context the mock has saved — the sheet arrives fully
        // prefilled, so the Build button is enabled without touching a file picker.
        let imagesSidebarItem = app.staticTexts["Images"]
        XCTAssertTrue(imagesSidebarItem.waitForExistence(timeout: 10))
        imagesSidebarItem.click()
        let imageRow = app.staticTexts["local/web:1.4"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10))
        imageRow.click()

        let rebuildButton = app.buttons["Rebuild"]
        XCTAssertTrue(rebuildButton.waitForExistence(timeout: 5))
        rebuildButton.click()

        // Scoped to the sheet: the toolbar has its own "Build" button.
        let sheetBuildButton = app.sheets.firstMatch.buttons["Build"]
        XCTAssertTrue(sheetBuildButton.waitForExistence(timeout: 5), "Rebuild sheet should appear")
        sheetBuildButton.click()

        let backgroundButton = app.buttons["Continue in Background"]
        XCTAssertTrue(backgroundButton.waitForExistence(timeout: 5), "Building state should offer backgrounding")
        backgroundButton.click()

        // The app is free while the build runs: the sheet is gone and the toolbar
        // indicator has taken over tracking the job.
        XCTAssertFalse(app.sheets.firstMatch.exists, "Sheet should close while the build continues")
        let buildsIndicator = app.buttons["buildsIndicator"]
        XCTAssertTrue(buildsIndicator.waitForExistence(timeout: 5))

        buildsIndicator.click()
        // SwiftUI flattens the popover row's texts into its Button's label, e.g.
        // "local/web:1.4, Succeeded in 5s" (confirmed via debugDescription) — there are no
        // separate StaticTexts inside the row to query.
        let successRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "local/web:1.4, Succeeded in")
        ).firstMatch
        XCTAssertTrue(successRow.waitForExistence(timeout: 15), "Finished build should appear in the popover")

        // Reopening the job shows its full log in the sheet. Plain SwiftUI Texts here
        // surface through AXValue, not label (same as the System page's log rows).
        successRow.click()
        func sheetText(_ text: String) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", text, text)).firstMatch
        }
        XCTAssertTrue(sheetText("Build Log").waitForExistence(timeout: 5))
        XCTAssertTrue(sheetText("Image built successfully").exists)
        app.buttons["Done"].click()

        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// A build must survive the main window closing (red button): `BuildJobManager` is owned
    /// by the App, not the window, and the app keeps running via the menu bar extra. Closing
    /// the window mid-build, then reopening it through the menu bar's "Open Berthly", should
    /// land on a Builds indicator that has the finished result waiting.
    @MainActor
    func testBuildSurvivesMainWindowCloseAndResultIsWaitingOnReopen() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        // Same prefilled-rebuild route as the background-build test above.
        let imagesSidebarItem = app.staticTexts["Images"]
        XCTAssertTrue(imagesSidebarItem.waitForExistence(timeout: 10))
        imagesSidebarItem.click()
        let imageRow = app.staticTexts["local/web:1.4"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10))
        imageRow.click()
        let rebuildButton = app.buttons["Rebuild"]
        XCTAssertTrue(rebuildButton.waitForExistence(timeout: 5))
        rebuildButton.click()
        let sheetBuildButton = app.sheets.firstMatch.buttons["Build"]
        XCTAssertTrue(sheetBuildButton.waitForExistence(timeout: 5))
        sheetBuildButton.click()
        let backgroundButton = app.buttons["Continue in Background"]
        XCTAssertTrue(backgroundButton.waitForExistence(timeout: 5))
        backgroundButton.click()

        // Close the main window with the build still running.
        let window = app.windows.firstMatch
        window.buttons[XCUIIdentifierCloseWindow].click()

        // Reopen via the menu bar extra — the only UI left once the window is gone.
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let openBerthly = app.buttons["Open Berthly"]
        XCTAssertTrue(openBerthly.waitForExistence(timeout: 5))
        openBerthly.click()

        // The reopened window's Builds indicator still tracks the same job; the mock build
        // (~5s) finishes within this wait and surfaces as a success row.
        let buildsIndicator = app.buttons["buildsIndicator"]
        XCTAssertTrue(buildsIndicator.waitForExistence(timeout: 10), "Builds indicator should survive window close/reopen")
        buildsIndicator.click()
        let successRow = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "local/web:1.4, Succeeded in")
        ).firstMatch
        XCTAssertTrue(successRow.waitForExistence(timeout: 15), "Finished build should be waiting after the window was closed mid-build")
    }

    // MARK: - Menu Bar Extra

    /// Launches with the mock service and clicks the status item open — every menu bar test
    /// starts here, since `XCUIApplication` traverses every window the app owns, so the
    /// popover's content becomes queryable through the same `app` object once it's open.
    @MainActor
    @discardableResult
    private func launchAndOpenMenuBarExtra() throws -> XCUIApplication {
        let app = XCUIApplication.berthly()
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
        XCTAssertTrue(app.staticTexts["Container Daemon"].exists)
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

        XCTAssertTrue(app.staticTexts["Run Container"].waitForExistence(timeout: 5), "Sheet should open in the main window")
        // Probe with the popover-only daemon stop button, not the "Container Daemon" text —
        // the main window's sidebar status bar shows the same label, so the text would match
        // even with the popover correctly closed.
        XCTAssertFalse(app.buttons["menuBarDaemonStopButton"].exists, "Menu bar popover should close after selecting an action")

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

    /// The daemon stop button acts immediately, same as every container/machine row's own
    /// stop button — no confirmation step, matching `MockContainerService.stopDaemon()`'s
    /// connected → stopping → installedButStopped sequence.
    @MainActor
    func testMenuBarExtraDaemonStopButtonStopsImmediately() throws {
        let app = try launchAndOpenMenuBarExtra()

        let daemonStopButton = app.buttons["menuBarDaemonStopButton"]
        XCTAssertTrue(daemonStopButton.waitForExistence(timeout: 5))
        daemonStopButton.click()

        let daemonStartButton = app.buttons["menuBarDaemonStartButton"]
        XCTAssertTrue(daemonStartButton.waitForExistence(timeout: 5), "Daemon should stop without a confirmation step")
        XCTAssertTrue(app.staticTexts["Container Daemon"].exists, "Popover should stay open after stopping")
    }

    /// Repeated sheet open/close is a classic leak source (an `@Observable` view model or a
    /// `Task` that outlives dismissal), so it's what we churn here rather than idling. Mock mode
    /// keeps this deterministic and fast — it's measuring the cost of the sheet lifecycle itself,
    /// not the real daemon. XCTMemoryMetric/XCTCPUMetric have no built-in pass/fail threshold:
    /// Xcode records a baseline on first run and flags future measurements that regress against
    /// it (Test Report > set baseline), so this needs a baseline set once after landing.
    /// Regression test for a real crash: `TerminalHostView.Coordinator.sizeChanged` used to force-
    /// convert SwiftTerm's initial `newCols`/`newRows` (0, or momentarily negative, before the
    /// zero-framed `TerminalView` is laid out) straight to `UInt16`, which traps. The mock service
    /// can't substitute for a real exec session, but it exercises the exact code path that crashed
    /// — opening the tab is enough to prove the fix without a live daemon.
    @MainActor
    func testTerminalTabOpensWithoutCrashing() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let containerRow = app.staticTexts["web-frontend"]
        XCTAssertTrue(containerRow.waitForExistence(timeout: 10))
        containerRow.click()

        // The detail tabs are a segmented Picker; its segments surface as radio buttons.
        let terminalTab = app.radioButtons["Terminal"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 5))
        terminalTab.click()

        // App must still be alive and responsive after the tab renders and lays out.
        XCTAssertTrue(app.windows.firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testMemoryAndCPUUsageDuringSheetChurn() throws {
        let app = XCUIApplication.berthly()
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

    /// SwiftTerm's `TerminalView` defaults to CoreText/CoreGraphics rendering on macOS (its Metal
    /// path is opt-in via `setUseMetal(_:)`, which `TerminalHostView` never calls), so this is a
    /// CPU-side cost, not GPU — the same reason `XCTCPUMetric`/`XCTMemoryMetric` are the right
    /// metrics here, matching `testMemoryAndCPUUsageDuringSheetChurn` above. Not baselined yet —
    /// per CLAUDE.md, run once in Xcode's Report Navigator and set a baseline before treating a
    /// future regression here as real rather than noise.
    @MainActor
    func testMemoryAndCPUUsageDuringTerminalTabChurn() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        let containerRow = app.staticTexts["web-frontend"]
        XCTAssertTrue(containerRow.waitForExistence(timeout: 10))
        containerRow.click()

        // The detail tabs are a segmented Picker; its segments surface as radio buttons.
        let terminalTab = app.radioButtons["Terminal"]
        let overviewTab = app.radioButtons["Overview"]
        XCTAssertTrue(terminalTab.waitForExistence(timeout: 5))

        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTMemoryMetric(), XCTCPUMetric()], options: options) {
            for _ in 0..<5 {
                terminalTab.click()
                overviewTab.click()
            }
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication.berthly().launch()
        }
    }
}
