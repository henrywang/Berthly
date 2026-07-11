//
//  BerthlyE2ETests.swift
//  BerthlyE2ETests
//
//  Local-only end-to-end tests against a REAL container daemon. These complement, not
//  replace, the two existing suites: BerthlyTests proves the logic, BerthlyUITests (mock
//  mode) proves the UI wiring, and this target proves the UI actually produces the right
//  daemon behavior — the layer CI can never cover (hosted Apple Silicon runners have no
//  nested virtualization, so the daemon can't boot VMs there).
//
//  Style contract, deliberately different from the mock suite:
//   - Few LONG journey tests, not one test per control — app.launch() is cheap next to a
//     real image pull, and per-control isolation is already covered by mock mode.
//   - The `container` CLI is the assertion oracle: drive via UI, verify via CLI
//     (`ls`/`inspect`), and occasionally the reverse to cover the observation path.
//   - Generous timeouts are FINE here (pull/boot take seconds); this suite trades speed
//     for fidelity and must never become a required gate.
//
//  Run via scripts/e2e.sh (pre-pulls fixtures, sets the BERTHLY_E2E=1 opt-in).
//

import XCTest

final class RunContainerJourneyTests: BerthlyE2ETestCase {

    /// Small, ubiquitous, boring — ideal fixture. Pre-pulled by scripts/e2e.sh.
    private static let fixtureImage = "alpine:latest"

    /// Journey: toolbar Run → popover → Run Container sheet → image + name → submit →
    /// success state → CLI confirms the container exists with the right image → the UI's
    /// own sidebar shows it (CLI-independent observation path).
    ///
    /// Extension points for full-sheet coverage (add as the same journey grows, asserting
    /// each through `container inspect` output rather than through the UI):
    ///  - command override, workdir, user, entrypoint (Process category text fields)
    ///  - cpus / memory / shm-size (Resources)
    ///  - env vars, labels, ports, volumes (add-row lists)
    ///  - the toggle wall: read-only, init, rosetta, ssh, -i/-t, virtualization…
    /// Most of those fields currently have no accessibility identifiers — give them ids in
    /// RunContainerSheet first (like runSubmitButton) instead of querying by placeholder.
    @MainActor
    func testRunContainerFromSheet_containerExistsWithCorrectImage() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        // Real daemon connection takes a moment after launch; the Run button stays
        // disabled until LiveContainerService connects. Wait for enabled, not existence.
        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)
        runButton.click()

        let containerOption = app.buttons["Run Container"]
        XCTAssertTrue(containerOption.waitForExistence(timeout: 5))
        containerOption.click()

        // Image is the first text field; Tab moves focus to Name (same order the mock
        // suite's testReturnSubmitsRunContainerFromAnyField relies on).
        let imageField = app.windows.textFields.firstMatch
        XCTAssertTrue(imageField.waitForExistence(timeout: 5), "Run container sheet should appear")
        imageField.click()
        imageField.typeText(Self.fixtureImage)
        app.typeKey(.tab, modifierFlags: [])
        app.typeText(containerName)

        // Submit by identifier — the button's *label* is "Run"/"Create", which collides
        // with the toolbar button (see CLAUDE.md: identifier-OR-label matching).
        let submitButton = app.buttons["runSubmitButton"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        submitButton.click()

        // Success footer shows "Show Container" once the daemon created (and started) the
        // container. First run on a cold daemon can include VM boot — hence 120s.
        let showContainer = app.buttons["Show Container"]
        XCTAssertTrue(
            showContainer.waitForExistence(timeout: 120),
            "Run should reach the success state; check the sheet's error output if this fails"
        )

        // ── CLI oracle: the daemon really has it, with the right image. ──
        let list = try ContainerCLI.run(["ls", "-a"], timeout: 30)
        XCTAssertEqual(list.status, 0)
        XCTAssertTrue(list.output.contains(containerName),
                      "`container ls -a` should list \(containerName); got:\n\(list.output)")

        let inspect = try ContainerCLI.run(["inspect", containerName], timeout: 30)
        XCTAssertEqual(inspect.status, 0)
        XCTAssertTrue(inspect.output.contains("alpine"),
                      "`container inspect` should show the alpine image; got:\n\(inspect.output)")

        // ── Back through the UI: "Show Container" routes to the sidebar selection, which
        // proves the app *observed* the container it just created (not just fired the call). ──
        showContainer.click()
        let sidebarEntry = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", containerName, containerName))
            .firstMatch
        XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 30),
                      "The new container should surface in the app's own UI")
    }

    /// Reverse direction: create via CLI, assert the UI notices. Covers the refresh /
    /// observation path that the UI-driven journey can't isolate.
    @MainActor
    func testContainerCreatedViaCLI_appearsInSidebar() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let create = try ContainerCLI.run(
            ["create", "--name", containerName, Self.fixtureImage],
            timeout: 120
        )
        XCTAssertEqual(create.status, 0, "container create failed:\n\(create.output)")

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        let sidebarEntry = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", containerName, containerName))
            .firstMatch
        XCTAssertTrue(sidebarEntry.waitForExistence(timeout: 30),
                      "A container created behind the app's back should appear in the sidebar")
    }
}
