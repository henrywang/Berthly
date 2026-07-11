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

    /// Tier-1 options journey (PLAN/E2E-TEST.md §1.2): one run with every assertable option
    /// class set through the sheet, verified field-by-field via `container inspect` JSON.
    /// Non-default values throughout, so a silently-dropped flag can't hide behind a default.
    @MainActor
    func testRunOptionsReachDaemon() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        let labelValue = UUID().uuidString.lowercased()

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)
        runButton.click()
        let containerOption = app.buttons["Run Container"]
        XCTAssertTrue(containerOption.waitForExistence(timeout: 5))
        containerOption.click()

        func type(_ text: String, into identifier: String) {
            let field = app.windows.textFields[identifier]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "field \(identifier) should exist")
            field.click()
            field.typeText(text)
        }

        // Header
        type(Self.fixtureImage, into: "runImageField")
        type(containerName, into: "runNameField")

        // General: sleep keeps it running so state/inspect assertions are stable.
        type("sleep 300", into: "runCommandField")

        // Environment: one env var + one label.
        app.buttons["runCategory-Environment"].click()
        app.buttons["runEnvAddButton"].click()
        type("BERTHLY_E2E", into: "runEnvKeyField")
        type("1", into: "runEnvValueField")
        app.buttons["runLabelAddButton"].click()
        type("berthly.e2e", into: "runLabelKeyField")
        type(labelValue, into: "runLabelValueField")

        // Resources: non-default cpu/memory.
        app.buttons["runCategory-Resources"].click()
        type("3", into: "runCpusField")
        type("512m", into: "runMemoryField")

        // Security: exactly one boring boolean inspect can confirm.
        app.buttons["runCategory-Security"].click()
        let readOnlyToggle = app.checkBoxes["runReadOnlyToggle"]
        XCTAssertTrue(readOnlyToggle.waitForExistence(timeout: 5))
        readOnlyToggle.click()

        let submitButton = app.buttons["runSubmitButton"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        submitButton.click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 120),
                      "Run should reach the success state")

        // ── Field-by-field oracle ──
        let json = try ContainerCLI.inspectJSON(containerName)
        let imageRef = ContainerCLI.value(at: "configuration.image.reference", in: json) as? String
        XCTAssertTrue(imageRef?.contains("alpine") == true, "image: \(imageRef ?? "nil")")

        let env = ContainerCLI.value(at: "configuration.initProcess.environment", in: json) as? [String]
        XCTAssertTrue(env?.contains("BERTHLY_E2E=1") == true, "env: \(env ?? [])")

        let labels = ContainerCLI.value(at: "configuration.labels", in: json) as? [String: Any]
        XCTAssertEqual(labels?["berthly.e2e"] as? String, labelValue, "labels: \(labels ?? [:])")

        XCTAssertEqual(ContainerCLI.value(at: "configuration.resources.cpus", in: json) as? Int, 3)
        XCTAssertEqual(ContainerCLI.value(at: "configuration.resources.memoryInBytes", in: json) as? Int,
                       512 * 1024 * 1024)
        XCTAssertEqual(ContainerCLI.value(at: "configuration.readOnly", in: json) as? Bool, true)
        XCTAssertEqual(ContainerCLI.value(at: "status.state", in: json) as? String, "running")
    }

    /// Tier-1 lifecycle journey (PLAN/E2E-TEST.md §1.3): stop/start/delete buttons' real
    /// effect, verified through the CLI after each transition. The container is created via
    /// CLI — this journey tests the lifecycle actions, not the Run sheet.
    @MainActor
    func testContainerLifecycleFromUI() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        let create = try ContainerCLI.run(
            ["run", "-d", "--name", containerName, Self.fixtureImage, "sleep", "300"],
            timeout: 120
        )
        XCTAssertEqual(create.status, 0, "container run failed:\n\(create.output)")

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        // Select the container in the sidebar to open its detail view. The row has its own
        // identifier because the detail view shows the same name once open — an app-wide
        // staticTexts[name] then matches twice ("multiple matching elements" on rightClick),
        // and firstMatch can resolve to the detail title instead of the row. (app.outlines
        // scoping also failed — the SwiftUI sidebar List doesn't surface as an outline here.)
        let row = app.staticTexts["computeRow-\(containerName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.click()

        // Stop from the UI; the Start button replacing Stop marks the observed transition.
        let stopButton = app.buttons["containerStopButton"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 10))
        stopButton.click()
        let startButton = app.buttons["containerStartButton"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 60), "UI should show Start after stopping")
        let stopped = try ContainerCLI.run(["ls"], timeout: 30) // running-only listing
        XCTAssertFalse(stopped.output.contains(containerName), "daemon should report it stopped")

        // Start again; boot can take a while on a cold VM.
        startButton.click()
        XCTAssertTrue(stopButton.waitForExistence(timeout: 120), "UI should show Stop after starting")
        let running = try ContainerCLI.run(["ls"], timeout: 30)
        XCTAssertTrue(running.output.contains(containerName), "daemon should report it running")

        // Stop once more — delete is only offered for stopped containers.
        stopButton.click()
        XCTAssertTrue(startButton.waitForExistence(timeout: 60))

        // Delete via the row's context menu + confirmation alert. Query the menu item by
        // label: .accessibilityIdentifier on a contextMenu Button does NOT survive the
        // SwiftUI→NSMenu bridge (confirmed here — the id query timed out with the menu open).
        // "Delete…" (U+2026) is unique within the menu, and menuItems is already scoped.
        row.rightClick()
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()
        // Scope to the window — bare buttons[…] can also match a Touch Bar phantom.
        let confirm = app.windows.buttons["containerDeleteConfirmButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation alert should appear")
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "row should leave the sidebar")
        let gone = try ContainerCLI.run(["ls", "-a"], timeout: 30)
        XCTAssertFalse(gone.output.contains(containerName), "daemon should no longer know it")
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
