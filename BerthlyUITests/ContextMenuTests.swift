// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Mock-mode coverage for the right-click context menus on list rows (containers, machines,
/// images, volumes, networks) — previously entirely untested at this layer despite every action
/// each menu offers being reachable through `MockContainerService`. Same conventions as
/// BerthlyUITests.swift/SecondaryViewTests.swift: `XCUIApplication.berthly()`,
/// `UITEST_USE_MOCK_SERVICE`, Escape dismissal over coordinate clicks, identifiers where one
/// exists (`computeRow-`/`machineRow-`), bare exact-text queries elsewhere (image/volume/network
/// rows have none, but resolve the same way `testTagImageSheetTagsImage`/
/// `testVolumeSelectionOpensAndSwapsDetailPane` already rely on).
///
/// Copy actions are verified against `NSPasteboard.general` directly — it's the OS-level system
/// pasteboard, so a value the app process writes is visible to the test-runner process too.
/// `.contextMenu` items don't carry `.accessibilityIdentifier` across the SwiftUI→NSMenu bridge
/// (confirmed in BerthlyE2ETests), so every menu item here is queried by label, matching that
/// suite's `menuItems["Delete…"]` precedent.
final class ContextMenuTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killer.arguments = ["-9", "Berthly"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        if (try? killer.run()) != nil { killer.waitUntilExit() }
    }

    private func launchMock() -> XCUIApplication {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    // MARK: - Containers

    /// Full menu on a running container ("cache" in the mock): lifecycle actions present, Export
    /// Filesystem disabled (only a stopped container's rootfs is exportable), Delete… disabled
    /// (only non-running containers can be deleted). Dismissed with Escape rather than clicked —
    /// a pure existence/gating check, no state change.
    @MainActor
    func testContainerContextMenuOnRunningShowsLifecycleActionsAndGates() throws {
        let app = launchMock()
        let row = app.staticTexts["computeRow-cache"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Restart"].exists)
        XCTAssertTrue(app.menuItems["Force Kill"].exists)
        XCTAssertTrue(app.menuItems["Copy Name"].exists)
        XCTAssertTrue(app.menuItems["Copy Container ID"].exists)
        XCTAssertTrue(app.menuItems["Copy Image Reference"].exists)
        XCTAssertFalse(app.menuItems["Export Filesystem…"].isEnabled, "only a stopped container can export")
        XCTAssertFalse(app.menuItems["Delete…"].isEnabled, "a running container can't be deleted")

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.menuItems["Stop"].waitForNonExistence(timeout: 5))
    }

    /// Same menu on a stopped container ("worker"): Start replaces Stop/Restart/Force Kill, and
    /// Export Filesystem / Delete… both become available.
    @MainActor
    func testContainerContextMenuOnStoppedShowsStartAndEnablesExportAndDelete() throws {
        let app = launchMock()
        let row = app.staticTexts["computeRow-worker"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Stop"].exists)
        XCTAssertTrue(app.menuItems["Export Filesystem…"].isEnabled)
        XCTAssertTrue(app.menuItems["Delete…"].isEnabled)

        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testContainerContextMenuCopyNameWritesToPasteboard() throws {
        let app = launchMock()
        NSPasteboard.general.clearContents()
        let row = app.staticTexts["computeRow-cache"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let copyName = app.menuItems["Copy Name"]
        XCTAssertTrue(copyName.waitForExistence(timeout: 5))
        copyName.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "cache")
    }

    /// Force Kill's real effect: `MockContainerService.killContainer` flips status to stopped —
    /// an observable UI transition, unlike Restart (stop-then-start, a net no-op the mock can't
    /// distinguish from doing nothing; proving restart is a real reboot is the E2E suite's job,
    /// via `/proc/uptime` against a live daemon).
    @MainActor
    func testContainerContextMenuForceKillStopsTheContainer() throws {
        let app = launchMock()
        let row = app.staticTexts["computeRow-cache"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let forceKill = app.menuItems["Force Kill"]
        XCTAssertTrue(forceKill.waitForExistence(timeout: 5))
        forceKill.click()

        // Re-open the menu: Start replacing Stop/Restart/Force Kill proves the transition landed.
        row.rightClick()
        XCTAssertTrue(app.menuItems["Start"].waitForExistence(timeout: 5),
                      "container should be stopped after Force Kill")
    }

    @MainActor
    func testContainerContextMenuDeleteRequiresConfirmation() throws {
        let app = launchMock()
        let row = app.staticTexts["computeRow-edge-proxy"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        let confirm = app.windows.buttons["containerDeleteConfirmButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete must confirm before removing")
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    // MARK: - Machines

    /// "ci-runner" in the mock: stopped, not the default. Start/Set as Default/Delete… all
    /// available.
    @MainActor
    func testMachineContextMenuOnStoppedShowsStartSetDefaultAndDelete() throws {
        let app = launchMock()
        let row = app.staticTexts["machineRow-ci-runner"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Set as Default"].isEnabled, "ci-runner isn't the default yet")
        XCTAssertTrue(app.menuItems["Copy Name"].exists)
        XCTAssertTrue(app.menuItems["Copy Machine ID"].exists)
        XCTAssertTrue(app.menuItems["Delete…"].isEnabled)

        app.typeKey(.escape, modifierFlags: [])
    }

    /// "dev" in the mock: running and already the default. Set as Default and Delete… are both
    /// gated off — the menu explains itself instead of hiding items.
    @MainActor
    func testMachineContextMenuOnRunningDefaultGatesSetDefaultAndDelete() throws {
        let app = launchMock()
        let row = app.staticTexts["machineRow-dev"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Stop"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Set as Default"].isEnabled, "dev is already the default")
        XCTAssertFalse(app.menuItems["Delete…"].isEnabled, "a running machine can't be deleted")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// `setDefaultMachine` grants the badge to exactly one holder, revoking it everywhere else —
    /// re-opening the menu afterward and finding Set as Default disabled proves the badge moved.
    @MainActor
    func testMachineContextMenuSetAsDefaultTransfersTheBadge() throws {
        let app = launchMock()
        let row = app.staticTexts["machineRow-ci-runner"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let setDefault = app.menuItems["Set as Default"]
        XCTAssertTrue(setDefault.waitForExistence(timeout: 5))
        setDefault.click()

        row.rightClick()
        let setDefaultAgain = app.menuItems["Set as Default"]
        XCTAssertTrue(setDefaultAgain.waitForExistence(timeout: 5))
        XCTAssertFalse(setDefaultAgain.isEnabled, "ci-runner should now hold the default badge")
    }

    @MainActor
    func testMachineContextMenuDeleteRequiresConfirmation() throws {
        let app = launchMock()
        let row = app.staticTexts["machineRow-ci-runner"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        let confirm = app.windows.buttons["machineDeleteConfirmButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    // MARK: - Images

    @MainActor
    func testImageContextMenuShowsActionsAndCopiesReference() throws {
        let app = launchMock()
        app.staticTexts["Images"].click()
        let row = app.staticTexts["local/web:1.4"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Run from This Image…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Tag…"].exists)
        XCTAssertTrue(app.menuItems["Save to Disk…"].exists)
        XCTAssertTrue(app.menuItems["Copy Reference"].exists)
        XCTAssertTrue(app.menuItems["Copy Digest"].exists)
        XCTAssertTrue(app.menuItems["Delete…"].exists)

        NSPasteboard.general.clearContents()
        app.menuItems["Copy Reference"].click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "local/web:1.4")
    }

    /// "Run from This Image…" opens RunContainerSheet pre-filled with the image reference —
    /// the row-context-menu path into the Run sheet, distinct from the toolbar Run button
    /// (`testRunSheetOpensAndClosesWithoutCrashing`) which starts with an empty image field.
    @MainActor
    func testImageContextMenuRunFromThisImageOpensRunSheetPrefilled() throws {
        let app = launchMock()
        app.staticTexts["Images"].click()
        let row = app.staticTexts["local/api:2.1"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let runItem = app.menuItems["Run from This Image…"]
        XCTAssertTrue(runItem.waitForExistence(timeout: 5))
        runItem.click()

        let imageField = app.windows.textFields["runImageField"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 5), "Run sheet should appear")
        XCTAssertEqual(imageField.value as? String, "local/api:2.1")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// "local/proxy:1.25" is `.unused` in the mock — deleting it exercises the plain path with
    /// no in-use warning branch to complicate the assertion.
    @MainActor
    func testImageContextMenuDeleteRequiresConfirmation() throws {
        let app = launchMock()
        app.staticTexts["Images"].click()
        let row = app.staticTexts["local/proxy:1.25"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()

        // No identifier on this confirm button (unlike containers/machines) — scoped to the
        // window so a bare buttons["Delete"] can't also match a Touch Bar element.
        let confirm = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    // MARK: - Volumes

    /// "model-cache" is unmounted in the mock (`mounts: []`) — deleting it needs no Terminal/
    /// active-mount cleanup, keeping this a pure context-menu-wiring check.
    @MainActor
    func testVolumeContextMenuShowsActionsAndDeletes() throws {
        let app = launchMock()
        app.staticTexts["Volumes"].click()
        let row = app.staticTexts["model-cache"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Copy Name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Copy Source Path"].exists)
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.exists)
        deleteItem.click()

        let confirm = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }

    // MARK: - Networks

    /// The default network's Delete… stays disabled, not hidden — same discoverable-gate
    /// convention as Export Filesystem/Set as Default elsewhere in this file.
    @MainActor
    func testNetworkContextMenuDeleteIsDisabledForTheDefaultNetwork() throws {
        let app = launchMock()
        app.staticTexts["Networks"].click()
        let row = app.staticTexts["default"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Copy Name"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Delete…"].isEnabled, "the default network can't be deleted")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// FIXED CRASH (2026-07-19), formerly known/skipped — deleting a non-default network row
    /// through its context menu used to deterministically crash the app: AppKit's "layout engine
    /// changed during its own layout pass" exception, thrown re-entrantly from
    /// `OutlineListCoordinator.listTableCellView(_:didUpdateIdealHeight:)` while the row was being
    /// removed. Confirmed not mock-specific (reproduced against a real daemon too) and not
    /// row-specific (both "data-net" and "app-net"). Bisected to `NetworkRow`'s trailing content
    /// swapping view identity on hover (`if isHovered { trashButton } else { chips }`): replacing
    /// it with a `ZStack` + opacity toggle (both branches always mounted, same identity) resolved
    /// it — confirmed clean 3/3 in mock mode and against a real daemon. Why the identical
    /// if/else pattern in `VolumesListView`'s row doesn't hit the same bug is still not
    /// understood, but the fix here is verified rather than theoretical.
    @MainActor
    func testNetworkContextMenuShowsActionsAndDeletes() throws {
        let app = launchMock()
        app.staticTexts["Networks"].click()
        let row = app.staticTexts["data-net"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        XCTAssertTrue(app.menuItems["Copy Subnet"].waitForExistence(timeout: 5))
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.isEnabled)
        deleteItem.click()

        let confirm = app.windows.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }
}
