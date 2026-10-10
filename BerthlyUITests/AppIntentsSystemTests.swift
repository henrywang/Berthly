// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

// AppIntentsTesting ships only with Xcode 27, so the Xcode 26 gate compiles this file out.
#if canImport(AppIntentsTesting)
import AppIntentsTesting
import XCTest

/// Runs Berthly's intents through the system (the path Shortcuts and Spotlight use), which the
/// unit tests cannot reach: they call `ComputeIntentActions` directly. Catches missing or renamed
/// intent metadata, a broken entity query, and dependencies not registered at launch.
///
/// Local-only, like BerthlyE2ETests: the system answers only a test runner signed by the app's
/// development team (verified: an ad-hoc runner gets AppIntentsServicesSecurityErrorDomain code
/// 800). CI builds everything ad-hoc (`ci.yml`), so there these tests skip themselves.
@available(macOS 27, *)
final class AppIntentsSystemTests: XCTestCase {
    private let definitions = IntentDefinitions(bundleIdentifier: "app.berthly.Berthly")

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIApplication.terminateRunningBerthly()
    }

    /// The system routes intents to the running Berthly. Launching it in mock mode first keeps
    /// them away from a real daemon, which a system-launched instance would talk to.
    @MainActor
    private func launchMock() -> XCUIApplication {
        let app = XCUIApplication.berthly()
        app.launchEnvironment["UITEST_USE_MOCK_SERVICE"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func worker() async throws -> AnyAppEntity {
        let matches: [AnyAppEntity]
        do {
            matches = try await definitions.entities["ContainerEntity"].entities(matching: "worker")
        } catch let error as NSError where error.domain == "AppIntentsServicesSecurityErrorDomain" && error.code == 800 {
            throw XCTSkip("AppIntentsTesting needs a test runner signed by the app's team; this one is ad-hoc (CI).")
        }
        XCTAssertEqual(matches.count, 1, "The mock seeds exactly one container named worker")
        return try XCTUnwrap(matches.first)
    }

    @MainActor
    func testOpenContainerIntentShowsTheContainerDetail() async throws {
        let app = launchMock()
        let worker = try await worker()

        try await definitions.intents["OpenContainerIntent"].makeIntent(target: worker).run()

        let title = app.staticTexts["containerDetailTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        // SwiftUI exposes this Text through `value`, not `label` (same as LargeInventoryTests).
        XCTAssertEqual(title.value as? String, "worker")
    }

    @MainActor
    func testStartContainerIntentStartsAStoppedContainer() async throws {
        let app = launchMock()
        let worker = try await worker()

        try await definitions.intents["StartContainerIntent"].makeIntent(container: worker).run()
        try await definitions.intents["OpenContainerIntent"].makeIntent(target: worker).run()

        XCTAssertTrue(app.buttons["containerStopButton"].waitForExistence(timeout: 5))
    }
}
#endif
