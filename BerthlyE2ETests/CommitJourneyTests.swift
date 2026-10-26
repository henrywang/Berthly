// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// #206: Commit to Image against a real daemon. The oracle is a second container run from the
/// committed image: it must see a file written into the source after it started, and run the
/// source's command by default.
final class CommitJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testCommitRunningContainerThenRunTheImage() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        let run = try ContainerCLI.run(
            ["run", "-d", "--name", containerName, Self.fixtureImage, "sleep", "600"], timeout: 120
        )
        XCTAssertEqual(run.status, 0, "fixture container should start:\n\(run.output)")
        let marker = "commit-marker-\(UUID().uuidString.prefix(8))"
        let write = try ContainerCLI.exec(containerName, ["sh", "-c", "echo \(marker) > /\(marker).txt"])
        XCTAssertEqual(write.status, 0, "writing the marker should succeed:\n\(write.output)")

        let reference = "\(Self.resourcePrefix)-commit-\(UUID().uuidString.prefix(8).lowercased()):snap"
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        let row = app.staticTexts["computeRow-\(containerName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.click()
        let commitButton = app.buttons["containerCommitButton"]
        XCTAssertTrue(commitButton.waitForExistence(timeout: 10))
        commitButton.click()

        let field = app.windows.textFields["commitTargetField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Commit sheet should appear")
        field.click()
        app.typeKey("a", modifierFlags: .command)
        field.typeText(reference)
        app.buttons["commitSubmitButton"].click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 180),
                      "commit should finish; sheet:\n\(app.windows.firstMatch.debugDescription)")
        app.buttons["Done"].click()

        let derived = "\(containerName)-from-commit"
        let runCommitted = try ContainerCLI.run(["run", "-d", "--name", derived, reference], timeout: 120)
        XCTAssertEqual(runCommitted.status, 0, "the committed image should run with its default command:\n\(runCommitted.output)")
        let read = try ContainerCLI.exec(derived, ["cat", "/\(marker).txt"])
        XCTAssertEqual(read.output.trimmingCharacters(in: .whitespacesAndNewlines), marker,
                       "the committed image should contain the file written after the source started")
        let cmdline = try ContainerCLI.exec(derived, ["cat", "/proc/1/cmdline"])
        XCTAssertTrue(cmdline.output.contains("sleep"), "PID 1 should be the source's command: \(cmdline.output)")
        // Containers and the prefixed image are swept by tearDown.
    }
}
