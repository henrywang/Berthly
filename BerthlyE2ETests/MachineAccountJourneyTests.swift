// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// Machine account journeys (#208) against a real daemon.
final class MachineAccountJourneyTests: BerthlyE2ETestCase {
    /// #208: the Create Machine account fields reach the guest — the account the setup script
    /// creates has the typed name, uid, and home, not the host user's.
    @MainActor
    func testCreateMachineWithCustomAccount() throws {
        try ContainerCLI.ensureImage("alpine:latest")
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        createMachineFromSheet(app, user: "berthlydev", uid: "4242", home: "/home/berthly-e2e-home")
        let createDone = app.buttons["Done"]
        XCTAssertTrue(createDone.waitForExistence(timeout: 240),
                      "machine should create and boot; sheet:\n\(app.windows.firstMatch.debugDescription)")
        createDone.click()

        // Plain arguments only: `machine run` doesn't keep a `sh -c "<command>"` string intact.
        func machineRun(_ command: [String]) throws -> String {
            let result = try ContainerCLI.run(["machine", "run", "-n", machineName, "--"] + command, timeout: 60)
            XCTAssertEqual(result.status, 0, "machine run should succeed:\n\(result.output)")
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(try machineRun(["id", "-un"]), "berthlydev")
        XCTAssertEqual(try machineRun(["id", "-u"]), "4242")
        XCTAssertEqual(try machineRun(["printenv", "HOME"]), "/home/berthly-e2e-home")
    }

    /// #208: an account that clashes with the image (alpine ships `nobody` as uid 65534) makes
    /// the setup script refuse; the sheet must name the account instead of a bare failure.
    @MainActor
    func testCreateMachineWithClashingAccountExplainsTheFailure() throws {
        try ContainerCLI.ensureImage("alpine:latest")
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        createMachineFromSheet(app, user: "nobody", uid: "4242", home: nil)
        let message = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "'nobody' (UID 4242)", "'nobody' (UID 4242)"))
            .firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 240),
                      "the clash should surface with the account named; sheet:\n\(app.windows.firstMatch.debugDescription)")
    }

    private func createMachineFromSheet(_ app: XCUIApplication, user: String, uid: String, home: String?) {
        XCTAssertTrue(app.openViaPalette("Create Machine"))
        let imageField = app.windows.textFields["machineImageField"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 5), "Machine sheet should appear")
        imageField.click(); imageField.typeText("alpine:latest")
        let nameField = app.windows.textFields["machineNameField"]
        nameField.click(); nameField.typeText(machineName)

        app.windows.buttons["machineAdvancedDisclosure"].click()
        XCTAssertTrue(app.windows.textFields["machineUserField"].waitForExistence(timeout: 5))
        // The Advanced section extends past the sheet's capped scroll height.
        app.windows.sheets.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -500)
        let fields = [("machineUserField", user), ("machineUIDField", uid), ("machineHomeField", home)]
        for (identifier, value) in fields {
            guard let value else { continue }
            let field = app.windows.textFields[identifier]
            field.click(); field.typeText(value)
        }
        app.buttons["machineCreateSubmitButton"].click()
    }
}
