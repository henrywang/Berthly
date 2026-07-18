// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

//
//  E2ESupport.swift
//  BerthlyE2ETests
//
//  Shared plumbing for the local-only end-to-end suite: launching the app against
//  the REAL daemon, shelling out to the `container` CLI as the assertion oracle,
//  and sweeping up prefixed resources so crashed runs never leave debris behind.
//

import XCTest

extension XCUIApplication {
    /// E2E launches mirror `XCUIApplication.berthly()` from BerthlyUITests (menu-bar apps
    /// relaunch windowless under window restoration — see CLAUDE.md), but deliberately do
    /// NOT set `UITEST_USE_MOCK_SERVICE`: the entire point of this target is the live
    /// `LiveContainerService` talking to a real daemon.
    static func berthlyE2E() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }

    /// Opens a sheet/page through the ⌘K command palette by its title (e.g. "Create Volume").
    /// Uniform, unambiguous entry point — avoids per-sheet toolbar/popover wiring. Returns
    /// false (via the caller's assert) if the palette or field never appears.
    @discardableResult
    func openViaPalette(_ commandTitle: String) -> Bool {
        typeKey("k", modifierFlags: .command)
        let search = textFields["commandPaletteSearchField"]
        guard search.waitForExistence(timeout: 5) else { return false }
        search.click()
        search.typeText(commandTitle)
        typeKey(.return, modifierFlags: [])
        return true
    }
}

/// Thin wrapper around the `container` CLI. The XCUITest runner is unsandboxed, so it can
/// spawn processes directly — we drive the daemon through the UI and *verify* through the
/// CLI (and occasionally the reverse), which is what makes these tests end-to-end rather
/// than screenshot tours.
enum ContainerCLI {
    /// Resolved lazily: an env override first (so a dev build of the CLI can be tested),
    /// then the standard install location.
    static var binaryPath: String {
        ProcessInfo.processInfo.environment["BERTHLY_CONTAINER_CLI"] ?? "/usr/local/bin/container"
    }

    struct Result {
        let status: Int32
        let output: String
    }

