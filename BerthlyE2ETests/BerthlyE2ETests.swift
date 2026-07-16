// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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

    /// Tier-1 options journey (PLAN/E2E-TEST.md §1.2): drives *every* assertable Run-sheet
    /// option across all seven category tabs, then verifies each field via `container inspect`.
    ///
    /// Uses **Create** (Start immediately OFF), not Run: create stores the full configuration
    /// without booting, so option combinations that wouldn't boot together (e.g. --ssh -i -t
    /// on alpine) still round-trip cleanly. Whether the UI can actually *boot* a container is
    /// covered separately by `testRunContainerFromSheet_containerExistsWithCorrectImage`.
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
        func check(_ identifier: String) {
            let box = app.checkBoxes[identifier]
            XCTAssertTrue(box.waitForExistence(timeout: 5), "toggle \(identifier) should exist")
            box.click()
        }
        func category(_ name: String) { app.buttons["runCategory-\(name)"].click() }

        // Header
        type(Self.fixtureImage, into: "runImageField")
        type(containerName, into: "runNameField")

        // General: Create, not Run — see doc comment. Command tokenizes shell-style, so
        // `-c "sleep 300"` becomes ["-c", "sleep 300"] under the /bin/sh entrypoint below.
        check("runStartImmediatelyToggle")
        type("-c \"sleep 300\"", into: "runCommandField")

        // Storage: a tmpfs mount (bind/volume rows need real host paths — tmpfs covers mounts[]).
        category("Storage")
        app.buttons["runTmpfsAddButton"].click()
        type("/scratch", into: "runTmpfsField")

        // Network: one published port.
        category("Network")
        app.buttons["runPortAddButton"].click()
        type("18080", into: "runPortHostField")
        type("80", into: "runPortContainerField")

        // DNS: server + domain + search.
        category("DNS")
        app.buttons["runDnsAddButton"].click()
        type("1.1.1.1", into: "runDnsField")
        type("corp.test", into: "runDnsDomainField")
        app.buttons["runDnsSearchAddButton"].click()
        type("example.com", into: "runDnsSearchField")

        // Resources: cpus, memory, shm, ulimit.
        category("Resources")
        type("3", into: "runCpusField")
        type("512m", into: "runMemoryField")
        type("64m", into: "runShmSizeField")
        app.buttons["runUlimitAddButton"].click()
        type("nofile=1024:2048", into: "runUlimitField")

        // Environment: env var + label.
        category("Environment")
        app.buttons["runEnvAddButton"].click()
        type("BERTHLY_E2E", into: "runEnvKeyField")
        type("1", into: "runEnvValueField")
        app.buttons["runLabelAddButton"].click()
        type("berthly.e2e", into: "runLabelKeyField")
        type(labelValue, into: "runLabelValueField")

        // Security: text fields, boolean toggles, and capability lists.
        category("Security")
        type("/work", into: "runWorkdirField")
        type("405:406", into: "runUserField")
        type("/bin/sh", into: "runEntrypointField")
        check("runReadOnlyToggle")
        check("runInitProcessToggle")
        check("runSshToggle")
        check("runInteractiveToggle")
        check("runTtyToggle")
        // capAdd represents the capability-list mechanism (StringListEditor, already exercised
        // by tmpfs/dns/ulimit above). capDrop sits at the very bottom of this long ScrollView
        // where its Add button isn't hittable without scrolling; drive capAdd only and assert
        // capDrop stayed empty — a reliable check beats an exhaustive-but-flaky one (CLAUDE.md).
        app.buttons["runCapAddAddButton"].click()
        type("CAP_NET_RAW", into: "runCapAddField")

        let submitButton = app.buttons["runSubmitButton"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 5))
        submitButton.click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 120),
                      "Create should reach the success state")

        // ── Field-by-field oracle (paths verified against a live daemon, apple/container 1.1.0) ──
        let json = try ContainerCLI.inspectJSON(containerName)
        func val(_ path: String) -> Any? { ContainerCLI.value(at: path, in: json) }

        // Image / command / entrypoint / process identity
        XCTAssertTrue((val("configuration.image.reference") as? String)?.contains("alpine") == true)
        XCTAssertEqual(val("configuration.initProcess.arguments") as? [String], ["-c", "sleep 300"])
        XCTAssertEqual(val("configuration.initProcess.executable") as? String, "/bin/sh")
        XCTAssertEqual(val("configuration.initProcess.workingDirectory") as? String, "/work")
        XCTAssertEqual(val("configuration.initProcess.user.raw.userString") as? String, "405:406")

        // Environment / labels
        XCTAssertTrue((val("configuration.initProcess.environment") as? [String])?.contains("BERTHLY_E2E=1") == true)
        XCTAssertEqual((val("configuration.labels") as? [String: Any])?["berthly.e2e"] as? String, labelValue)

        // Resources
        XCTAssertEqual(val("configuration.resources.cpus") as? Int, 3)
        XCTAssertEqual(val("configuration.resources.memoryInBytes") as? Int, 512 * 1024 * 1024)
        XCTAssertEqual(val("configuration.shmSize") as? Int, 64 * 1024 * 1024)
        let rlimits = val("configuration.initProcess.rlimits") as? [[String: Any]]
        XCTAssertTrue(rlimits?.contains { ($0["limit"] as? String) == "RLIMIT_NOFILE"
                                          && ($0["soft"] as? Int) == 1024 && ($0["hard"] as? Int) == 2048 } == true,
                      "rlimits: \(rlimits ?? [])")

        // Boolean toggles (flipped ON → true; rosetta/virtualization left OFF → false proves default)
        XCTAssertEqual(val("configuration.readOnly") as? Bool, true)
        XCTAssertEqual(val("configuration.useInit") as? Bool, true)
        XCTAssertEqual(val("configuration.ssh") as? Bool, true)
        XCTAssertEqual(val("configuration.initProcess.terminal") as? Bool, true) // -i/-t
        XCTAssertEqual(val("configuration.rosetta") as? Bool, false)
        XCTAssertEqual(val("configuration.virtualization") as? Bool, false)

        // Capabilities
        XCTAssertTrue((val("configuration.capAdd") as? [String])?.contains("CAP_NET_RAW") == true)
        XCTAssertEqual((val("configuration.capDrop") as? [String])?.isEmpty, true, "capDrop left unset")

        // DNS
        XCTAssertTrue((val("configuration.dns.nameservers") as? [String])?.contains("1.1.1.1") == true)
        XCTAssertEqual(val("configuration.dns.domain") as? String, "corp.test")
        XCTAssertTrue((val("configuration.dns.searchDomains") as? [String])?.contains("example.com") == true)

        // Published port
        let ports = val("configuration.publishedPorts") as? [[String: Any]]
        XCTAssertTrue(ports?.contains { ($0["hostPort"] as? Int) == 18080 && ($0["containerPort"] as? Int) == 80 } == true,
                      "ports: \(ports ?? [])")

        // tmpfs mount
        let mounts = val("configuration.mounts") as? [[String: Any]]
        XCTAssertTrue(mounts?.contains { ($0["destination"] as? String) == "/scratch" } == true,
                      "mounts: \(mounts ?? [])")
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

    /// Behavioral counterpart to `testRunOptionsReachDaemon`: instead of asserting the daemon
    /// *recorded* the options, this boots a container with a bootable subset set through the
    /// sheet and `container exec`s in to prove each option actually took *effect* — env visible
    /// to a process, working directory applied, running as the given uid, root filesystem truly
    /// read-only. This is the "function checking" the inspect-based test can't do.
    @MainActor
    func testRunOptionsTakeEffectViaExec() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let app = XCUIApplication.berthlyE2E()
        app.launch()

        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)
        runButton.click()
        app.buttons["Run Container"].click()

        func type(_ text: String, into id: String) {
            let field = app.windows.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "field \(id)")
            field.click(); field.typeText(text)
        }

        // Boot ON (default). A bootable set: /tmp and uid 405 don't need a passwd entry, and
        // sleep writes nothing so read-only is fine. (testRunOptionsReachDaemon covers the
        // exhaustive/unbootable option surface via Create.)
        type(Self.fixtureImage, into: "runImageField")
        type(containerName, into: "runNameField")
        type("sleep 300", into: "runCommandField")

        app.buttons["runCategory-Environment"].click()
        app.buttons["runEnvAddButton"].click()
        type("BERTHLY_E2E", into: "runEnvKeyField")
        type("marker-value", into: "runEnvValueField")

        app.buttons["runCategory-Security"].click()
        type("/tmp", into: "runWorkdirField")
        type("405", into: "runUserField")
        app.checkBoxes["runReadOnlyToggle"].click()

        app.buttons["runSubmitButton"].click()
        XCTAssertTrue(app.buttons["Show Container"].waitForExistence(timeout: 120),
                      "container should boot")

        // ── Behavioral oracle: exec into the running container ──
        let env = try ContainerCLI.exec(containerName, ["env"])
        XCTAssertTrue(env.output.contains("BERTHLY_E2E=marker-value"),
                      "env var should be visible to a process:\n\(env.output)")

        let pwd = try ContainerCLI.exec(containerName, ["pwd"])
        XCTAssertEqual(pwd.output.trimmingCharacters(in: .whitespacesAndNewlines), "/tmp",
                       "working directory should be applied")

        let uid = try ContainerCLI.exec(containerName, ["id", "-u"])
        XCTAssertEqual(uid.output.trimmingCharacters(in: .whitespacesAndNewlines), "405",
                       "process should run as the configured uid")

        let write = try ContainerCLI.exec(containerName, ["touch", "/should-fail"])
        XCTAssertNotEqual(write.status, 0, "read-only root filesystem should reject writes")
        XCTAssertTrue(write.output.lowercased().contains("read-only"),
                      "write should fail with a read-only error:\n\(write.output)")
    }
}

