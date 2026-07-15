// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Mock-mode coverage for secondary sheets and detail panes reached through a menu, overflow
/// action, or list-row selection rather than a toolbar button: Settings, machine detail/edit/logs,
/// copy/tag/push on containers and images, and the Registries list. Same conventions as
/// BerthlyUITests.swift: `XCUIApplication.berthly()`, `UITEST_USE_MOCK_SERVICE`, Escape/Return key
/// dismissal over coordinate clicks, identifiers over label text where one exists.
///
/// LoadImageSheet and SaveImageSheet are deliberately not covered here: both are gated behind a
/// synchronous NSOpenPanel/NSSavePanel `runModal()` before the sheet body ever renders, and
/// driving native panels from XCUITest is a known flake source for no coverage payoff — a
/// cancel-only interaction would dismiss the panel without the sheet ever appearing.
final class SecondaryViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false

        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killer.arguments = ["-9", "Berthly"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        if (try? killer.run()) != nil {
            killer.waitUntilExit()
        }
    }

    /// Settings lives in a separate NSWindow (SwiftUI `Settings {}` scene, not a sheet) — ⌘,
    /// opens it. Only asserts existence of both tabs; never flips "Launch at login", which calls
    /// the real `SMAppService.mainApp.register()/unregister()` (SettingsView.swift) rather than
    /// anything routed through the mock service — toggling it under test would touch a real
    /// system login-item registration.
    @MainActor
    func testSettingsWindowOpensWithGeneralAndTerminalTabs() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.typeKey(",", modifierFlags: .command)

        // macOS renders a SwiftUI Settings-scene TabView as toolbar buttons, not XCUIElementTypeTab.
        XCTAssertTrue(app.buttons["General"].waitForExistence(timeout: 5), "Settings window should appear with a General tab:\n\(app.debugDescription)")
        XCTAssertTrue(app.buttons["Terminal"].exists)

        app.buttons["Terminal"].click()
        XCTAssertTrue(app.staticTexts["Terminal Theme"].waitForExistence(timeout: 5))

        app.typeKey("w", modifierFlags: .command)
    }

    /// Selecting a machine (Compute is the default sidebar page — no navigation click needed)
    /// opens MachineDetailView's overview, which is otherwise entirely unexercised. "DISK" is a
    /// detail-only section title, mirroring how the existing Volumes/Networks tests assert on
    /// detail-only text rather than a container identifier (see testVolumeSelectionOpensAndSwapsDetailPane).
    @MainActor
    func testMachineSelectionOpensDetailPaneWithDiskSection() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        let machineRow = app.staticTexts["machineRow-dev"]
        XCTAssertTrue(machineRow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["DISK"].exists)

        machineRow.click()
        XCTAssertTrue(app.staticTexts["DISK"].waitForExistence(timeout: 5))
    }

    /// MachineEditSheet ("container machine set" as a form) — reached from the edit button on
    /// MachineDetailView, which only got an accessibilityIdentifier as part of adding this test
    /// (it was previously icon-only with no queryable handle). Applying with a blank-safe CPU
    /// value dismisses the sheet back to the detail pane, since MockContainerService's
    /// updateMachine is instant.
    @MainActor
    func testMachineEditSheetAppliesCpuChange() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let machineRow = app.staticTexts["machineRow-dev"]
        XCTAssertTrue(machineRow.waitForExistence(timeout: 10))
        machineRow.click()

        let editButton = app.buttons["machineEditButton"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 5))
        editButton.click()

        let cpusField = app.textFields["machineEditCpusField"]
        XCTAssertTrue(cpusField.waitForExistence(timeout: 5), "Machine edit sheet should appear")
        cpusField.click()
        cpusField.typeText("4")

        app.buttons["machineEditApplyButton"].click()

        XCTAssertTrue(cpusField.waitForNonExistence(timeout: 5), "Sheet should dismiss back to the detail pane")
        XCTAssertTrue(app.staticTexts["DISK"].waitForExistence(timeout: 5))
    }

    /// The Logs tab's `stream` closure calls `ContainerClient()`/`MachineClient()` directly,
    /// bypassing MockContainerService entirely — there is no mocked log content even under
    /// UITEST_USE_MOCK_SERVICE. The `.task` is async and non-blocking so the toolbar always
    /// renders, but asserting on actual log lines or the "Stream ended"/Copy-enabled state would
    /// depend on whether a real daemon happens to be reachable in this environment. Scoped to
    /// the always-present toolbar controls instead.
    @MainActor
    func testMachineLogsTabShowsStaticControls() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let machineRow = app.staticTexts["machineRow-dev"]
        XCTAssertTrue(machineRow.waitForExistence(timeout: 10))
        machineRow.click()

        let logsTab = app.radioButtons["Logs"]
        XCTAssertTrue(logsTab.waitForExistence(timeout: 5))
        logsTab.click()

        XCTAssertTrue(app.textFields["Filter logs"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Wrap"].exists || app.checkBoxes["Wrap"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["Clear"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(identifier: "logSourcePicker").firstMatch.exists,
            app.debugDescription
        )
    }

    /// CopyFilesSheet, reached from ContainerDetailView's folder-icon button — also previously
    /// icon-only with no queryable handle, and its fields had no accessibility identifiers at
    /// all (both added alongside this test). "web-frontend" is the mock's one running container
    /// with a stable name; the sheet is only offered while running (copyFiles rejects a stopped
    /// container the same way the Terminal tab does).
    @MainActor
    func testCopyFilesSheetCopiesFile() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let containerRow = app.staticTexts["computeRow-web-frontend"]
        XCTAssertTrue(containerRow.waitForExistence(timeout: 10))
        containerRow.click()

        let copyButton = app.buttons["copyFilesButton"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        copyButton.click()

        let hostField = app.textFields["copyHostPathField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "Copy Files sheet should appear")
        hostField.click()
        hostField.typeText("/tmp/example.txt")

        let containerField = app.textFields["copyContainerPathField"]
        containerField.click()
        containerField.typeText("/app/example.txt")

        app.buttons["copyFilesSubmitButton"].click()

        let done = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Copied to", "Copied to")
        ).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Copy should complete via the mocked service:\n\(app.debugDescription)")

        app.typeKey(.return, modifierFlags: [])
    }

    /// TagImageSheet, reached from ImageDetailView's overflow "More Actions" menu. A SwiftUI
    /// `Menu` renders as XCUIElementTypeMenuButton (not `.buttons`), confirmed empirically here —
    /// the plain icon-only `Button` (Rebuild) stays `.buttons`, only the `Menu` control differs.
    /// Menu items don't carry accessibilityIdentifier across the NSMenu bridge (confirmed in
    /// BerthlyE2ETests), so the menu item itself is queried by label.
    @MainActor
    func testTagImageSheetTagsImage() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let imagesSidebarItem = app.staticTexts["Images"]
        XCTAssertTrue(imagesSidebarItem.waitForExistence(timeout: 10))
        imagesSidebarItem.click()
        let imageRow = app.staticTexts["local/web:1.4"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10))
        imageRow.click()

        // A `Menu` (unlike a plain `Button`) renders as XCUIElementTypeMenuButton on macOS.
        let moreActions = app.menuButtons["More Actions"]
        XCTAssertTrue(moreActions.waitForExistence(timeout: 5), app.debugDescription)
        moreActions.click()
        let tagItem = app.menuItems["Tag…"]
        XCTAssertTrue(tagItem.waitForExistence(timeout: 5))
        tagItem.click()

        let targetField = app.textFields["tagTargetField"]
        XCTAssertTrue(targetField.waitForExistence(timeout: 5), "Tag Image sheet should appear")
        targetField.click()
        app.typeKey("a", modifierFlags: .command)
        targetField.typeText("local/web:2.0")

        app.buttons["tagSubmitButton"].click()

        XCTAssertTrue(app.staticTexts["Image tagged"].waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
    }

    /// PushImageSheet, reached from ImageDetailView's labeled "Push" button. The prefilled
    /// destination is the local reference as-is ("local/web:1.4"), which has no registry host —
    /// retargeting to the mock's seeded `ghcr.io` registry both satisfies `canSubmit` (needs a
    /// resolvable host) and exercises the "signed in" branch (MockContainerService seeds
    /// ghcr.io/apple-bot).
    @MainActor
    func testPushImageSheetPushesImage() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let imagesSidebarItem = app.staticTexts["Images"]
        XCTAssertTrue(imagesSidebarItem.waitForExistence(timeout: 10))
        imagesSidebarItem.click()
        let imageRow = app.staticTexts["local/web:1.4"]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 10))
        imageRow.click()

        let pushButton = app.buttons["Push"]
        XCTAssertTrue(pushButton.waitForExistence(timeout: 5))
        pushButton.click()

        let destinationField = app.textFields["pushDestinationField"]
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5), "Push Image sheet should appear")
        destinationField.click()
        app.typeKey("a", modifierFlags: .command)
        destinationField.typeText("ghcr.io/apple-bot/web:1.4")

        app.buttons["pushSubmitButton"].click()

        XCTAssertTrue(app.staticTexts["Image pushed"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
    }

    /// RegistriesListView is a sidebar page, not a sheet — `loadRegistries()` is a no-op over the
    /// mock's two seeded registries, so nothing but navigation is needed to exercise it.
    @MainActor
    func testRegistriesListShowsSeededRegistries() throws {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        let registriesSidebarItem = app.staticTexts["Registries"]
        XCTAssertTrue(registriesSidebarItem.waitForExistence(timeout: 10))
        registriesSidebarItem.click()

        XCTAssertTrue(app.staticTexts["ghcr.io"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["registry-1.docker.io"].exists)
    }
}