    /// Runs `container <arguments>` and returns exit status + combined stdout/stderr.
    /// Synchronous by design — E2E assertions are sequential and generous timeouts are
    /// this suite's contract (real pulls/boots take seconds, not milliseconds).
    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = 60) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments
        // The XCUITest runner executes with a *container* HOME
        // (~/Library/Containers/…xctrunner/Data). The container CLI resolves its appRoot
        // (apiserver plist, image store) relative to HOME, so inheriting the runner's
        // environment makes it look in an empty container and report "apiserver is not
        // running and not registered with launchd" even when the daemon is up. Resolve
        // the REAL home from the passwd database instead — it isn't affected by the env.
        var environment = ProcessInfo.processInfo.environment
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            environment["HOME"] = String(cString: dir)
        }
        environment["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "ContainerCLI", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "`container \(arguments.joined(separator: " "))` timed out after \(Int(timeout))s"
            ])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Lossy decode on purpose: CLI output with a stray non-UTF-8 byte should still
        // surface the rest, not become nil.
        // swiftlint:disable:next optional_data_string_conversion
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binaryPath)
    }

    static var daemonIsRunning: Bool {
        (try? run(["system", "status"], timeout: 10))?.status == 0
    }

    /// Pulls `reference` if it isn't already present. Pulls are the slowest step in the
    /// suite, so `scripts/e2e.sh` pre-pulls the fixture image — this is the in-test
    /// fallback for running a single test straight from Xcode.
    static func ensureImage(_ reference: String) throws {
        let images = try run(["image", "ls"], timeout: 30)
        let base = reference.split(separator: ":").first.map(String.init) ?? reference
        if images.status == 0 && images.output.contains(base) { return }
        let pull = try run(["image", "pull", reference], timeout: 600)
        guard pull.status == 0 else {
            throw NSError(domain: "ContainerCLI", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "pull \(reference) failed: \(pull.output)"
            ])
        }
    }

    /// Parsed `container inspect` for one container. apple/container returns a JSON array;
    /// this unwraps the first element. Schema reference (verified against a live daemon,
    /// 2026-07-10 — apple/container 1.1.0):
    ///   .configuration.image.reference            "docker.io/library/alpine:latest"
    ///   .configuration.initProcess.environment    ["PATH=…", "BERTHLY_E2E=1"]
    ///   .configuration.labels                     {"berthly.e2e": "abc123"}
    ///   .configuration.resources.cpus             3
    ///   .configuration.resources.memoryInBytes    536870912
    ///   .configuration.readOnly                   false
    ///   .status.state                             "running"
    static func inspectJSON(_ name: String) throws -> [String: Any] {
        let result = try run(["inspect", name], timeout: 30)
        guard result.status == 0 else {
            throw NSError(domain: "ContainerCLI", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "inspect \(name) failed: \(result.output)"
            ])
        }
        let data = Data(result.output.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data)
        if let array = parsed as? [[String: Any]], let first = array.first { return first }
        if let object = parsed as? [String: Any] { return object }
        throw NSError(domain: "ContainerCLI", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "unexpected inspect JSON shape: \(result.output.prefix(200))"
        ])
    }

    /// Digs a dot path through nested dictionaries ("configuration.resources.cpus").
    /// Only for keys without dots of their own — read dotted keys (labels) directly.
    static func value(at path: String, in json: [String: Any]) -> Any? {
        var current: Any? = json
        for component in path.split(separator: ".") {
            current = (current as? [String: Any])?[String(component)]
        }
        return current
    }

    /// Force-removes every container whose name starts with `prefix`. Called from both
    /// setUp (leftovers from a previous *crashed* run — without this, debris causes
    /// name-collision "flakes") and tearDown (this run's resources).
    static func sweepContainers(prefix: String) {
        guard let list = try? run(["ls", "-a", "-q"], timeout: 30), list.status == 0 else { return }
        let stale = list.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
        guard !stale.isEmpty else { return }
        _ = try? run(["rm", "-f"] + stale, timeout: 60)
    }

    /// `container exec <name> <arguments…>` — the behavioral oracle. Runs a command *inside*
    /// a running container so tests can observe an option actually taking effect (env visible,
    /// filesystem read-only, workdir/user applied) rather than just its recorded configuration.
    @discardableResult
    static func exec(_ name: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> Result {
        try run(["exec", name] + arguments, timeout: timeout)
    }

    /// Removes named volumes/networks whose name starts with `prefix`. `volume ls`/`network ls`
    /// have no -q, so take the first whitespace-delimited column of each row after the header.
    static func sweepVolumes(prefix: String) { sweepNamed(kind: "volume", prefix: prefix) }
    static func sweepNetworks(prefix: String) { sweepNamed(kind: "network", prefix: prefix) }

    private static func sweepNamed(kind: String, prefix: String) {
        guard let list = try? run([kind, "ls"], timeout: 30), list.status == 0 else { return }
        let stale = list.output
            .split(separator: "\n")
            .dropFirst() // header row
            .compactMap { $0.split(separator: " ", maxSplits: 1).first.map(String.init) }
            .filter { $0.hasPrefix(prefix) }
        for name in stale { _ = try? run([kind, "delete", name], timeout: 30) }
    }

    /// Removes images whose reference contains `prefix` (e.g. the build journey's
    /// `berthly-e2e/...` tags). Public registry images pulled by the pull journey aren't
    /// prefixable, so that test removes its own target explicitly.
    static func sweepImages(prefix: String) {
        guard let list = try? run(["image", "ls"], timeout: 30), list.status == 0 else { return }
        // `image ls` columns are NAME TAG DIGEST; `image delete` needs NAME:TAG (a bare NAME
        // fails), so rejoin the first two columns.
        let stale: [String] = list.output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { row in
                let cols = row.split(separator: " ", omittingEmptySubsequences: true)
                guard cols.count >= 2, cols[0].contains(prefix) else { return nil }
                return "\(cols[0]):\(cols[1])"
            }
        for ref in stale { _ = try? run(["image", "delete", ref], timeout: 30) }
    }

    /// Machine counterpart of `sweepContainers`. `machine ls` has no -q, so parse the
    /// NAME column out of the header table; prefix-scoping is what keeps this away from
    /// the developer's real machines. Running machines must be stopped before delete.
    static func sweepMachines(prefix: String) {
        guard let list = try? run(["machine", "ls"], timeout: 30), list.status == 0 else { return }
        let stale = list.output
            .split(separator: "\n")
            .dropFirst() // header row
            .compactMap { $0.split(separator: " ", maxSplits: 1).first.map(String.init) }
            .filter { $0.hasPrefix(prefix) }
        for name in stale {
            _ = try? run(["machine", "stop", name], timeout: 60)
            _ = try? run(["machine", "delete", name], timeout: 60)
        }
    }
}

