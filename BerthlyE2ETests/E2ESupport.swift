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
                NSLocalizedDescriptionKey: "`container \(arguments.joined(separator: " "))` timed out after \(Int(timeout))s",
            ])
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
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
                NSLocalizedDescriptionKey: "pull \(reference) failed: \(pull.output)",
            ])
        }
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
        guard ContainerCLI.daemonIsRunning else {
            throw XCTSkip("container daemon not running — start it with `container system start`")
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
        containerName = "\(Self.resourcePrefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    override func tearDownWithError() throws {
        // Guards above may have skipped before the daemon check; sweeping is safe either way.
        if ContainerCLI.isInstalled && ContainerCLI.daemonIsRunning {
            ContainerCLI.sweepContainers(prefix: Self.resourcePrefix)
        }
    }
}
