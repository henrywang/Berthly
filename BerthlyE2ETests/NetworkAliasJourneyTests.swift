// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import XCTest

/// #207: DNS aliases typed into the Run sheet reach the daemon's attachment configuration and
/// read back into the container detail. Resolution itself needs a default DNS domain (an admin
/// prompt), so the oracle is the stored configuration rather than a lookup.
final class NetworkAliasJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    @MainActor
    func testRunSheetAliasesReachTheDaemonAndShowInDetail() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        openRunSheet(app)
        typeField(app, Self.fixtureImage, into: "runImageField")
        typeField(app, containerName, into: "runNameField")
        typeField(app, "sleep 300", into: "runCommandField")
        app.buttons["runCategory-Network"].click()
        app.buttons["runNetworkAddButton"].click()
        // A subtree alias must sit below the hostname or an exact alias (the daemon's AliasPolicy).
        typeField(app, "api.berthly-e2e.test, gw.berthly-e2e.test .gw.berthly-e2e.test", into: "runNetworkAliasesField")
        app.buttons["runSubmitButton"].click()
        let show = app.buttons["Show Container"]
        XCTAssertTrue(show.waitForExistence(timeout: 120),
                      "container should start; sheet:\n\(app.windows.firstMatch.debugDescription)")

        let json = try ContainerCLI.inspectJSON(containerName)
        let attachments = ContainerCLI.value(at: "configuration.networks", in: json) as? [[String: Any]]
        let aliases = (attachments?.first?["options"] as? [String: Any])?["aliases"] as? [String]
        XCTAssertEqual(aliases, ["api.berthly-e2e.test", "gw.berthly-e2e.test", ".gw.berthly-e2e.test"])

        show.click()
        let expected = "(api.berthly-e2e.test, gw.berthly-e2e.test, .gw.berthly-e2e.test)"
        let networksRow = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expected, expected))
            .firstMatch
        XCTAssertTrue(networksRow.waitForExistence(timeout: 15), "the detail's Networks row should list the aliases")
    }
}