/// Base class every E2E test inherits: opt-in gate, environment preflight, stray-instance
/// kill, and prefix hygiene. Guards use `XCTSkip`, so an un-opted-in ⌘U run reports the
/// suite as skipped rather than failed.
class BerthlyE2ETestCase: XCTestCase {
    /// Every resource this suite creates carries this prefix — it's what makes cleanup
    /// safe on a machine that also has *real* containers.
    static let resourcePrefix = "berthly-e2e"

    /// Run-unique name for the container a test creates, e.g. `berthly-e2e-1a2b3c4d`.
    private(set) var containerName = ""

    /// Run-unique name for a machine a test creates. Separate prefix segment ("-m-") so the
    /// container and machine sweeps never trip over each other's names.
    private(set) var machineName = ""

    /// Run-unique names for volumes/networks a test creates (kept within the sweep prefix).
    private(set) var volumeName = ""
    private(set) var networkName = ""

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Triple gate. E2E mutates real daemon state, so it must be impossible to run by
        // accident: (1) explicit opt-in via scripts/e2e.sh (TEST_RUNNER_BERTHLY_E2E=1),
        // (2) never on CI (hosted runners lack nested virtualization anyway),
        // (3) only with an installed CLI and a running daemon.
        let env = ProcessInfo.processInfo.environment
        guard env["BERTHLY_E2E"] == "1" else {
            throw XCTSkip("E2E is opt-in: run via scripts/e2e.sh (sets BERTHLY_E2E=1)")
        }
        if env["CI"] != nil {
            throw XCTSkip("E2E tests are local-only; CI runners can't boot the container daemon")
        }
        guard ContainerCLI.isInstalled else {
            throw XCTSkip("container CLI not found at \(ContainerCLI.binaryPath)")
        }
        let status: ContainerCLI.Result
        do {
            status = try ContainerCLI.run(["system", "status"], timeout: 10)
        } catch {
            throw XCTSkip("container CLI failed to launch: \(error)")
        }
        guard status.status == 0 else {
            // Two ways to land here: the daemon really is down, or this suite was run
            // WITHOUT scripts/e2e.sh. Xcode signs the xctrunner with app-sandbox=true and
            // a mach-lookup allowlist that excludes com.apple.container.*, so a sandboxed
            // runner's CLI children can't reach the daemon by XPC *or* by path (container
            // HOME) — e2e.sh strips that entitlement and re-signs the runner after
            // build-for-testing. There is no in-process escape: ENABLE_APP_SANDBOX is
            // ignored for xctrunners, and the sandbox denies launchctl submit.
            throw XCTSkip("""
            container daemon unreachable (exit \(status.status)): \(status.output.prefix(200))
            If the daemon IS running, you're in a sandboxed runner — run via scripts/e2e.sh.
            """)
        }

