// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

//
//  ImageArchiveJourneyTests.swift
//  BerthlyE2ETests
//
//  Tag → Save → Load round trip, added after a 2026-07-19 scope check found Save/Load's
//  "add a typeable path field" premise was wrong: SaveImageSheet/LoadImageSheet call
//  NSSavePanel/NSOpenPanel via runModal() *before* any sheet exists — there's no form to
//  extend, unlike Build/Copy Files. A real typed-field redesign would trade away the native
//  panel's overwrite confirmation and .tar enforcement for a weak payoff (a save destination
//  genuinely wants a picker, unlike a container-side path). Instead this uses a test-only
//  launch-env seam — UITEST_SAVE_DESTINATION / UITEST_LOAD_SOURCE, checked in
//  promptForArchiveDestination/promptForArchiveToLoad — matching the existing
//  UITEST_USE_MOCK_SERVICE precedent. Real users see no change; only an E2E launch bypasses
//  the panel.
//

import XCTest

final class ImageArchiveJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    /// Tag the fixture image with a fresh, prefixed reference (also new E2E coverage for
    /// TagImageSheet, previously untested at this layer) → Save it to disk through the sheet →
    /// delete the local name via CLI (forcing a real reload, not a no-op) → Load it back through
    /// the sheet → verify the daemon has it again with the SAME digest, and that it actually runs.
    @MainActor
    func testTagSaveDeleteLoadRoundTrip() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let uid = UUID().uuidString.prefix(8).lowercased()
        let typedTag = "\(Self.resourcePrefix)/savetest-\(uid):1"

        let archiveDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-archive-\(uid)")
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archiveDir) }
        let archivePath = archiveDir.appendingPathComponent("image.tar").path

        let app = XCUIApplication.berthlyE2E()
        app.launchEnvironment["UITEST_SAVE_DESTINATION"] = archivePath
        app.launchEnvironment["UITEST_LOAD_SOURCE"] = archivePath
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // ── 1. Tag the fixture image with a fresh, prefixed reference. ──
        let imagesTab = app.staticTexts["Images"]
        XCTAssertTrue(imagesTab.waitForExistence(timeout: 10))
        imagesTab.click()

        // Predicate, not an exact string: the pre-pulled fixture's displayed fullName is the
        // daemon's own reference ("docker.io/library/alpine:latest", not the bare CLI pull
        // argument) — ":latest" excludes any other locally-tagged "alpine:<other>" rows. ImageRow
        // renders fullName as the accessibility *value*, not label (confirmed via an xcresult
        // hierarchy dump after label-only matching found nothing) — same label-OR-value pattern
        // used elsewhere in this suite (LogStreamJourneyTests, SystemViewJourneyTests).
        let alpineRow = app.staticTexts
            .matching(NSPredicate(
                format: "(label CONTAINS 'alpine' OR value CONTAINS 'alpine') "
                      + "AND (label CONTAINS ':latest' OR value CONTAINS ':latest')"))
            .firstMatch
        XCTAssertTrue(alpineRow.waitForExistence(timeout: 15), "alpine:latest should be listed")
        alpineRow.rightClick()
        let tagMenuItem = app.menuItems["Tag…"]
        XCTAssertTrue(tagMenuItem.waitForExistence(timeout: 5))
        tagMenuItem.click()

        let tagField = app.windows.textFields["tagTargetField"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5), "Tag sheet should appear")
        tagField.click()
        app.typeKey("a", modifierFlags: .command)
        tagField.typeText(typedTag)
        app.buttons["tagSubmitButton"].click()
        let tagDone = app.buttons["Done"]
        XCTAssertTrue(tagDone.waitForExistence(timeout: 15), "tag should complete")
        tagDone.click()

        // Discover the daemon-normalized reference via the CLI rather than predicting
        // normalization rules (default registry host, library/ namespace rules by segment count —
        // see LiveContainerService.tagImage's doc comment); `image ls` columns are NAME TAG DIGEST
        // (same parsing ImageArchive's sweepImages already relies on).
        func findTaggedRow() throws -> (name: String, tag: String, digest: String)? {
            let list = try ContainerCLI.run(["image", "ls"], timeout: 20)
            guard let line = list.output.split(separator: "\n").first(where: { $0.contains(uid) }) else { return nil }
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3 else { return nil }
            return (String(cols[0]), String(cols[1]), String(cols[2]))
        }
        guard let taggedBefore = try findTaggedRow() else {
            XCTFail("tagged image should appear in `image ls`"); return
        }
        let taggedReference = "\(taggedBefore.name):\(taggedBefore.tag)"

        // ── 2. Save it to disk through the sheet (native panel bypassed via env var). ──
        let taggedRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", uid, uid))
            .firstMatch
        XCTAssertTrue(taggedRow.waitForExistence(timeout: 10), "tagged image should appear in the sidebar")
        taggedRow.rightClick()
        let saveMenuItem = app.menuItems["Save to Disk…"]
        XCTAssertTrue(saveMenuItem.waitForExistence(timeout: 5))
        saveMenuItem.click()

        // SaveImageSheet starts writing the moment it appears (destination already chosen) —
        // no submit button, just wait for the done state.
        let saveDone = app.buttons["Done"]
        XCTAssertTrue(saveDone.waitForExistence(timeout: 60), "save should complete")
        saveDone.click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath), "archive should be written to disk")

        // ── 3. Delete the local name via CLI — forces a real load, not a no-op. Content bytes
        // may still exist under alpine:latest (same digest), but this specific name is gone. ──
        let delete = try ContainerCLI.run(["image", "delete", taggedReference], timeout: 20)
        XCTAssertEqual(delete.status, 0, "deleting the tagged reference failed:\n\(delete.output)")
        XCTAssertNil(try findTaggedRow(), "tagged reference should be gone before loading")

        // ── 4. Load it back through the sheet (native panel bypassed via env var). ──
        XCTAssertTrue(app.openViaPalette("Load Image from Disk"))
        // LoadImageSheet starts on appear (archiveURL already chosen) — no submit button.
        let loadDone = app.buttons["Done"]
        XCTAssertTrue(loadDone.waitForExistence(timeout: 60), "load should complete")
        loadDone.click()

        // ── Oracle: the reference exists again with the SAME digest — a genuine round trip
        // through the archive, not just "a load succeeded" — and it actually runs. ──
        guard let taggedAfter = try findTaggedRow() else {
            XCTFail("loaded image should reappear in `image ls`"); return
        }
        XCTAssertEqual(taggedAfter.digest, taggedBefore.digest,
                       "the reloaded image should carry the same content digest")

        let run = try ContainerCLI.run(
            ["run", "--rm", "--name", containerName, taggedReference, "echo", "tag-save-load-round-trip"],
            timeout: 120
        )
        XCTAssertTrue(run.output.contains("tag-save-load-round-trip"),
                      "the reloaded image should run:\n\(run.output)")
    }
}
