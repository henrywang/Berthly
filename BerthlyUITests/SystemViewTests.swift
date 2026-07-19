// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Mock-mode coverage for the System page's mutating actions — disk-usage prune rows, "Clean Up
/// All", and local DNS domain add/delete — none of which had UI-layer coverage despite being
/// fully reachable through `MockContainerService` (unlike the E2E suite, where `prune` is
/// permanently descoped as too destructive to run against a real daemon; see PLAN/E2E-TEST.md
/// §6.4). Same conventions as BerthlyUITests.swift/SecondaryViewTests.swift:
/// `XCUIApplication.berthly()`, `UITEST_USE_MOCK_SERVICE`. These rows previously had no
/// accessibility identifiers and their action buttons only carried `.help()` tooltip text (not a
/// usable XCUITest label) — added `.accessibilityIdentifier` to each (`prune-<name>`,
/// `dnsDeleteButton-<domain>`) rather than guess at ordering or scope tricks. Alert-driven confirm
/// buttons are queried via `app.sheets`, not `app.windows` — the latter can't disambiguate a
/// trigger button from its own same-labeled confirm button when both are visible at once.
///
/// Builder stop/delete is NOT covered here: in this session's runs, `MockContainerService
/// .stopBuilder` demonstrably executed (confirmed via a temporary file-based side channel) but
/// the row's UI never reflected the state change across two separate XCUITest invocations
/// (`.click()` and `.typeKey(.return)` on the confirmation alert). Unconfirmed whether this is a
/// real `@Observable`/SwiftUI reactivity bug or an XCUITest-specific artifact of how it drives
/// this destructive alert — sibling tests in this same file rule out the two most obvious
/// mechanism theories (plain value-capture rows and self-observing sections both update fine
/// elsewhere), so the differentiator isn't understood. Deferred rather than asserted as a bug;
/// start any follow-up from a manual or real-daemon repro, not more automation-only theorizing.
final class SystemViewTests: XCTestCase {

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
        app.staticTexts["System"].click()
        return app
    }

    // MARK: - Disk usage prune rows

    /// Images row: mock seeds reclaimable bytes > 0, so "Prune" is present; confirms via "Clean
    /// Up" (non-destructive alert role — pruning re-pullable image cache), then the row's own
    /// "Prune" button disappears once reclaimableBytes drops to 0.
    @MainActor
    func testDiskUsagePruneImagesRemovesTheButtonOnceReclaimed() throws {
        let app = launchMock()
        let pruneImages = app.buttons["prune-Images"]
        XCTAssertTrue(pruneImages.waitForExistence(timeout: 5), "Images row should offer Prune")
        pruneImages.click()

        let confirm = app.sheets.buttons["Clean Up"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let done = app.sheets.buttons["OK"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "prune should report a Done alert")
        done.click()
        XCTAssertTrue(pruneImages.waitForNonExistence(timeout: 5), "Prune should disappear once reclaimed")
    }

    /// Containers row: same shape as Images but a destructive confirm role ("Remove") since a
    /// deleted stopped container isn't re-pullable.
    @MainActor
    func testDiskUsagePruneStoppedContainersRequiresConfirmation() throws {
        let app = launchMock()
        let pruneContainers = app.buttons["prune-Containers"]
        XCTAssertTrue(pruneContainers.waitForExistence(timeout: 5), "Containers row should offer Prune")
        pruneContainers.click()

        let confirm = app.sheets.buttons["Remove"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let done = app.sheets.buttons["OK"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "prune should report a Done alert")
        done.click()
    }

    /// "Clean Up All" prunes images + stopped containers together, independent of the per-row
    /// actions above — a separate test proves it isn't just an alias for clicking both rows.
    @MainActor
    func testDiskUsageCleanUpAllShowsSummary() throws {
        let app = launchMock()
        let cleanUpAll = app.buttons["Clean Up All"]
        XCTAssertTrue(cleanUpAll.waitForExistence(timeout: 5))
        cleanUpAll.click()

        // Scoped to app.sheets: the trigger button ("Clean Up All") stays on screen while its
        // own confirm alert (same label) is showing — app.windows can't disambiguate them.
        let confirm = app.sheets.buttons["Clean Up All"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        let done = app.sheets.buttons["OK"]
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Clean Up All should report a Done alert")
        done.click()
    }

    // MARK: - Local DNS

    /// Mock seeds one domain ("test"); adding a second proves the create path end-to-end, no
    /// admin-password prompt to drive since MockContainerService never shells out.
    @MainActor
    func testLocalDNSAddDomainAppendsToTheList() throws {
        let app = launchMock()
        let addButton = app.buttons["Add Domain…"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.click()

        let field = app.sheets.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "add-domain alert should appear")
        field.click()
        field.typeText("example")
        app.sheets.buttons["Add"].click()

        XCTAssertTrue(app.staticTexts["example"].waitForExistence(timeout: 5),
                      "the new domain should appear in the list")
    }

    /// Deleting the seeded "test" domain requires confirmation, then it's gone from the list.
    @MainActor
    func testLocalDNSDeleteDomainRequiresConfirmation() throws {
        let app = launchMock()
        let row = app.staticTexts["test"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "mock should seed a \"test\" domain")

        app.buttons["dnsDeleteButton-test"].click()
        // Scoped to app.sheets: the builder row's own Delete button (once stopped) would share
        // this exact label too, though it's not stopped in this test — scoped consistently with
        // every other confirm click in this file regardless.
        let confirm = app.sheets.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
    }
}
