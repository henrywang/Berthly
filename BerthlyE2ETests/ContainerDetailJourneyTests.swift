// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

//
//  ContainerDetailJourneyTests.swift
//  BerthlyE2ETests
//
//  Container detail-view journeys added in the 2026-07-18 gap review (PLAN/E2E-TEST.md §6):
//  Copy Files and Log streaming. Split out of BerthlyE2ETests.swift once that file hit the
//  file_length lint ceiling — see BerthlyE2ETests.swift for the suite's style contract and
//  shared helpers (BerthlyE2ETestCase, ContainerCLI, XCUIApplication.berthlyE2E()).
//

import XCTest

/// Copy Files journey (PLAN/E2E-TEST.md §6.1, added 2026-07-18): drives both copy directions
/// through the sheet — host→container and container→host — verified via the CLI/filesystem
/// oracle on each side. No product change was needed: `CopyFilesSheet` already exposes
/// `copyHostPathField`/`copyContainerPathField`/`copyFilesSubmitButton`, and
/// `ContainerDetailView` already exposes `copyFilesButton`; the direction segmented Picker's
/// segments are queried by label (`radioButtons["Out of Container"]`), same as every other
/// segmented control in this suite (e.g. the Terminal/Logs tab picker).
final class CopyFilesJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testCopyFilesBothDirectionsViaSheet() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        let create = try ContainerCLI.run(
            ["run", "-d", "--name", containerName, Self.fixtureImage, "sleep", "300"],
            timeout: 120
        )
        XCTAssertEqual(create.status, 0, "container run failed:\n\(create.output)")

        // Host fixture for the into-container direction; also the destination folder for the
        // out-of-container direction (both sides of the round trip share one temp dir).
        let hostDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-cpctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: hostDir) }
        let inFile = hostDir.appendingPathComponent("in-marker.txt")
        try "into-container-marker".write(to: inFile, atomically: true, encoding: .utf8)

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        let row = app.staticTexts["computeRow-\(containerName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.click()

        // ── 1. Into container: a host file → a container path. ──
        let copyButton = app.buttons["copyFilesButton"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
        copyButton.click()

        typeField(app, inFile.path, into: "copyHostPathField")
        typeField(app, "/tmp/berthly-e2e-in", into: "copyContainerPathField")
        app.buttons["copyFilesSubmitButton"].click()

        let inDone = app.buttons["Done"]
        XCTAssertTrue(inDone.waitForExistence(timeout: 30), "copy into container should succeed")
        inDone.click()

        let inCheck = try ContainerCLI.exec(containerName, ["cat", "/tmp/berthly-e2e-in"])
        XCTAssertTrue(inCheck.output.contains("into-container-marker"),
                      "file copied into the container should be readable:\n\(inCheck.output)")

        // ── 2. Out of container: a container-written file → a host folder. ──
        let outMarker = try ContainerCLI.exec(
            containerName, ["sh", "-c", "echo out-of-container-marker > /tmp/berthly-e2e-out"])
        XCTAssertEqual(outMarker.status, 0,
                       "writing the out-marker inside the container failed:\n\(outMarker.output)")

        copyButton.click()
        let containerPathField = app.windows.textFields["copyContainerPathField"]
        XCTAssertTrue(containerPathField.waitForExistence(timeout: 5), "sheet should reopen")
        // Switching direction clears both fields (CopyFilesSheet.onChange(of: direction)), so the
        // direction must be selected before typing.
        app.radioButtons["Out of Container"].click()

        typeField(app, "/tmp/berthly-e2e-out", into: "copyContainerPathField")
        typeField(app, hostDir.path, into: "copyHostPathField")
        app.buttons["copyFilesSubmitButton"].click()

        let outDone = app.buttons["Done"]
        XCTAssertTrue(outDone.waitForExistence(timeout: 30), "copy out of container should succeed")
        outDone.click()

        // Oracle: resolvedHostDestination appends the container source's last path component to
        // the chosen folder — the file lands at hostDir/berthly-e2e-out, not hostDir itself.
        let landedPath = hostDir.appendingPathComponent("berthly-e2e-out")
        let landed = try String(contentsOf: landedPath, encoding: .utf8)
        XCTAssertTrue(landed.contains("out-of-container-marker"),
                      "the copied-out file should exist on the host with the container's bytes: \(landed)")
    }
}

/// Log streaming journey (PLAN/E2E-TEST.md §6.2, added 2026-07-18): the Logs tab had zero E2E
/// coverage despite being the one path with a known real-daemon-only regression class — the XPC
/// `set(FileHandle)` fd-reuse bug that once surfaced as a spurious "Stream ended" banner (see the
/// `feedback_container_native_api` project memory: a `Pipe` double-close clobbered a reused log
/// fd). Boots a container emitting a unique marker on a loop, opens the Logs tab, and proves both
/// that live stdout actually renders and that the filter field narrows/restores against real
/// streamed data — the mock suite already covers filter *logic*, but only against static lines.
/// Needed one product change: `logFilterField` (nothing else in `LogStreamView` had an
/// identifier besides the source picker).
final class LogStreamJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testContainerLogsStreamIntoLogsTab() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        let marker = "berthly-e2e-log-\(UUID().uuidString.prefix(8).lowercased())"
        let create = try ContainerCLI.run(
            ["run", "-d", "--name", containerName, Self.fixtureImage,
             "sh", "-c", "while true; do echo \(marker); sleep 1; done"],
            timeout: 120
        )
        XCTAssertEqual(create.status, 0, "container run failed:\n\(create.output)")

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        let row = app.staticTexts["computeRow-\(containerName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.click()

        // Segmented tab picker: "Logs" surfaces as a radioButton by label, same as the
        // "Terminal" tab elsewhere in this suite (runInTerminal).
        let logsTab = app.radioButtons["Logs"]
        XCTAssertTrue(logsTab.waitForExistence(timeout: 10))
        logsTab.click()

        // `.textSelection(.enabled)` on the log list (LogStreamView) surfaces each line's text
        // as the accessibility *value*, not the label — confirmed via an xcresult hierarchy dump
        // after a first attempt with `label CONTAINS` alone found nothing despite the marker text
        // being present in the snapshot. Same label-OR-value pattern as the sidebar-observation
        // and System Properties checks elsewhere in this suite.
        func markerText() -> XCUIElement {
            app.staticTexts
                .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", marker, marker))
                .firstMatch
        }

        // ── 1. Live stdout actually renders — the stream-attach + parse + render path. ──
        XCTAssertTrue(markerText().waitForExistence(timeout: 30),
                      "the container's stdout marker should appear in the Logs tab")

        // ── 2. Filter narrows against the real streamed lines, not a static fixture. ──
        let filterField = app.windows.textFields["logFilterField"]
        XCTAssertTrue(filterField.waitForExistence(timeout: 5))
        filterField.click()
        filterField.typeText("berthly-e2e-no-such-marker")
        XCTAssertTrue(markerText().waitForNonExistence(timeout: 10),
                      "an unmatched filter should hide the marker lines")

        // ── 3. Clearing the filter restores them. ──
        filterField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(markerText().waitForExistence(timeout: 10),
                      "clearing the filter should restore the marker lines")
    }
}