/// Machine create + delete through the UI (PLAN/E2E-TEST.md — promoted from the Tier-3
/// defer at the user's request). Kept minimal: one create-then-delete journey, boot OFF.
final class MachineJourneyTests: BerthlyE2ETestCase {
    /// A bootable Linux image the machine subsystem accepts (per `container machine create`'s
    /// own examples). Reuse the distro already present as `fedora-44-machine` to maximise the
    /// image-cache hit — machine images are large, and a cold pull would dominate the runtime.
    private static let machineImage = "fedora:44"

    @MainActor
    func testCreateMachineFromSheetThenDelete() throws {
        let app = XCUIApplication.berthlyE2E()
        app.launch()

        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)
        runButton.click()

        // The Run toolbar popover offers Container vs Machine; take Machine.
        let machineOption = app.buttons["Create Machine"]
        XCTAssertTrue(machineOption.waitForExistence(timeout: 5))
        machineOption.click()

        let imageField = app.windows.textFields["machineImageField"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 5), "Machine create sheet should appear")
        imageField.click()
        imageField.typeText(Self.machineImage)
        let nameField = app.windows.textFields["machineNameField"]
        nameField.click()
        nameField.typeText(machineName)

        // Regression coverage for a real accessibility-click bug (2026-07-16): the "Advanced"
        // disclosure used to never toggle when driven through the accessibility API. Existence-
        // only check via the insecure-registry toggle — never click "Set as default machine",
        // also revealed here, per the comment below about not repointing the developer's real
        // default machine.
        app.buttons["machineAdvancedDisclosure"].click()
        XCTAssertTrue(app.checkBoxes["allowInsecureRegistryToggle"].waitForExistence(timeout: 5),
                      "Advanced section should expand")
        app.buttons["machineAdvancedDisclosure"].click() // collapse again

        // Boot OFF: create the machine config without booting a VM (a Berthly-native path).
        // Keeps the journey fast and off the VM-boot flakiness; booting is out of scope here.
        // Never touch "Set as default machine" — it would repoint the developer's real default.
        let bootToggle = app.checkBoxes["Boot immediately"]
        XCTAssertTrue(bootToggle.waitForExistence(timeout: 5))
        bootToggle.click()

        app.buttons["machineCreateSubmitButton"].click()

        // Image fetch + unpack (no boot) — generous, and surface the sheet on failure.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300),
                      "Machine create should reach success; sheet was:\n\(app.windows.firstMatch.debugDescription)")
        done.click()

        // Oracle: the daemon knows the machine.
        let list = try ContainerCLI.run(["machine", "ls"], timeout: 30)
        XCTAssertTrue(list.output.contains(machineName),
                      "`machine ls` should list \(machineName):\n\(list.output)")

        // Delete via the machine row's context menu + confirmation (same pattern as containers;
        // context-menu item queried by label since ids don't survive the NSMenu bridge).
        let row = app.staticTexts["machineRow-\(machineName)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.rightClick()
        let deleteItem = app.menuItems["Delete…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5))
        deleteItem.click()
        let confirm = app.windows.buttons["machineDeleteConfirmButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "confirmation alert should appear")
        confirm.click()

        XCTAssertTrue(row.waitForNonExistence(timeout: 30), "machine row should leave the sidebar")
        let gone = try ContainerCLI.run(["machine", "ls"], timeout: 30)
        XCTAssertFalse(gone.output.contains(machineName), "daemon should no longer know the machine")
    }

    /// The full "build a machine image, then actually boot a machine from it" journey the
    /// simpler boot-off test can't do. A machine needs an init-enabled rootfs (a plain distro
    /// image lacks one and won't boot), so this builds a systemd-enabled Fedora image through
    /// the Build sheet, then creates a machine from it through the Create Machine sheet with
    /// **boot ON** and non-default cpus/memory, and proves the machine reached the *running*
    /// state — a plain image would fail to boot.
    ///
    /// Heavy: the image build is minutes on a cold cache (dnf update + install systemd) and the
    /// boot adds more. Fine for a local opt-in suite; the build layers cache across runs.
    @MainActor
    func testBuildMachineImageThenBootMachine() throws {
        // systemd-enabled Fedora — a bootable machine image (per apple/container's own machine
        // image recipe). The trimming RUN is one line to avoid Swift multiline `\`-continuation.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-mctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dockerfile = """
        FROM quay.io/fedora/fedora:44
        RUN dnf update -y && dnf install -y systemd
        RUN (cd /lib/systemd/system/sysinit.target.wants/; for i in *; do [ $i == systemd-tmpfiles-setup.service ] || rm -f $i; done); rm -f /lib/systemd/system/multi-user.target.wants/*; rm -f /etc/systemd/system/*.wants/*; rm -f /lib/systemd/system/local-fs.target.wants/*; rm -f /lib/systemd/system/sockets.target.wants/*udev*; rm -f /lib/systemd/system/sockets.target.wants/*initctl*; rm -f /lib/systemd/system/basic.target.wants/*; rm -f /lib/systemd/system/anaconda.target.wants/*;
        VOLUME [ "/sys/fs/cgroup" ]
        CMD ["/usr/sbin/init"]
        """
        try dockerfile.write(to: dir.appendingPathComponent("Dockerfile"),
                             atomically: true, encoding: .utf8)
        let tag = "\(Self.resourcePrefix)/machine-\(UUID().uuidString.prefix(8).lowercased()):1"

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // ── 1. Build the machine image through the Build sheet. ──
        XCTAssertTrue(app.openViaPalette("Build Image"))
        let tagField = app.windows.textFields["buildTagField"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5), "Build sheet should appear")
        tagField.click(); tagField.typeText(tag)
        let ctxField = app.windows.textFields["buildContextField"]
        ctxField.click(); ctxField.typeText(dir.path)
        app.buttons["buildSubmitButton"].click()
        // Cold: dnf update + install systemd. Generous.
        let buildDone = app.buttons["Done"]
        XCTAssertTrue(buildDone.waitForExistence(timeout: 900),
                      "machine image build should succeed; sheet:\n\(app.windows.firstMatch.debugDescription)")
        buildDone.click()
        XCTAssertEqual(try ContainerCLI.run(["image", "inspect", tag]).status, 0,
                       "built machine image should be present")

        // ── 2. Create + boot a machine from the built image, with non-default resources. ──
        XCTAssertTrue(app.openViaPalette("Create Machine"))
        let imageField = app.windows.textFields["machineImageField"]
        XCTAssertTrue(imageField.waitForExistence(timeout: 5), "Machine sheet should appear")
        imageField.click(); imageField.typeText(tag)
        let nameField = app.windows.textFields["machineNameField"]
        nameField.click(); nameField.typeText(machineName)
        // "More options": override the default cpus/memory. Boot immediately stays ON.
        let cpusField = app.windows.textFields["machineCpusField"]
        cpusField.click(); cpusField.typeText("2")
        let memoryField = app.windows.textFields["machineMemoryField"]
        memoryField.click(); memoryField.typeText("4G")
        app.buttons["machineCreateSubmitButton"].click()

        // Boot ON → success only after the VM boots. Very generous.
        let createDone = app.buttons["Done"]
        XCTAssertTrue(createDone.waitForExistence(timeout: 600),
                      "machine should create and boot; sheet:\n\(app.windows.firstMatch.debugDescription)")
        createDone.click()

        // ── Oracle: the daemon shows the machine RUNNING with the resources we set. A plain
        // (non-init) image would never reach running — that's the function check. Poll: under
        // full-suite load the daemon's `machine ls` can lag a beat behind the sheet's "Done". ──
        var rowLine: Substring?
        let deadline = Date(timeIntervalSinceNow: 60)
        repeat {
            let list = try ContainerCLI.run(["machine", "ls"], timeout: 30)
            rowLine = list.output.split(separator: "\n").first { $0.contains(machineName) }
            if rowLine?.contains("running") == true { break }
            Thread.sleep(forTimeInterval: 2)
        } while Date() < deadline
        XCTAssertNotNil(rowLine, "machine should be listed")
        XCTAssertTrue(rowLine?.contains("running") == true, "machine should be running: \(rowLine ?? "")")
        XCTAssertTrue(rowLine?.contains("4G") == true, "memory override should apply: \(rowLine ?? "")")
        // machine (stop+delete) and image swept by prefix in tearDown.
    }
}

/// Resource journeys (PLAN/E2E-TEST.md Tier 2): create a real resource through its sheet,
/// confirm via the CLI, then *use* it to prove it actually works — the create-then-use
/// pattern. Each opens its sheet through the ⌘K command palette for a uniform entry point.
final class ResourceJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"

    /// Pull an image through the Pull sheet, then run a container from it — proving the pulled
    /// image is not just listed but functional.
    @MainActor
    func testPullImageFromSheetThenRun() throws {
        // A small, pinned, unlikely-to-be-in-active-use tag. Force a real registry pull by
        // removing it first; restore the machine's prior state in cleanup.
        let ref = "busybox:1.36"
        let hadItBefore = (try? ContainerCLI.run(["image", "inspect", ref]))?.status == 0
        _ = try? ContainerCLI.run(["image", "delete", ref])
        defer { if !hadItBefore { _ = try? ContainerCLI.run(["image", "delete", ref]) } }

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        XCTAssertTrue(app.openViaPalette("Pull Image"), "command palette should open")
        let field = app.windows.textFields["pullImageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Pull sheet should appear")
        field.click(); field.typeText(ref)
        app.buttons["pullSubmitButton"].click()

        // Registry pull → generous timeout; success shows a Done button.
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300),
                      "pull should complete; sheet:\n\(app.windows.firstMatch.debugDescription)")
        done.click()

        // Oracle: the daemon has the image.
        XCTAssertEqual(try ContainerCLI.run(["image", "inspect", ref]).status, 0,
                       "pulled image should be present")

        // Behavioral: the pulled image actually runs.
        let out = try ContainerCLI.run(
            ["run", "--rm", "--name", containerName, ref, "echo", "pulled-and-running"],
            timeout: 120
        )
        XCTAssertTrue(out.output.contains("pulled-and-running"),
                      "a container from the pulled image should run:\n\(out.output)")
    }

    /// Create a volume through the sheet, then prove it's a real shared volume: write into it
    /// from one container, read the same bytes back from another.
    /// Create a volume through its sheet, attach it to a container through the Run sheet's
    /// Storage editor (UI, not `-v`), then use the *Terminal* to write into the mount — and
    /// prove it's the real shared named volume by reading the same bytes from a second
    /// container. Exercises: volume-create sheet, Run-sheet volume attach, and the terminal.
    @MainActor
    func testVolumeAttachedViaUIVerifiedInTerminal() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // 1. Create the volume through its sheet.
        XCTAssertTrue(app.openViaPalette("Create Volume"))
        let volNameField = app.windows.textFields["volumeNameField"]
        XCTAssertTrue(volNameField.waitForExistence(timeout: 5), "Volume sheet should appear")
        volNameField.click(); volNameField.typeText(volumeName)
        let volSubmit = app.buttons["volumeCreateSubmitButton"]
        volSubmit.click()
        XCTAssertTrue(volSubmit.waitForNonExistence(timeout: 15), "volume sheet should close on success")
        XCTAssertTrue(try ContainerCLI.run(["volume", "ls"]).output.contains(volumeName), "volume listed")

        // 2. Run a container attaching the volume through the Run sheet's Storage editor.
        openRunSheet(app)
        typeField(app, Self.fixtureImage, into: "runImageField")
        typeField(app, containerName, into: "runNameField")
        typeField(app, "sleep 300", into: "runCommandField")
        app.buttons["runCategory-Storage"].click()
        app.buttons["runVolumeAddButton"].click()
        typeField(app, "\(volumeName):/data", into: "runVolumeField")
        app.buttons["runSubmitButton"].click()
        let show = app.buttons["Show Container"]
        XCTAssertTrue(show.waitForExistence(timeout: 120), "container should boot with the volume attached")

        // Inspect confirms the UI attached the named volume at /data (source is the volume's image).
        let json = try ContainerCLI.inspectJSON(containerName)
        let mounts = ContainerCLI.value(at: "configuration.mounts", in: json) as? [[String: Any]]
        XCTAssertTrue(mounts?.contains { ($0["destination"] as? String) == "/data"
                                         && (($0["source"] as? String)?.contains(volumeName) ?? false) } == true,
                      "the named volume should be mounted at /data: \(mounts ?? [])")
        show.click() // navigate to the container's detail view

        // 3. Write into the mount via the Terminal.
        XCTAssertTrue(runInTerminal(app, container: containerName,
                                    command: "echo shared-payload > /data/f", awaitFile: "/data/f"),
                      "terminal write into the mounted volume should land")

        // 4. Prove the bytes persisted in the named volume itself: stop this container (a volume
        // image can only attach to one running VM at a time — a *concurrent* second mount fails
        // with "storage device attachment is invalid"), then read it back from a fresh container.
        _ = try ContainerCLI.run(["stop", containerName], timeout: 60)
        let read = try ContainerCLI.run(
            ["run", "--rm", "--name", "\(containerName)-r", "-v", "\(volumeName):/data",
             Self.fixtureImage, "cat", "/data/f"], timeout: 120)
        XCTAssertTrue(read.output.contains("shared-payload"),
                      "a fresh container mounting the volume should read what the terminal wrote:\n\(read.output)")
    }

    /// Create a network through its sheet, attach it to a container through the Run sheet's
    /// Network *select menu* (the Picker — new coverage), confirm via inspect, then use the
    /// Terminal to capture the interface and read it back. Exercises: network-create sheet,
    /// the Run-sheet network Picker, and the terminal.
    @MainActor
    func testNetworkAttachedViaUIVerifiedInTerminal() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        // 1. Create the network through its sheet.
        XCTAssertTrue(app.openViaPalette("Create Network"))
        let netNameField = app.windows.textFields["networkNameField"]
        XCTAssertTrue(netNameField.waitForExistence(timeout: 5), "Network sheet should appear")
        netNameField.click(); netNameField.typeText(networkName)
        let netSubmit = app.buttons["networkCreateSubmitButton"]
        netSubmit.click()
        XCTAssertTrue(netSubmit.waitForNonExistence(timeout: 15), "network sheet should close on success")
        XCTAssertTrue(try ContainerCLI.run(["network", "ls"]).output.contains(networkName), "network listed")

        // 2. Run a container attaching the network through the Run sheet's Network select menu.
        openRunSheet(app)
        typeField(app, Self.fixtureImage, into: "runImageField")
        typeField(app, containerName, into: "runNameField")
        typeField(app, "sleep 300", into: "runCommandField")
        app.buttons["runCategory-Network"].click()
        app.buttons["runNetworkAddButton"].click()
        // The Picker is an NSPopUpButton on macOS: click it, then pick our network by name
        // (the just-created network appears because the create refreshed service.networks).
        let picker = app.windows.popUpButtons["runNetworkPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "network picker should appear")
        picker.click()
        let item = app.menuItems[networkName]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "created network should be selectable in the menu")
        item.click()
        app.buttons["runSubmitButton"].click()
        let show = app.buttons["Show Container"]
        XCTAssertTrue(show.waitForExistence(timeout: 120), "container should boot on the network")

        // Inspect confirms the UI select attached the right network.
        let json = try ContainerCLI.inspectJSON(containerName)
        let nets = (ContainerCLI.value(at: "configuration.networks", in: json) as? [[String: Any]])?
            .compactMap { $0["network"] as? String }
        XCTAssertTrue(nets?.contains(networkName) == true, "inspect should show the selected network: \(nets ?? [])")
        show.click()

        // 3. Capture the interface via the Terminal, then read the captured file back.
        XCTAssertTrue(runInTerminal(app, container: containerName,
                                    command: "ip -o -4 addr show eth0 > /berthly-e2e-net",
                                    awaitFile: "/berthly-e2e-net"),
                      "terminal command capturing the interface should run")
        let addr = try ContainerCLI.exec(containerName, ["cat", "/berthly-e2e-net"])
        XCTAssertTrue(addr.output.contains("inet "),
                      "the container should have an IPv4 address on the attached network:\n\(addr.output)")
    }

    /// Build an image through the Build sheet from a runtime-written Dockerfile, then run it and
    /// exec to read a file the build baked in — proving the built image is real and functional.
    /// The build context is typed into the field added for this (no NSOpenPanel to drive).
    @MainActor
    func testBuildImageFromDockerfileThenRun() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)

        // Runtime fixture: a temp dir with a trivial Dockerfile (avoids bundling questions).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-ctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dockerfile = """
        FROM alpine:latest
        RUN echo built-by-e2e > /berthly-e2e-marker
        LABEL berthly.e2e=build
        """
        try dockerfile.write(to: dir.appendingPathComponent("Dockerfile"),
                             atomically: true, encoding: .utf8)
        let tag = "\(Self.resourcePrefix)/img-\(UUID().uuidString.prefix(8).lowercased()):1"

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        XCTAssertTrue(app.openViaPalette("Build Image"))
        let tagField = app.windows.textFields["buildTagField"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5), "Build sheet should appear")
        tagField.click(); tagField.typeText(tag)
        let ctxField = app.windows.textFields["buildContextField"]
        ctxField.click(); ctxField.typeText(dir.path)

        // Regression coverage for a real accessibility-click bug (2026-07-16): the "Advanced"
        // disclosure used to never toggle when driven through the accessibility API — same input
        // path assistive technology uses — because of a DisclosureGroup initializer quirk. Expand
        // it and confirm a field inside actually appears.
        app.buttons["buildAdvancedDisclosure"].click()
        XCTAssertTrue(app.windows.textFields["buildTargetField"].waitForExistence(timeout: 5),
                      "Advanced section should expand")
        app.buttons["buildAdvancedDisclosure"].click() // collapse again

        app.buttons["buildSubmitButton"].click()
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 300),
                      "build should succeed; sheet:\n\(app.windows.firstMatch.debugDescription)")
        done.click()

        // Oracle: the image exists.
        XCTAssertEqual(try ContainerCLI.run(["image", "inspect", tag]).status, 0,
                       "built image should be present")

        // Behavioral: run it and read the file the build wrote.
        let out = try ContainerCLI.run(
            ["run", "--rm", "--name", containerName, tag, "cat", "/berthly-e2e-marker"],
            timeout: 120)
        XCTAssertTrue(out.output.contains("built-by-e2e"),
                      "the built image should carry what the Dockerfile baked in:\n\(out.output)")
        // image (berthly-e2e/…) swept by prefix in tearDown.
    }
}

/// Registry journey (user-suggested, 2026-07-16): stands up a real, self-hosted, *anonymous*
/// registry (`registry:latest`) as fixture infra, then drives build → push → pull through the
/// UI against it. This closes two real gaps: Push had zero E2E coverage before this, and
/// PLAN/E2E-TEST.md's Tier 3 had descoped "Registries" entirely because a credentialed test
/// needs real secrets — a local, unauthenticated registry sidesteps that specific objection for
/// the anonymous push/pull case (credentialed sign-in stays descoped for the same reason: it
/// would need real secrets in a local test suite).
final class RegistryJourneyTests: BerthlyE2ETestCase {
    private static let fixtureImage = "alpine:latest"
    private static let registryImage = "registry:latest"
    /// Arbitrary, uncommon high port — avoids macOS's own AirPlay Receiver (5000/7000) and
    /// anything else plausibly already listening on a dev machine.
    private static let registryPort = 18581

    private var registryName: String { "\(Self.resourcePrefix)-registry" }

    /// Build a marker image → push it to the local registry (Advanced → Allow insecure registry,
    /// never signing in anywhere) → delete every local copy → pull it back the same way → run it
    /// and read the marker back out. Each half also proves the insecure toggle is *causally*
    /// required, not cosmetic: submitting first with the toggle off is left to run against the
    /// HTTP-only registry, which a CLI spike confirmed fails deterministically (~43s, a real TLS
    /// protocol mismatch — "bad protocol version" — not a stall), before retrying with it on.
    @MainActor
    func testBuildPushPullRoundTripThroughLocalInsecureRegistry() throws {
        try ContainerCLI.ensureImage(Self.fixtureImage)
        try ContainerCLI.ensureImage(Self.registryImage)

        // ── 1. Stand up the registry — fixture infra via CLI, not the feature under test
        // (matches the create-via-CLI precedent used elsewhere in this suite). ──
        let run = try ContainerCLI.run(
            ["run", "-d", "--name", registryName, "-p", "\(Self.registryPort):5000", Self.registryImage],
            timeout: 60
        )
        XCTAssertEqual(run.status, 0, "starting the local registry failed:\n\(run.output)")
        try waitForRegistryReady()

        let ref = "localhost:\(Self.registryPort)/berthly-e2e/regtest:1"

        // ── 2. Build a marker image through the Build sheet (same pattern as
        // testBuildImageFromDockerfileThenRun). ──
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.resourcePrefix)-regctx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dockerfile = """
        FROM alpine:latest
        RUN echo registry-round-trip > /berthly-e2e-marker
        """
        try dockerfile.write(to: dir.appendingPathComponent("Dockerfile"),
                             atomically: true, encoding: .utf8)
        let localTag = "\(Self.resourcePrefix)/regtest-\(UUID().uuidString.prefix(8).lowercased()):1"

        let app = XCUIApplication.berthlyE2E()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        XCTAssertTrue(app.openViaPalette("Build Image"))
        let tagField = app.windows.textFields["buildTagField"]
        XCTAssertTrue(tagField.waitForExistence(timeout: 5), "Build sheet should appear")
        tagField.click(); tagField.typeText(localTag)
        let ctxField = app.windows.textFields["buildContextField"]
        ctxField.click(); ctxField.typeText(dir.path)
        app.buttons["buildSubmitButton"].click()
        let buildDone = app.buttons["Done"]
        XCTAssertTrue(buildDone.waitForExistence(timeout: 300),
                      "build should succeed; sheet:\n\(app.windows.firstMatch.debugDescription)")
        buildDone.click()

        // ── 3. Open the built image's Push sheet from the Images sidebar. ──
        let imagesTab = app.staticTexts["Images"]
        XCTAssertTrue(imagesTab.waitForExistence(timeout: 10))
        imagesTab.click()
        let imageRow = app.staticTexts[localTag]
        XCTAssertTrue(imageRow.waitForExistence(timeout: 15), "built image should appear in the sidebar")
        imageRow.click()
        let pushButton = app.buttons["Push"]
        XCTAssertTrue(pushButton.waitForExistence(timeout: 10))
        pushButton.click()

        let destField = app.windows.textFields["pushDestinationField"]
        XCTAssertTrue(destField.waitForExistence(timeout: 5), "Push sheet should appear")
        // Field arrives pre-filled with the local reference; select all and replace.
        destField.click()
        app.typeKey("a", modifierFlags: .command)
        destField.typeText(ref)

        expandAdvancedSection(app, revealing: "allowInsecureRegistryToggle")
        let pushInsecureToggle = app.checkBoxes["allowInsecureRegistryToggle"]

        // ── 4. Negative: plain HTTPS push against an HTTP-only registry must fail. ──
        let pushSubmit = app.buttons["pushSubmitButton"]
        XCTAssertTrue(pushSubmit.waitForExistence(timeout: 5))
        pushSubmit.click()
        XCTAssertTrue(pushSubmit.waitForNonExistence(timeout: 10), "push should leave idle once submitted")
        XCTAssertTrue(pushSubmit.waitForExistence(timeout: 90),
                      "push without the insecure toggle should fail and return to idle")
        XCTAssertFalse(app.buttons["Done"].exists, "push should not succeed without the insecure toggle")

        // ── 5. Positive: toggle on, never having signed in anywhere — proves anonymous push
        // against an unauthenticated registry needs zero credentials. ──
        pushInsecureToggle.click()
        pushSubmit.click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 60),
                      "push should succeed with the insecure toggle on and no registry credentials")
        app.buttons["Done"].click()

        // ── 6. Force a real network pull: delete every local copy of the pushed reference. ──
        _ = try ContainerCLI.run(["image", "delete", ref])
        _ = try ContainerCLI.run(["image", "delete", localTag])

        // ── 7. Pull it back — same negative-then-positive proof, on the Pull sheet. ──
        XCTAssertTrue(app.openViaPalette("Pull Image"))
        let pullField = app.windows.textFields["pullImageField"]
        XCTAssertTrue(pullField.waitForExistence(timeout: 5), "Pull sheet should appear")
        pullField.click(); pullField.typeText(ref)

        expandAdvancedSection(app, revealing: "allowInsecureRegistryToggle")
        let pullInsecureToggle = app.checkBoxes["allowInsecureRegistryToggle"]

        let pullSubmit = app.buttons["pullSubmitButton"]
        pullSubmit.click()
        XCTAssertTrue(pullSubmit.waitForNonExistence(timeout: 10), "pull should leave idle once submitted")
        XCTAssertTrue(pullSubmit.waitForExistence(timeout: 90),
                      "pull without the insecure toggle should fail and return to idle")
        XCTAssertFalse(app.buttons["Done"].exists, "pull should not succeed without the insecure toggle")

        pullInsecureToggle.click()
        pullSubmit.click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 60),
                      "pull should succeed with the insecure toggle on")

        // ── Oracle: the pulled bytes are the SAME image that was built and pushed — a genuine
        // round trip through the registry, not just "a pull succeeded". ──
        let out = try ContainerCLI.run(
            ["run", "--rm", "--name", containerName, ref, "cat", "/berthly-e2e-marker"],
            timeout: 120
        )
        XCTAssertTrue(out.output.contains("registry-round-trip"),
                      "the pulled image should carry what the build baked in:\n\(out.output)")
        // registry container and berthly-e2e/… images swept by prefix in tearDown.
    }

    /// Polls the freshly-started registry until it accepts pushes. `container run -d` returning
    /// doesn't mean the distribution server inside has bound its port yet; retries a real (cheap,
    /// already-local) push rather than an HTTP probe, since that's the exact path the journey
    /// itself exercises.
    private func waitForRegistryReady(timeout: TimeInterval = 30) throws {
        let probeRef = "localhost:\(Self.registryPort)/berthly-e2e/ready-probe:1"
        _ = try ContainerCLI.run(["image", "tag", Self.fixtureImage, probeRef])
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            if (try? ContainerCLI.run(["image", "push", "--scheme", "http", probeRef], timeout: 10))?.status == 0 {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw XCTSkip("local registry on port \(Self.registryPort) never became ready")
    }
}

/// Regression coverage for the same "Advanced"-style accessibility-click bug (2026-07-16, see
/// `SheetAdvancedSection` in SheetChrome.swift) in `SystemPropertiesSection`'s own hand-rolled
/// disclosure — a `Section` inside a `Form`, not a sheet, so it's covered separately here rather
/// than folded into one of the sheet journeys above.
final class SystemViewJourneyTests: BerthlyE2ETestCase {
    @MainActor
    func testSystemPropertiesDisclosureExpands() throws {
        let app = XCUIApplication.berthlyE2E()
        app.launch()
        let systemTab = app.staticTexts["System"]
        XCTAssertTrue(systemTab.waitForExistence(timeout: 15))
        systemTab.click()
        let disclosure = app.buttons["systemPropertiesDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 15), "Properties disclosure should exist")
        disclosure.click()
        // Rows render their key as the row's accessibility *value*, not label (LabeledContent's
        // label closure carries "value" semantics here) — see ContainerCLI oracles elsewhere in
        // this file for the same label-OR-value pattern.
        let anyRow = app.staticTexts
            .matching(NSPredicate(format: "value CONTAINS 'container.'"))
            .firstMatch
        XCTAssertTrue(anyRow.waitForExistence(timeout: 5), "expanding should reveal property rows")
    }
}
