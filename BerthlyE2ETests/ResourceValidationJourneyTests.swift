// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// container 1.7.1 validates cpus/memory on the client (`Parser.resources`), which Berthly's Run
/// path calls in-process. The Run sheet takes free-text cpus/memory, so this proves the rejection
/// reaches the user as upstream's message — not a generic "operation couldn't be completed" — and
/// that nothing is created.
final class ResourceValidationJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testRunSheetShowsUpstreamResourceLimitErrors() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        let tooManyCPUs = String(ProcessInfo.processInfo.processorCount + 1)
        submitRunSheet(app, field: "runCpusField", value: tooManyCPUs)
        XCTAssertTrue(failureText(app, containing: "cpus must be between 1 and").waitForExistence(timeout: 60),
                      "cpus above the host's cores should show upstream's message:\n\(app.windows.firstMatch.debugDescription)")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["runSubmitButton"].waitForNonExistence(timeout: 10))

        submitRunSheet(app, field: "runMemoryField", value: "100m")
        XCTAssertTrue(failureText(app, containing: "minimum memory amount allowed is 200 MiB").waitForExistence(timeout: 60),
                      "memory under 200 MiB should show upstream's message:\n\(app.windows.firstMatch.debugDescription)")
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertNotEqual(try ContainerCLI.run(["inspect", containerName]).status, 0,
                          "a rejected run must not create the container")
    }

    @MainActor
    private func submitRunSheet(_ app: XCUIApplication, field: String, value: String) {
        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)
        runButton.click()
        let containerOption = app.buttons["Run Container"]
        XCTAssertTrue(containerOption.waitForExistence(timeout: 5))
        containerOption.click()

        type(app, Self.fixtureImage, into: "runImageField")
        type(app, containerName, into: "runNameField")
        app.buttons["runCategory-Resources"].click()
        type(app, value, into: field)

        let submit = app.buttons["runSubmitButton"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.click()
    }

    @MainActor
    private func type(_ app: XCUIApplication, _ text: String, into identifier: String) {
        let field = app.windows.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "field \(identifier) should exist")
        field.click()
        field.typeText(text)
    }

    @MainActor
    private func failureText(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.windows.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", fragment, fragment))
            .firstMatch
    }
}