        // Same rationale as BerthlyUITests.setUpWithError: a stray instance from a manual
        // launch or crashed run makes launch() adopt nothing and every wait time out.
        let killer = Process()
        killer.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killer.arguments = ["-9", "Berthly"]
        killer.standardOutput = FileHandle.nullDevice
        killer.standardError = FileHandle.nullDevice
        if (try? killer.run()) != nil { killer.waitUntilExit() }

        ContainerCLI.sweepContainers(prefix: Self.resourcePrefix)
        ContainerCLI.sweepVolumes(prefix: Self.resourcePrefix)
        ContainerCLI.sweepNetworks(prefix: Self.resourcePrefix)
        ContainerCLI.sweepImages(prefix: Self.resourcePrefix)
        ContainerCLI.sweepMachines(prefix: Self.resourcePrefix)
        let uid = UUID().uuidString.prefix(8).lowercased()
        containerName = "\(Self.resourcePrefix)-\(uid)"
        machineName = "\(Self.resourcePrefix)-m-\(uid)"
        volumeName = "\(Self.resourcePrefix)-v-\(uid)"
        networkName = "\(Self.resourcePrefix)-n-\(uid)"
    }

    override func tearDownWithError() throws {
        // Guards above may have skipped before the daemon check; sweeping is safe either way.
        if ContainerCLI.isInstalled && ContainerCLI.daemonIsRunning {
            ContainerCLI.sweepContainers(prefix: Self.resourcePrefix)
            ContainerCLI.sweepVolumes(prefix: Self.resourcePrefix)
            ContainerCLI.sweepNetworks(prefix: Self.resourcePrefix)
            ContainerCLI.sweepImages(prefix: Self.resourcePrefix)
            ContainerCLI.sweepMachines(prefix: Self.resourcePrefix)
        }
    }

    /// Opens the Run Container sheet: click the (daemon-gated) toolbar button once enabled,
    /// then the "Run Container" popover option.
    @MainActor
    func openRunSheet(_ app: XCUIApplication) {
        let runButton = app.buttons["runToolbarButton"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 15), "run toolbar button")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: runButton)
        waitForExpectations(timeout: 30)
        runButton.click()
        let option = app.buttons["Run Container"]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Run Container option")
        option.click()
    }

    /// Types `text` into the sheet text field with `identifier` (waits, clicks to focus first).
    @MainActor
    func typeField(_ app: XCUIApplication, _ text: String, into identifier: String) {
        let field = app.windows.textFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "field \(identifier) should exist")
        field.click(); field.typeText(text)
    }

    /// Expands `SheetAdvancedSection` (`sheetAdvancedDisclosure` in the pull/push sheets) and
    /// waits for `identifier` — one of its revealed controls — to appear.
    @MainActor
    func expandAdvancedSection(_ app: XCUIApplication, revealing identifier: String, timeout: TimeInterval = 5) {
        app.buttons["sheetAdvancedDisclosure"].click()
        let revealed = app.checkBoxes[identifier]
        XCTAssertTrue(revealed.waitForExistence(timeout: timeout),
                      "\(identifier) should appear after expanding Advanced; sheet:\n\(app.windows.firstMatch.debugDescription)")
    }

    /// Opens the Terminal tab on the currently-selected container and types `command` into
    /// SwiftTerm's view, retrying focus-type until `file` appears inside `container` (the
    /// exec'd shell connects async with no queryable ready signal; the command must be
    /// idempotent). Confirmed: XCUITest keystrokes reach SwiftTerm where System Events don't.
    /// Returns whether the file appeared. Assumes the container's detail view is showing.
    @MainActor
    func runInTerminal(_ app: XCUIApplication, container: String, command: String,
                       awaitFile file: String, timeout: TimeInterval = 30) -> Bool {
        let terminalTab = app.radioButtons["Terminal"]
        guard terminalTab.waitForExistence(timeout: 10) else { return false }
        terminalTab.click()
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).click()
            app.typeText("\(command)\r")
            Thread.sleep(forTimeInterval: 2)
            if (try? ContainerCLI.exec(container, ["ls", file]))?.status == 0 { return true }
        } while Date() < deadline
        return false
    }
}
