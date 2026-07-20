// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Mock-mode coverage for the Watchtower-style image-update surface: the staleness badges on
/// image/container rows, the Pull Latest shortcut, and the full recreate flow through
/// `RecreateContainerSheet`. The mock seeds two stale fixtures at launch (`sandbox` = remote
/// update available, `datastore` = newer image pulled but not applied), so every badge assertion
/// is deterministic with no network or clock involved.
///
/// Badges are HStacks/Images whose `.accessibilityIdentifier` is set on the styled container, so
/// they're queried via `descendants(matching: .any)` rather than a concrete element type (SwiftUI
/// reports them as different types on different rows). Context-menu items are label-queried —
/// identifiers don't survive the SwiftUI→NSMenu bridge (ContextMenuTests precedent).
final class RecreateImageUpdateTests: XCTestCase {

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

    private func badge(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    // MARK: - Badges

    /// Both staleness kinds show on their seeded containers, an up-to-date container stays
    /// badge-free, and the Images page shows the update pill plus the Check for Updates control.
    @MainActor
    func testUpdateBadgesShowOnSeededStaleFixtures() throws {
        let app = launchMock()

        XCTAssertTrue(app.staticTexts["computeRow-sandbox"].waitForExistence(timeout: 5))
        XCTAssertTrue(badge(app, "containerUpdateBadge-sandbox").exists, "seeded remote update must badge the row")
        XCTAssertTrue(badge(app, "containerUpdateBadge-datastore").exists, "pulled-but-not-recreated must badge the row")
        XCTAssertFalse(badge(app, "containerUpdateBadge-web-frontend").exists, "an up-to-date container must not")

        app.staticTexts["Images"].click()
        XCTAssertTrue(app.staticTexts["local/base:latest"].waitForExistence(timeout: 5))
        XCTAssertTrue(badge(app, "imageUpdateBadge-local/base:latest").exists)
        XCTAssertFalse(badge(app, "imageUpdateBadge-local/web:1.4").exists)
        XCTAssertTrue(app.buttons["checkImageUpdatesButton"].exists)
    }

    // MARK: - Recreate flow

    /// End-to-end on `datastore` (running, localImageNewer): context menu → confirm sheet →
    /// working phases → done callout → opt-in reclaim → freed size — then the badge is gone and
    /// the container is running again.
    @MainActor
    func testRecreateFlowClearsBadgeAndOffersReclaim() throws {
        let app = launchMock()
        let row = app.staticTexts["computeRow-datastore"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let item = app.menuItems["Recreate with Latest Image…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()

        let submit = app.buttons["recreateSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.click()

        let reclaimButton = app.buttons["reclaimOldImageButton"]
        XCTAssertTrue(reclaimButton.waitForExistence(timeout: 10), "recreate should finish and offer reclaim (digest moved)")
        reclaimButton.click()
        XCTAssertTrue(badge(app, "reclaimFreedLabel").waitForExistence(timeout: 5))

        // Done button binds ⏎; a key event can't race sheet animation coordinates.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["recreateSubmitButton"].waitForNonExistence(timeout: 5))

        XCTAssertTrue(badge(app, "containerUpdateBadge-datastore").waitForNonExistence(timeout: 5),
                      "recreate pins the new digest, so the staleness badge must clear")
        XCTAssertTrue(row.exists, "the recreated container keeps its row")
    }

    /// The pull-then-recreate path on `sandbox` (remote update seeded): the phase label shows
    /// while working, and Cancel disables once the flow crosses into the non-cancellable
    /// replace window (an eventually-true condition — phases always progress in mock mode).
    @MainActor
    func testRecreatePullPhaseDisablesCancelInReplaceWindow() throws {
        let app = launchMock()
        let row = app.staticTexts["computeRow-sandbox"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()

        let item = app.menuItems["Recreate with Latest Image…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()

        let submit = app.buttons["recreateSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.click()

        XCTAssertTrue(app.staticTexts["recreatePhaseLabel"].waitForExistence(timeout: 5))
        let cancel = app.sheets.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.exists)
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: cancel)
        waitForExpectations(timeout: 10)

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(badge(app, "containerUpdateBadge-sandbox").waitForNonExistence(timeout: 5))
    }

    // MARK: - Pull Latest shortcut

    /// "Pull Latest" appears only on an image with a seeded update, and opens the pull sheet
    /// with the reference prefilled.
    @MainActor
    func testPullLatestPrefillsPullSheet() throws {
        let app = launchMock()
        app.staticTexts["Images"].click()

        let current = app.staticTexts["local/web:1.4"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        current.rightClick()
        XCTAssertTrue(app.menuItems["Run from This Image…"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Pull Latest"].exists, "no update seeded for this image")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.menuItems["Run from This Image…"].waitForNonExistence(timeout: 5))

        let stale = app.staticTexts["local/base:latest"]
        XCTAssertTrue(stale.waitForExistence(timeout: 5))
        stale.rightClick()
        let pullLatest = app.menuItems["Pull Latest"]
        XCTAssertTrue(pullLatest.waitForExistence(timeout: 5))
        pullLatest.click()

        let field = app.textFields["pullImageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "local/base:latest")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    }
}
