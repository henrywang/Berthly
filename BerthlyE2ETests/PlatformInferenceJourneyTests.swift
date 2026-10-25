// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// #209: Run/Create infer the platform from the image (container 1.6.1, apple/container#2422),
/// like the CLI. Berthly used to pin the host architecture, so an amd64-only image failed with
/// "does not support linux/arm64" unless the Platform field was set.
final class PlatformInferenceJourneyTests: BerthlyE2ETestCase {
    private static let amd64OnlyImage = "amd64/alpine:3.20"

    @MainActor
    func testAmd64OnlyImageRunsWithoutChoosingAPlatform() throws {
        try ContainerCLI.ensureImage(Self.amd64OnlyImage)
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        openRunSheet(app)
        typeField(app, Self.amd64OnlyImage, into: "runImageField")
        typeField(app, containerName, into: "runNameField")
        typeField(app, "sleep 300", into: "runCommandField")
        app.buttons["runSubmitButton"].click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 180),
                      "an amd64-only image should run; sheet:\n\(app.windows.firstMatch.debugDescription)")

        let arch = try ContainerCLI.exec(containerName, ["uname", "-m"])
        XCTAssertEqual(arch.output.trimmingCharacters(in: .whitespacesAndNewlines), "x86_64")
    }

    /// Inference must not move a multi-platform image off the host architecture.
    @MainActor
    func testMultiPlatformImageStillRunsNatively() throws {
        try ContainerCLI.ensureImage("alpine:latest")
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        openRunSheet(app)
        typeField(app, "alpine:latest", into: "runImageField")
        typeField(app, containerName, into: "runNameField")
        typeField(app, "sleep 300", into: "runCommandField")
        app.buttons["runSubmitButton"].click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 120),
                      "alpine should run; sheet:\n\(app.windows.firstMatch.debugDescription)")

        let arch = try ContainerCLI.exec(containerName, ["uname", "-m"])
        XCTAssertEqual(arch.output.trimmingCharacters(in: .whitespacesAndNewlines), "aarch64")
    }
}
