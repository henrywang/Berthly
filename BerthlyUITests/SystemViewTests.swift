// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Mock-mode coverage for the System page's mutating actions — disk-usage prune rows, "Clean Up
/// All", local DNS domain add/delete, and the builder Stop/Start/Delete lifecycle — none of which
/// had UI-layer coverage despite being fully reachable through `MockContainerService` (unlike the
/// E2E suite, where `prune` is permanently descoped as too destructive against a real daemon; see
/// PLAN/E2E-TEST.md §6.4). Same conventions as BerthlyUITests.swift/SecondaryViewTests.swift.
///
/// These rows previously had no accessibility identifiers, only `.help()` tooltip text — and the
/// DNS row and builder row each have their own identically-labeled "Delete" button, both visible
/// at once, so a bare label query for one could silently match the other. Added
/// `.accessibilityIdentifier` to each (`prune-<name>`, `dnsDeleteButton-<domain>`,
/// `builder{Stop,Start,Delete}Button-<id>`) instead. Alert-driven confirm buttons are queried via
/// `app.sheets`, not `app.windows`, which can't disambiguate a trigger from its same-labeled
/// confirm button when both are on screen.
///
/// Builder stop/delete was initially dropped from this file: the row's UI didn't reflect a
/// confirmed-successful model change, and it wasn't clear whether that was a real bug or an
/// XCUITest artifact. The user reproduced it manually — the daemon-side stop succeeded but the UI
/// stayed wrong until navigating away and back — confirming a real SwiftUI reactivity bug:
/// `Builder`'s custom `Equatable` compared only `id`, so `ForEach(service.builders)` never redrew
/// a row whose status changed. Fixed by widening `Builder.==` to include `status` (`Models.swift`,
/// matching the `Container`/`Machine` precedent). The test below is the regression guard.
final class SystemViewTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication.terminateRunningBerthly()
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

    // MARK: - Builder

    /// Regression guard for the Equatable-diffing bug described in this file's header comment.
    /// Exercises the full lifecycle — Stop → Start → Stop → Delete — entirely without navigating
    /// away, since that's exactly the scenario that reproduced the bug (navigating away and back
    /// always "fixed" the display by forcing a full view reconstruction, which would mask a
    /// regression here). Covers both directions of the status flip (Stop *and* Start) since the
    /// fix could plausibly have been one-directional, plus Delete to prove the row is removed
    /// entirely, not just its buttons.
    @MainActor
    func testBuilderLifecycleUpdatesRowWithoutNavigatingAway() throws {
        let app = launchMock()

        let stopButton = app.buttons["builderStopButton-default"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 5), "the mock's running builder should offer Stop")
        stopButton.click()
        let confirmStop = app.sheets.buttons["Stop"]
        XCTAssertTrue(confirmStop.waitForExistence(timeout: 5))
        confirmStop.click()

        let startButton = app.buttons["builderStartButton-default"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10),
                      "builder row should show Start after stopping, without navigating away")
        XCTAssertTrue(app.buttons["builderDeleteButton-default"].exists, "builder row should also show Delete")
        XCTAssertFalse(app.buttons["builderStopButton-default"].exists, "Stop should be gone once stopped")

        // Start: reverses the same status flip, proving the fix isn't one-directional.
        startButton.click()
        XCTAssertTrue(app.buttons["builderStopButton-default"].waitForExistence(timeout: 10),
                      "builder row should show Stop again after starting, without navigating away")
        XCTAssertFalse(app.buttons["builderStartButton-default"].exists, "Start should be gone once running again")
        XCTAssertFalse(app.buttons["builderDeleteButton-default"].exists, "Delete should be gone once running again")

        // Stop once more, then Delete — proves the row is removed entirely, not just its buttons.
        app.buttons["builderStopButton-default"].click()
        app.sheets.buttons["Stop"].click()
        let deleteButton = app.buttons["builderDeleteButton-default"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 10))
        deleteButton.click()
        app.sheets.buttons["Delete"].click()

        // This Text surfaces as accessibility *value*, not label — same gotcha documented
        // elsewhere in this suite (LogStreamView, ImagesListView rows) — so an exact-label
        // query silently never matches even though the text is genuinely there.
        let emptyState = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "No builder found", "No builder found"))
            .firstMatch
        XCTAssertTrue(emptyState.waitForExistence(timeout: 10),
                      "the builder should be gone entirely after deleting the only one")
    }
}
