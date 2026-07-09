// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import class AppKit.NSApplication
import AsyncHTTPClient
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Foundation
import Logging
import MachineAPIClient
import NIOCore
import NIOHTTP1
import NIOPosix
import TerminalProgress
internal import ContainerPersistence
internal import ContainerPlugin

@MainActor
final class LiveContainerService: ContainerServiceBase {

    private var pollTask: Task<Void, Never>?
    private var isStarting = false
    private var isStopping = false
    /// The in-flight elevated `osascript` (install/update), if any. Tracked so it can be killed
    /// on task cancellation and on app quit — an orphaned osascript otherwise blocks on its
    /// admin-password dialog forever and stalls every later authorization prompt behind it.
    private var privilegedProcess: Foundation.Process?
    private var isBuilding = false
    private var systemConfig: ContainerSystemConfig?
    private static let log = Logger(label: "app.berthly.container")

    private func resolvedSystemConfig() async -> ContainerSystemConfig {
        if systemConfig == nil {
            systemConfig = try? await ConfigurationLoader.load()
        }
        return systemConfig ?? ContainerSystemConfig()
    }

    private static let contextsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Berthly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("build-contexts.json")
    }()

    private static let pinnedItemsURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Berthly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pinned-items.json")
    }()

    // MARK: - Init

    override init() {
        super.init()
        loadBuildContexts()
        loadPinnedItems()
        startPolling()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.privilegedProcess?.terminate()
            }
        }
    }

    private func loadBuildContexts() {
        guard let data = try? Data(contentsOf: Self.contextsURL),
              let dict = try? JSONDecoder().decode([String: BuildContext].self, from: data) else { return }
        buildContexts = dict
    }

    override func saveBuildContext(_ ctx: BuildContext, for reference: String) {
        super.saveBuildContext(ctx, for: reference)
        guard let data = try? JSONEncoder().encode(buildContexts) else { return }
        try? data.write(to: Self.contextsURL, options: .atomic)
    }

    private func loadPinnedItems() {
        guard let data = try? Data(contentsOf: Self.pinnedItemsURL),
              let items = try? JSONDecoder().decode(PinnedItems.self, from: data) else { return }
        pinnedContainerIDs = items.containers
        pinnedMachineIDs = items.machines
    }

    private func savePinnedItems() {
        let items = PinnedItems(containers: pinnedContainerIDs, machines: pinnedMachineIDs)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.pinnedItemsURL, options: .atomic)
    }

    override func togglePinContainer(_ id: String) {
        super.togglePinContainer(id)
        savePinnedItems()
    }

    override func togglePinMachine(_ id: String) {
        super.togglePinMachine(id)
        savePinnedItems()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.poll()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await self.poll()
            }
        }
    }

    override func refresh() async {
        await poll()
    }

    private func poll() async {
        // While `stopDaemon()` is tearing things down, the daemon may still answer a ping for a
        // moment — without this guard, this independent 5-second timer would see it as still
        // `.connected` and stomp on `.stopping`, or on the `.installedButStopped` `stopDaemon()`
        // just set, flipping the UI back to "running" for a container system that's mid-shutdown.
        guard !isStarting && !isStopping else { return }
        do {
            let health = try await ClientHealthCheck.ping(timeout: .seconds(5))
            // apiServerVersion is a full descriptive string (e.g. "container-apiserver version
            // 1.0.0 (build: release, commit: abc1234)"), not a bare version — pull just the
            // number out for both the compatibility check and anywhere this is displayed.
            let installedVersion = ContainerCompatibility.extractVersion(from: health.apiServerVersion) ?? health.apiServerVersion
            installedContainerVersion = installedVersion
            await refreshAll()
            daemonState = ContainerCompatibility.isCompatible(installed: installedVersion)
                ? .connected
                : .versionMismatch(installed: installedVersion, required: ContainerCompatibility.requiredVersion)
        } catch {
            daemonState = .afterFailedPing(
                isConnectionFailure: isXPCConnectionError(error),
                cliInstalled: FileManager.default.fileExists(atPath: Self.apiServerExecutablePath),
                errorMessage: error.localizedDescription
            )
        }
    }

    // `nonisolated`: these are immutable compile-time constants read by the `nonisolated`
    // daemon-launch helpers (`launchDaemonIfNeeded`, `pingDaemonWithRecovery`), which run off the
    // main actor. Without `nonisolated` they'd be MainActor-isolated (this is a `@MainActor` class)
    // and every off-actor read would warn under Swift 6 concurrency.
    private nonisolated static let apiServerExecutablePath = "/usr/local/bin/container-apiserver"
    // `InstallRoot.defaultPath` derives this from `CommandLine.executablePath`, which for a GUI
    // .app resolves to Berthly's own bundle path, not the `container` CLI's install location —
    // hardcode the layout the CLI's own installer uses instead (`container-apiserver` lives next
    // to `container` under `/usr/local/bin`, confirmed on disk).
    private nonisolated static let installRootPath = "/usr/local"
    private nonisolated static let apiServerLabel = "com.apple.container.apiserver"
    private static let servicePrefix = "com.apple.container."

    /// Native (launchd, no CLI shelling) implementation of `container system start`: registers
    /// (or restarts) the `container-apiserver` launchd service, waits for it to respond, and
    /// bootstraps the vminit filesystem image and default kernel on first run — without asking,
    /// since this app has no interactive terminal for the CLI's "install the kernel? [Y/n]"
    /// prompt, and a daemon without a kernel can't run anything anyway. Those bootstrap
    /// downloads are sizeable, so they report to `onLog` when a caller provides one.
    override func startDaemon(onLog: (@MainActor (String) -> Void)? = nil) async {
        guard !isStarting, !isStopping else { return }
        guard FileManager.default.fileExists(atPath: Self.apiServerExecutablePath) else {
            daemonState = .notInstalled
            return
        }
        isStarting = true
        daemonState = .connecting
        lastStartupWarning = nil

        do {
            try await launchDaemonIfNeeded()
            try await pingDaemonWithRecovery()
            _ = try await MachineClient().list()
        } catch {
            daemonState = .error(error.localizedDescription)
            isStarting = false
            return
        }

        let containerSystemConfig = await resolvedSystemConfig()
        await installVminitImageIfNeeded(containerSystemConfig: containerSystemConfig, onLog: onLog)
        await installDefaultKernelIfNeeded(containerSystemConfig: containerSystemConfig, onLog: onLog)

        // Clear before polling — `poll()` no-ops while `isStarting` is true, so this must happen
        // before the call below, not in a `defer` (which wouldn't fire until after `poll()` returns).
        isStarting = false
        await poll()
    }

    /// Native (launchd, no CLI shelling) implementation of `container system stop`, mirroring
    /// `SystemStop.swift`: stops every running container on the machine — not just ones Berthly
    /// shows; CLI-launched and machine-backed containers are included, matching the real command —
    /// waits for them to exit, then deregisters the apiserver plus every other
    /// `com.apple.container.*` launchd service. Every UI entry point into this must make that
    /// blast radius explicit before calling it; this method itself doesn't ask for confirmation.
    override func stopDaemon() async {
        // Without this guard, the independent 5-second `poll()` timer keeps running underneath
        // this (which can itself take 20+ seconds waiting for containers to exit) and races it —
        // see the guard in `poll()`. `isStarting` is also checked so a stop can't overlap a
        // start. Logged because a silent early-return here (stuck flag from a prior call that
        // never reached its `defer`) is otherwise indistinguishable from the toggle doing nothing.
        guard !isStarting, !isStopping else {
            Self.log.warning("stopDaemon() skipped — already in progress", metadata: ["isStarting": "\(isStarting)", "isStopping": "\(isStopping)"])
            return
        }
        isStopping = true
        daemonState = .stopping
        defer { isStopping = false }
        Self.log.info("stopDaemon() starting")

        let apiServerRunning = (try? await ClientHealthCheck.ping(timeout: .seconds(5))) != nil
        Self.log.info("stopDaemon(): initial ping", metadata: ["apiServerRunning": "\(apiServerRunning)"])

        if apiServerRunning {
            let client = ContainerClient()
            if let allContainers = try? await client.list() {
                Self.log.info("stopDaemon(): stopping containers", metadata: ["count": "\(allContainers.count)"])
                // Concurrent, not sequential — mirrors the CLI's own `ContainerStop.stopContainers`
                // (TaskGroup over all containers). Each `stop` has its own ~5s graceful-shutdown
                // timeout; stopping N containers one at a time turns that into an N*5s wait for no
                // reason, since the containers are independent.
                let log = Self.log
                await withTaskGroup(of: Void.self) { group in
                    for snapshot in allContainers {
                        group.addTask {
                            do {
                                try await client.stop(id: snapshot.id)
                            } catch {
                                log.warning("stopDaemon(): failed to stop container", metadata: ["id": "\(snapshot.id)", "error": "\(error)"])
                            }
                        }
                    }
                }
            } else {
                Self.log.warning("stopDaemon(): client.list() failed before stopping containers")
            }
            // Matches SystemStop's shutdownTimeoutSeconds budget.
            for _ in 0..<20 {
                let stillRunning = (try? await client.list(filters: ContainerListFilters(status: .running))) ?? []
                if stillRunning.isEmpty { break }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        do {
            let domain = try ServiceManager.getDomainString()
            let fullLabel = "\(domain)/\(Self.apiServerLabel)"
            if apiServerRunning {
                do {
                    try ServiceManager.deregister(fullServiceLabel: fullLabel)
                    Self.log.info("stopDaemon(): deregistered apiserver", metadata: ["label": "\(fullLabel)"])
                } catch {
                    Self.log.error("stopDaemon(): failed to deregister apiserver", metadata: ["label": "\(fullLabel)", "error": "\(error)"])
                }
            }
            // Sibling services (e.g. network-vmnet) registered under the same prefix —
            // deregistered unconditionally, even if the apiserver ping failed, in case they're
            // still around.
            let siblingLabels = (try? ServiceManager.enumerate()) ?? []
            for label in siblingLabels where label.hasPrefix(Self.servicePrefix) && "\(domain)/\(label)" != fullLabel {
                do {
                    try ServiceManager.deregister(fullServiceLabel: "\(domain)/\(label)")
                    Self.log.info("stopDaemon(): deregistered sibling service", metadata: ["label": "\(label)"])
                } catch {
                    Self.log.warning("stopDaemon(): failed to deregister sibling service", metadata: ["label": "\(label)", "error": "\(error)"])
                }
            }
        } catch {
            Self.log.error("stopDaemon(): couldn't determine launchd domain — skipping deregistration", metadata: ["error": "\(error)"])
        }

        // Every step above is soft-failed (deregistering a service that's in a weird state
        // shouldn't abort the whole shutdown), so confirm the daemon is actually gone rather than
        // assuming success — otherwise a silent failure here reports "stopped" for a daemon that's
        // still running, which the next `poll()` tick would immediately contradict anyway.
        let stillResponding = (try? await ClientHealthCheck.ping(timeout: .seconds(3))) != nil
        Self.log.info("stopDaemon(): final verification", metadata: ["stillResponding": "\(stillResponding)"])
        if stillResponding {
            daemonState = .error("Couldn't stop the container daemon — it's still responding after the stop sequence.")
        } else {
            daemonState = .installedButStopped
        }
    }

    /// Stops the daemon, runs the upstream `update-container.sh` (already handles GitHub release
    /// lookup, signed-vs-unsigned package selection, and download — reimplementing that natively
    /// would just duplicate already-correct upstream logic) elevated via `osascript`'s native
    /// admin-password prompt, then restarts the daemon. Callers must confirm with the user before
    /// invoking this — `stopDaemon()` stops every running container on the machine.
    override func upgradeContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        await stopDaemon()
        guard case .installedButStopped = daemonState else {
            throw ContainerizationError(.invalidState, message: "Couldn't stop the container daemon before upgrading.")
        }

        do {
            try await runPrivilegedShellCommand(
                "/usr/local/bin/update-container.sh -v \(ContainerCompatibility.requiredVersion)",
                onLog: onLog
            )
        } catch {
            // Put the daemon back the way we found it — the user should land on a running
            // (still-old) setup, not stranded on the stopped gate. Unstructured Task so a
            // cancelled operation can't suppress the restart.
            Task { await self.startDaemon() }
            throw error
        }

        await startDaemon(onLog: onLog)
    }

    /// First-time install: downloads the pinned release's signed installer pkg, verifies its
    /// signature, and runs `installer` elevated. The upstream `update-container.sh` can't be used
    /// here — that script is installed *by* the pkg, so on a machine without `container` it
    /// doesn't exist yet. `startDaemon()` afterwards bootstraps the default kernel, so a fresh
    /// Mac goes straight to a working setup.
    override func installContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        let version = ContainerCompatibility.requiredVersion
        let pkgName = "container-\(version)-installer-signed.pkg"
        let url = URL(string: "https://github.com/apple/container/releases/download/\(version)/\(pkgName)")!

        onLog("Downloading \(pkgName)…")
        let pkgPath = try await Self.downloadFile(from: url, suggestedName: pkgName)
        onLog("Downloaded to \(pkgPath)")

        onLog("Verifying package signature…")
        try await Self.verifyPackageSignature(at: pkgPath)
        onLog("Signature OK (signed by Apple)")

        try await runPrivilegedShellCommand(
            Self.stagedInstallCommand(pkgPath: pkgPath),
            onLog: onLog
        )

        onLog("Starting container system…")
        await startDaemon(onLog: onLog)
    }

    private nonisolated static func downloadFile(from url: URL, suggestedName: String) async throws -> String {
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ContainerizationError(
                .internalError,
                message: "Download failed (HTTP \(http.statusCode)) for \(url.absoluteString)"
            )
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(suggestedName)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination.path
    }

    /// The exact leaf-certificate identity `pkgutil --check-signature` prints for apple/container
    /// release pkgs, including Apple's Containerization team ID — verified against the real
    /// signed 1.1.0 pkg. Deliberately NOT the generic "signed by a developer certificate issued
    /// by Apple" status line: every registered Developer ID on earth matches that phrase, which
    /// would let any developer's pkg through this gate. If upstream ever rotates its signing
    /// identity, installs fail closed with the verification error until this is re-pinned
    /// (re-check alongside `ContainerCompatibility.requiredVersion` bumps).
    nonisolated static let appleSignatureMarkers = [
        "Developer ID Installer: Apple Inc. - Containerization (UPBK2H6LZM)",
    ]

    /// The acceptance predicate for `pkgutil --check-signature`, extracted pure so the
    /// security-critical decision is testable without spawning a process.
    nonisolated static func isAcceptableSignature(output: String, terminationStatus: Int32) -> Bool {
        terminationStatus == 0 && appleSignatureMarkers.contains { output.contains($0) }
    }

    /// Refuses to hand a pkg to the elevated installer unless `pkgutil` confirms it's signed by
    /// Apple itself — a hijacked download (or a truncated file) must fail here, before the admin
    /// prompt.
    private nonisolated static func verifyPackageSignature(at pkgPath: String) async throws {
        let (status, output) = try await runProcessCollectingOutput(
            executablePath: "/usr/sbin/pkgutil",
            arguments: ["--check-signature", pkgPath]
        )
        guard isAcceptableSignature(output: output, terminationStatus: status) else {
            throw ContainerizationError(
                .internalError,
                message: "The downloaded installer package failed signature verification — refusing to install it.\n\(output)"
            )
        }
    }

    /// Runs a short command to completion without blocking a cooperative-pool thread — the
    /// blocking drain happens inside `terminationHandler`, which fires on Process's own private
    /// queue. Only for commands whose output fits the pipe buffer (~64 KB): a chattier command
    /// would fill the pipe and never exit. `pkgutil --check-signature` prints a few hundred bytes.
    private nonisolated static func runProcessCollectingOutput(
        executablePath: String,
        arguments: [String]
    ) async throws -> (terminationStatus: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Shell-quotes a value for safe interpolation into an `sh` command: wrapped in single
    /// quotes, embedded single quotes spliced out as `'\''`.
    nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The elevated install command. The pkg was already signature-checked in user space (so a
    /// bad download fails before the password prompt), but that copy sits in the user-writable
    /// temp directory — anything running as this user could swap it between that check and the
    /// root install. So the elevated shell copies the pkg into a root-owned staging directory
    /// (mode 700 under sticky /tmp, untouchable by the user), re-verifies the signature on the
    /// copy, and installs that copy: what got verified is exactly what gets installed.
    nonisolated static func stagedInstallCommand(pkgPath: String) -> String {
        let grepMarkers = appleSignatureMarkers.map { "-e \(shellQuoted($0))" }.joined(separator: " ")
        return "staging=$(/usr/bin/mktemp -d /tmp/berthly-install.XXXXXX)"
            + " && /bin/cp \(shellQuoted(pkgPath)) \"$staging/container.pkg\""
            + " && /usr/sbin/pkgutil --check-signature \"$staging/container.pkg\" | /usr/bin/grep \(grepMarkers)"
            + " && /usr/sbin/installer -pkg \"$staging/container.pkg\" -target /"
            + "; status=$?; /bin/rm -rf \"$staging\"; exit $status"
    }

    /// Builds the AppleScript source for an elevated shell command. The command is embedded in
    /// an AppleScript string literal, so backslashes and double quotes are escaped — without
    /// that, a command containing a quoted path would terminate the literal early and execute a
    /// mangled script. `do shell script` runs with a minimal PATH
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`) that omits `/usr/local/bin` — which made the upstream
    /// update script's final `container --version` self-check exit 1 *after* the update had
    /// already succeeded. Prepending `/usr/local/bin` fixes every lookup of container's binaries
    /// inside the elevated shell.
    nonisolated static func privilegedAppleScript(for shellCommand: String) -> String {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"export PATH=/usr/local/bin:$PATH; \(escaped)\" with administrator privileges"
    }

    /// `osascript` reports the user dismissing the admin-password dialog as
    /// `execution error: User canceled. (-128)` on stderr with exit code 1 — indistinguishable
    /// from a real failure by exit code alone. The message text is localized on non-English
    /// systems, so only the trailing error code is matched — but anchored to the end of the
    /// line, so command output that merely *mentions* -128 mid-line can't masquerade as a
    /// cancellation and silently suppress a real failure.
    nonisolated static func userCancelledAdminPrompt(_ outputLines: [String]) -> Bool {
        outputLines.contains { $0.hasSuffix("(-128)") }
    }

    /// Error text for a failed elevated command: the output tail is almost always more useful
    /// than the exit code, so include it when there is any.
    nonisolated static func privilegedFailureMessage(exitCode: Int32, outputLines: [String]) -> String {
        let tail = outputLines.suffix(6).joined(separator: "\n")
        if tail.isEmpty {
            return "The elevated command failed (exit code \(exitCode)) and produced no output."
        }
        return "The elevated command failed (exit code \(exitCode)):\n\(tail)"
    }

    /// Runs a shell command elevated via `osascript ... with administrator privileges`,
    /// which shows the native macOS admin-password dialog — no custom UI, no deprecated
    /// `AuthorizationExecuteWithPrivileges`. The process is tracked in `privilegedProcess` and
    /// killed on task cancellation and app quit: an orphaned osascript sits on its password
    /// dialog forever and silently blocks every subsequent authorization prompt on the system.
    /// `onLog` hops back to `MainActor` per line. Dismissing the password dialog surfaces as
    /// `CancellationError`, same as the in-app Cancel button.
    private func runPrivilegedShellCommand(
        _ shellCommand: String,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        try Task.checkCancellation()
        let appleScript = Self.privilegedAppleScript(for: shellCommand)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let readHandle = pipe.fileHandleForReading
        let drainTask = Task.detached(priority: .userInitiated) { () -> [String] in
            var collected: [String] = []
            while true {
                let data = readHandle.availableData
                if data.isEmpty { return collected }
                guard let str = String(data: data, encoding: .utf8) else { continue }
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    collected.append(line)
                    await MainActor.run { onLog(line) }
                }
            }
        }

        privilegedProcess = process
        defer { privilegedProcess = nil }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { finishedProcess in
                        Task {
                            let outputLines = await drainTask.value
                            if finishedProcess.terminationStatus == 0 {
                                continuation.resume()
                            } else if Self.userCancelledAdminPrompt(outputLines) {
                                continuation.resume(throwing: CancellationError())
                            } else {
                                continuation.resume(throwing: ContainerizationError(
                                    .internalError,
                                    message: Self.privilegedFailureMessage(
                                        exitCode: finishedProcess.terminationStatus,
                                        outputLines: outputLines
                                    )
                                ))
                            }
                        }
                    }
                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                // isRunning guards the never-launched case (terminate() would raise); a process
                // that already exited ignores the extra SIGTERM.
                if process.isRunning { process.terminate() }
            }
        } catch {
            // A SIGTERM from cancellation surfaces as a nonzero exit — report it as the
            // cancellation it is, not as a failure.
            try Task.checkCancellation()
            throw error
        }
    }

    /// Registers the `container-apiserver` launchd service, matching `SystemStart.run()`'s own
    /// plist construction. `ServiceManager.register` shells out to `launchctl bootstrap`, which is
    /// a no-op if the label is already loaded and won't restart a stopped one — so an
    /// already-registered label is kickstarted instead of re-registered.
    ///
    /// `nonisolated` deliberately: this touches no MainActor state, and every step here
    /// (`ConfigurationLoader`, `ServiceManager`) shells out to `launchctl`/does file I/O
    /// synchronously — without `nonisolated`, an `async` method on this `@MainActor` class runs
    /// that blocking work directly on the main thread; `nonisolated` makes it hop onto the
    /// cooperative thread pool instead, so starting the daemon doesn't freeze the UI.
    private nonisolated func launchDaemonIfNeeded() async throws {
        // Matches `SystemStart.run()`'s first line: refresh the read-only copy of the user's
        // config that the apiserver itself reads at startup.
        try ConfigurationLoader.copyConfigurationToReadOnly()

        let domain = try ServiceManager.getDomainString()
        let fullLabel = "\(domain)/\(Self.apiServerLabel)"
        // `try?` here means "isRegistered threw" and "isRegistered returned false" both fall
        // through to the register() path below — which is a safe default (`register` is a no-op
        // for an already-loaded label) rather than a definitive answer either way; `startDaemon`'s
        // retry-with-kickstart on a failed post-launch ping is what actually makes this reliable
        // even when this check picks the "wrong" branch.
        if (try? ServiceManager.isRegistered(fullServiceLabel: fullLabel)) == true {
            try ServiceManager.kickstart(fullServiceLabel: fullLabel)
            return
        }

        // Gatekeeper/amfid validates code signatures relative to the enclosing bundle hierarchy;
        // launching via a symlink outside that bundle fails the check, so resolve it first.
        let executablePath = URL(fileURLWithPath: Self.apiServerExecutablePath).resolvingSymlinksInPath().path

        let appRootPath = ApplicationRoot.pathname
        let apiServerDataURL = URL(fileURLWithPath: appRootPath).appendingPathComponent("apiserver")
        try FileManager.default.createDirectory(at: apiServerDataURL, withIntermediateDirectories: true)

        var env = PluginLoader.filterEnvironment()
        env[ApplicationRoot.environmentName] = appRootPath
        env[InstallRoot.environmentName] = Self.installRootPath

        let plist = LaunchPlist(
            label: Self.apiServerLabel,
            arguments: [executablePath, "start"],
            environment: env,
            limitLoadToSessionType: [.Aqua, .Background, .System],
            runAtLoad: true,
            machServices: [Self.apiServerLabel]
        )

        let plistURL = apiServerDataURL.appendingPathComponent("apiserver.plist")
        try plist.encode().write(to: plistURL)
        try ServiceManager.register(plistPath: plistURL.path)
    }

    /// Pings the apiserver, with one kickstart-and-retry recovery attempt if the first ping fails.
    /// This is what actually makes `launchDaemonIfNeeded`'s registered-vs-not check reliable in
    /// practice: rather than depending on that check having picked the right branch (register is a
    /// silent no-op for an already-loaded-but-stopped label), a failed ping here is treated as the
    /// real signal to force a restart before giving up.
    private nonisolated func pingDaemonWithRecovery() async throws {
        do {
            _ = try await ClientHealthCheck.ping()
        } catch {
            let domain = try ServiceManager.getDomainString()
            try? ServiceManager.kickstart(fullServiceLabel: "\(domain)/\(Self.apiServerLabel)")
            _ = try await ClientHealthCheck.ping()
        }
    }

    /// Pulls and unpacks the vminit base filesystem image if it isn't already present — mirrors
    /// `SystemStart.installInitialFilesystem`. Soft-fails (logs only) like the CLI does, since a
    /// hiccup here shouldn't block the daemon from reporting connected; a later operation that
    /// actually needs it will surface a clearer error at that point.
    private func installVminitImageIfNeeded(
        containerSystemConfig: ContainerSystemConfig,
        onLog: (@MainActor (String) -> Void)? = nil
    ) async {
        let reference = containerSystemConfig.vminit.image
        if let existing = try? await ClientImage.get(reference: reference, containerSystemConfig: containerSystemConfig),
           (try? await existing.getSnapshot(platform: .current)) != nil {
            return
        }
        // Emit a static line up front — unlike the builder pull, this download can land on a path
        // that reports no size events at all (a resolved-but-not-unpacked layer set, or a mid-pull
        // failure before a size event fires), and the user should still see something happened
        // rather than silence until "installed"/an error. The reporter's own throttled
        // "Downloading… N MB" lines follow once real bytes move.
        onLog?("Downloading base container filesystem (\(reference))…")
        let reporter = onLog.map { onLog in
            DownloadReporter(label: "Downloading base container filesystem (\(reference))", onLog: onLog)
        }
        do {
            let image = try await ClientImage.pull(
                reference: reference,
                platform: nil,
                scheme: .auto,
                containerSystemConfig: containerSystemConfig,
                progressUpdate: reporter?.handler
            )
            try await image.unpack(platform: nil)
            onLog?("Base container filesystem installed")
        } catch {
            Self.log.error("failed to install base container filesystem", metadata: ["error": "\(error)"])
            lastStartupWarning = "Couldn't install the base container filesystem: \(error.localizedDescription)"
            onLog?("Couldn't install the base container filesystem: \(error.localizedDescription)")
        }
    }

    /// Downloads and installs the recommended default kernel if none is configured yet — mirrors
    /// `SystemStart.installDefaultKernel`, but always installs rather than prompting (see
    /// `startDaemon`'s doc comment for why). Soft-fails like `installVminitImageIfNeeded`.
    private func installDefaultKernelIfNeeded(
        containerSystemConfig: ContainerSystemConfig,
        onLog: (@MainActor (String) -> Void)? = nil
    ) async {
        guard (try? await ClientKernel.getDefaultKernel(for: .current)) == nil else { return }
        // Static line up front (see installVminitImageIfNeeded's comment) — a local tar path
        // skips the HTTP download entirely and emits no size events, so the reporter alone would
        // go silent until "installed" on that path.
        onLog?("Downloading default kernel from \(containerSystemConfig.kernel.url.absoluteString)…")
        let reporter = onLog.map { onLog in
            DownloadReporter(label: "Downloading default kernel from \(containerSystemConfig.kernel.url.absoluteString)", onLog: onLog)
        }
        do {
            try await ClientKernel.installKernelFromTar(
                tarFile: containerSystemConfig.kernel.url.absoluteString,
                kernelFilePath: containerSystemConfig.kernel.binaryPath,
                platform: .current,
                progressUpdate: reporter?.handler,
                force: true
            )
            onLog?("Default kernel installed")
        } catch {
            Self.log.error("failed to install default kernel", metadata: ["error": "\(error)"])
            lastStartupWarning = "Couldn't install the default kernel: \(error.localizedDescription)"
            onLog?("Couldn't install the default kernel: \(error.localizedDescription)")
        }
    }

    // XPCClient throws ContainerizationError(.interrupted, message: "XPC connection error: …")
    // when the daemon isn't running (XPC_CONNECTION_ERROR_CONNECTION_INVALID).
    private func isXPCConnectionError(_ error: Error) -> Bool {
        // Narrowed to `ContainerizationError`s carrying the specific `.interrupted` code XPCClient
        // uses for this case, in addition to the message substrings — reduces the chance an
        // unrelated error whose description happens to contain the same wording gets misclassified
        // as "daemon stopped" instead of surfacing as a real `.error(...)`.
        guard let containerizationError = error as? ContainerizationError, containerizationError.isCode(.interrupted) else {
            return false
        }
        let desc = String(describing: error)
        return desc.contains("XPC connection error") || desc.contains("Connection invalid")
    }

    /// Server-side filter for `role == builder` — the same query that populates the `builders` list
    /// — so builder detection can't drift between what's shown as a builder in the UI and what
    /// `pruneStoppedContainers()` protects from deletion.
    private static func fetchBuilderSnaps() async throws -> [ContainerSnapshot] {
        try await ContainerClient().list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.role: ResourceRoleValues.builder])
        )
    }

    private func refreshAll() async {
        let machineSnaps = (try? await MachineClient().list()) ?? []
        let machineContainerIds = Set(machineSnaps.compactMap { $0.containerId })

        let builderSnaps = (try? await Self.fetchBuilderSnaps()) ?? []
        let builderIds = Set(builderSnaps.map { $0.id })

        do {
            let allSnaps = try await ContainerClient().list()
            containers = allSnaps
                .filter { !machineContainerIds.contains($0.id) && !builderIds.contains($0.id) }
                .map { mapContainer($0) }
        } catch {
            containers = []
        }
        images    = (try? await fetchImages())   ?? []
        volumes   = (try? await fetchVolumes())  ?? []
        networks  = (try? await fetchNetworks()) ?? []
        let kernelName = Self.kernelName(try? await ClientKernel.getDefaultKernel(for: .current))
        machines  = machineSnaps.map { mapMachine($0, kernelName: kernelName) }
        builders  = builderSnaps.map { mapBuilder($0) }
    }

    // MARK: - Fetch

    private func fetchContainers() async throws -> [Container] {
        try await ContainerClient().list().map { snap in mapContainer(snap) }
    }

    private func fetchImages() async throws -> [ContainerImage] {
        let config = await resolvedSystemConfig()
        let builderImage = config.build.image
        let initImage    = config.vminit.image
        let clientImages = try await ClientImage.list()
            .filter { !Utility.isInfraImage(name: $0.reference, builderImage: builderImage, initImage: initImage) }
        var result: [ContainerImage] = []
        var inspectData: [String: ImageInspectData] = [:]
        for img in clientImages {
            let resource = try? await img.toImageResource(containerSystemConfig: config)
            if let resource { inspectData[img.digest] = makeInspectData(resource) }
            result.append(mapImage(img, resource: resource))
        }
        imageInspectData = inspectData
        return result
    }

    private func fetchVolumes() async throws -> [Volume] {
        try await ClientVolume.list().map { cfg in mapVolume(cfg) }
    }

    private func fetchNetworks() async throws -> [Network] {
        try await NetworkClient().list().map { r in Self.mapNetwork(r) }
    }

    private func fetchMachines() async throws -> [Machine] {
        // Machines all boot the system default kernel — the snapshot records no
        // per-machine kernel — so resolve it once and thread it into every row.
        // A missing/failed default kernel degrades to a dash rather than failing
        // the whole list fetch.
        let kernelName = Self.kernelName(try? await ClientKernel.getDefaultKernel(for: .current))
        return try await MachineClient().list().map { mapMachine($0, kernelName: kernelName) }
    }

    /// Display name for a machine's kernel: the default kernel binary's filename
    /// (e.g. `vmlinux-6.18.15-186`). The `Kernel` type carries no version string,
    /// so the filename is the most honest stable identifier. `nil` → `"–"`.
    nonisolated static func kernelName(_ kernel: Kernel?) -> String {
        guard let kernel else { return "–" }
        return kernel.path.lastPathComponent
    }

    // MARK: - Mapping

    private func mapContainer(_ snap: ContainerSnapshot) -> Container {
        let proc = snap.configuration.initProcess
        let cmd = ([proc.executable] + proc.arguments).joined(separator: " ")
        let ref = snap.configuration.image.reference
        let image: String = {
            guard let atIdx = ref.firstIndex(of: "@") else { return ref }
            let name = String(ref[ref.startIndex ..< atIdx])
            return name.isEmpty ? ref : name  // digest-only ref: fall back to full string
        }()
        return Container(
            id: snap.id,
            name: snap.id,
            image: image,
            status: mapStatus(snap.status),
            ports: snap.configuration.publishedPorts.map {
                PortMapping(host: Int($0.hostPort), container: Int($0.containerPort))
            },
            cpuPercent: 0,
            memoryMB: 0,
            memoryLimitMB: 0,
            networkIOString: "–",
            uptime: uptimeString(from: snap.startedDate),
            command: cmd,
            mounts: snap.configuration.mounts.map {
                ContainerMount(source: $0.source, destination: $0.destination)
            },
            networks: snap.networks.map { $0.network },
            environment: proc.environment,
            startedDate: snap.startedDate
        )
    }

    private func makeInspectData(_ resource: ImageResource) -> ImageInspectData {
        let supportedArch = Set(["arm64", "amd64"])
        let displayVariants = resource.variants.filter {
            supportedArch.contains($0.platform.architecture)
        }
        let variants = (displayVariants.isEmpty ? resource.variants : displayVariants).map {
            ImageVariantInfo(arch: $0.platform.architecture, archVariant: $0.platform.variant,
                             sizeBytes: $0.size, digest: $0.digest)
        }
        // Prefer arm64 config, fall back to amd64, then first
        let primary = displayVariants.first(where: { $0.platform.architecture == "arm64" })
            ?? displayVariants.first(where: { $0.platform.architecture == "amd64" })
            ?? resource.variants.first
        let cfg = primary?.config.config
        let ep  = cfg?.entrypoint ?? []
        let cmd = cfg?.cmd ?? []
        let history: [String] = (primary?.config.history ?? []).compactMap { h in
            guard let raw = h.createdBy, !raw.isEmpty else { return nil }
            var s = raw
            if s.hasPrefix("/bin/sh -c ") { s = String(s.dropFirst("/bin/sh -c ".count)) }
            if s.hasPrefix("#(nop) ")      { s = String(s.dropFirst("#(nop) ".count)) }
            return s.trimmingCharacters(in: .whitespaces)
        }
        return ImageInspectData(
            variants: variants,
            command: (ep + cmd).joined(separator: " "),
            workDir: cfg?.workingDir ?? "",
            user: cfg?.user ?? "",
            stopSignal: cfg?.stopSignal ?? "",
            env: cfg?.env ?? [],
            labels: cfg?.labels ?? [:],
            history: history
        )
    }

    private func mapImage(_ img: ClientImage, resource: ImageResource?) -> ContainerImage {
        let ref = img.reference
        let atIdx = ref.firstIndex(of: "@")
        let base = atIdx.map { String(ref[ref.startIndex ..< $0]) } ?? ref
        let colonIdx = base.lastIndex(of: ":")
        let repository = colonIdx.map { String(base[base.startIndex ..< $0]) } ?? base
        let tag = colonIdx.map { idx -> String in String(base[base.index(after: idx)...]) } ?? "latest"

        let variants = resource?.variants.filter {
            !($0.platform.os == "unknown" && $0.platform.architecture == "unknown")
        } ?? []
        let sizeBytes = variants.reduce(0) { $0 + $1.size }
        let supportedArch: Set<String> = ["arm64", "amd64"]
        let arch = Array(Set(variants.map { $0.platform.architecture }).intersection(supportedArch)).sorted()
        let created: String = {
            guard let date = resource?.configuration.creationDate,
                  date.timeIntervalSince1970 > 0 else { return "–" }
            return date.formatted(Date.FormatStyle().day(.defaultDigits).month(.abbreviated).year(.defaultDigits))
        }()

        let isBuilt = img.description.descriptor.annotations?[AnnotationKeys.containerizationImageName] != nil

        return ContainerImage(
            id: img.digest,
            repository: repository,
            tag: tag,
            arch: arch,
            sizeBytes: sizeBytes,
            created: created,
            source: isBuilt ? .built : .pulled,
            usage: .unused
        )
    }

    private func mapVolume(_ cfg: VolumeConfiguration) -> Volume {
        let usedMB = cfg.sizeInBytes.map { Int($0 / 1_048_576) } ?? 0
        let created = cfg.creationDate.formatted(Date.FormatStyle().day(.defaultDigits).month(.abbreviated).year(.defaultDigits))
        return Volume(
            id: cfg.name,
            name: cfg.name,
            type: cfg.isAnonymous ? .anonymous : .named,
            usedMB: usedMB,
            allocatedMB: 0,
            driver: cfg.driver,
            source: cfg.source,
            created: created,
            labels: cfg.labels.map { "\($0.key)=\($0.value)" },
            mounts: [],
            fs: cfg.format,
            reclaimable: true
        )
    }

    nonisolated static func mapNetwork(_ r: NetworkResource) -> Network {
        Network(
            id: r.id,
            name: r.name,
            driver: r.configuration.plugin.lowercased().contains("host") ? .hostOnly : .nat,
            subnet: r.status.ipv4Subnet.description,
            gateway: r.status.ipv4Gateway.description,
            isDefault: r.name == NetworkClient.defaultNetworkName,
            scope: "local",
            ipv6Enabled: r.configuration.ipv6Subnet != nil,
            egress: "–",
            attachable: !r.isBuiltin,
            backend: r.configuration.plugin,
            endpoints: []
        )
    }

    private func mapMachine(_ snap: MachineSnapshot, kernelName: String) -> Machine {
        let diskGB = Double(snap.diskSize ?? 0) / 1_073_741_824
        let created = snap.createdDate.map {
            $0.formatted(Date.FormatStyle().day(.defaultDigits).month(.abbreviated).year(.defaultDigits))
        } ?? "–"
        let cpus = snap.bootConfig.cpus
        let memBytes = snap.bootConfig.memory.toUInt64(unit: .bytes)
        let memGB = Double(memBytes) / 1_073_741_824
        let resources = String(format: memGB >= 1 ? "%d CPU · %.0f GB" : "%d CPU · %.0f MB",
                               cpus, memGB >= 1 ? memGB : Double(memBytes) / 1_048_576)
        return Machine(
            id: snap.id,
            name: snap.id,
            image: snap.configuration.image.reference,
            status: mapStatus(snap.status),
            isUtility: false,
            diskUsedGB: 0,
            diskTotalGB: diskGB,
            uptimeString: uptimeString(from: snap.startedDate),
            kernel: kernelName,
            resources: resources,
            created: created,
            homeMount: Self.mapHomeMount(snap.bootConfig.homeMount)
        )
    }

    nonisolated static func mapHomeMount(_ option: MachineConfig.HomeMountOption) -> MachineHomeMount {
        switch option {
        case .ro:   .readOnly
        case .rw:   .readWrite
        case .none: .none
        }
    }

    private func mapBuilder(_ snap: ContainerSnapshot) -> Builder {
        let ref = snap.configuration.image.reference
        let atIdx = ref.firstIndex(of: "@")
        let base = atIdx.map { String(ref[ref.startIndex ..< $0]) } ?? ref
        return Builder(
            id: snap.id,
            name: snap.id,
            image: base,
            status: snap.status == .running ? .running : .stopped,
            autoStarted: snap.configuration.labels[ResourceLabelKeys.plugin] == "builder",
            cpus: Int(snap.configuration.resources.cpus),
            memoryGB: Int(snap.configuration.resources.memoryInBytes / 1_073_741_824)
        )
    }

    private func mapStatus(_ s: RuntimeStatus) -> ContainerStatus {
        switch s {
        case .running:                      return .running
        case .stopped, .stopping, .unknown: return .stopped
        }
    }

    private func uptimeString(from date: Date?) -> String {
        guard let date else { return "–" }
        let total = Int(Date().timeIntervalSince(date))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    // MARK: - Lifecycle actions

    override func startContainer(_ id: String) async throws {
        let client = ContainerClient()
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
        await refresh()
    }

    override func stopContainer(_ id: String) async throws {
        try await ContainerClient().stop(id: id)
        await refresh()
    }

    override func restartContainer(_ id: String) async throws {
        let client = ContainerClient()
        try await client.stop(id: id)
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
        await refresh()
    }

    override func deleteContainer(_ id: String) async throws {
        try await ContainerClient().delete(id: id)
        if pinnedContainerIDs.remove(id) != nil { savePinnedItems() }
        await refresh()
    }

    override func copyFiles(direction: CopyDirection, containerID: String, hostPath: String, containerPath: String) async throws {
        let (source, destination) = Self.copyArguments(direction: direction, hostPath: hostPath, containerPath: containerPath)
        let client = ContainerClient()
        // `createParents: true` so a copy into `/tmp/new/dir/` whose parent doesn't exist yet
        // succeeds instead of failing with "destination directory does not exist" (the framework's
        // default without this flag — see containerization's testCopyInFileToMissingDirectoryFails).
        switch direction {
        case .intoContainer:
            try await client.copyIn(id: containerID, source: source, destination: destination, createParents: true)
        case .outOfContainer:
            try await client.copyOut(id: containerID, source: source, destination: destination, createParents: true)
        }
    }

    /// Maps a copy `direction` plus the two user-entered paths to the `(source, destination)` pair
    /// the client expects. Pure and `nonisolated` so it's unit-testable without a daemon: the whole
    /// point is that `.outOfContainer` swaps which side is the source, and getting that backwards is
    /// the obvious bug. `hostPath` for `.outOfContainer` should already be a full target path (see
    /// `resolvedHostDestination`), since `copyOut` writes to the exact path given, not into a folder.
    nonisolated static func copyArguments(direction: CopyDirection, hostPath: String, containerPath: String) -> (source: String, destination: String) {
        switch direction {
        case .intoContainer:  return (source: hostPath, destination: containerPath)
        case .outOfContainer: return (source: containerPath, destination: hostPath)
        }
    }

    /// Turns a host *folder* the user picked into a concrete copy-out target by appending the
    /// container source's last path component — `copyOut` writes to the exact destination path, so
    /// handing it a bare directory would try to overwrite the directory itself. E.g. folder
    /// `/Users/me/Downloads` + source `/var/log/app.log` → `/Users/me/Downloads/app.log`.
    nonisolated static func resolvedHostDestination(folder: String, containerSource: String) -> String {
        let name = (containerSource as NSString).lastPathComponent
        return (folder as NSString).appendingPathComponent(name)
    }

    override func startMachine(_ id: String) async throws {
        // Routes through the same first-boot-aware helper `createMachine` uses: a no-op extra
        // check for the common case (an already-initialized machine), but correct if this is
        // ever reached for one that was created but never successfully booted.
        do {
            try await bootMachineNatively(id: id, client: MachineClient())
        } catch {
            // `bootMachineNatively` stops the machine internally before rethrowing on failure —
            // refresh so that real, server-side state change isn't stuck showing stale (e.g.
            // still "running") until the next background poll tick.
            await refresh()
            throw error
        }
        await refresh()
    }

    override func stopMachine(_ id: String) async throws {
        try await MachineClient().stop(id: id)
        await refresh()
    }

    override func deleteMachine(_ id: String) async throws {
        try await MachineClient().delete(id: id)
        if pinnedMachineIDs.remove(id) != nil { savePinnedItems() }
        await refresh()
    }

    override func stopBuilder(_ id: String) async throws {
        try await ContainerClient().stop(id: id)
        await refresh()
    }

    override func deleteImage(_ reference: String) async throws {
        try await ClientImage.delete(reference: reference)
        await refresh()
    }

    override func deleteVolume(_ name: String) async throws {
        try await ClientVolume.delete(name: name)
        await refresh()
    }

    override func deleteNetwork(_ id: String) async throws {
        try await NetworkClient().delete(id: id)
        await refresh()
    }

    override func createVolume(options: VolumeCreateOptions) async throws {
        let name = options.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Volume name is required.")
        }
        _ = try await ClientVolume.create(
            name: name,
            driver: "local",
            driverOpts: Self.volumeDriverOpts(for: options),
            labels: [:]
        )
        await refresh()
    }

    /// Pure/testable: the local driver takes `size` (bytes, optional K/M/G/T/P suffix) as a driver
    /// option — everything else is left to the daemon's defaults. Mirrors `VolumeCreate`'s CLI mapping.
    nonisolated static func volumeDriverOpts(for options: VolumeCreateOptions) -> [String: String] {
        let size = options.size?.trimmingCharacters(in: .whitespaces) ?? ""
        return size.isEmpty ? [:] : ["size": size]
    }

    override func createNetwork(options: NetworkCreateOptions) async throws {
        let name = options.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Network name is required.")
        }
        let subnetText = options.subnet?.trimmingCharacters(in: .whitespaces) ?? ""
        let subnet = try subnetText.isEmpty ? nil : CIDRv4(subnetText)
        let config = try NetworkConfiguration(
            name: name,
            mode: Self.networkMode(hostOnly: options.hostOnly),
            ipv4Subnet: subnet,
            plugin: "container-network-vmnet"
        )
        _ = try await NetworkClient().create(configuration: config)
        await refresh()
    }

    /// Pure/testable: the CLI's `--internal` flag selects a host-only network; otherwise NAT.
    nonisolated static func networkMode(hostOnly: Bool) -> NetworkMode {
        hostOnly ? .hostOnly : .nat
    }

    // MARK: - System page

    override func fetchDiskUsage() async throws {
        let stats = try await ClientDiskUsage.get()
        diskUsage = Self.mapDiskUsage(stats)
    }

    /// Pure image selection, extracted from the live client calls so the decision is unit-testable
    /// (see `PruneSelectionTests`). Mirrors the daemon's own `reclaimable` definition so freed space
    /// matches the number shown next to the button rather than exceeding it: the daemon counts an
    /// image as unused only when **no** container references it — running *or* stopped, machine or
    /// builder (`getActiveImageReferences` iterates every container). So the caller passes image
    /// references from the *current full* container list; an image referenced only by a stopped
    /// container is protected here even though that container may be removed separately — it's left
    /// for the next cleanup. Honest beats maximal.
    nonisolated static func unusedImageReferences(allImageReferences: [String], containerImageReferences: [String]) -> [String] {
        let inUse = Set(containerImageReferences)
        return allImageReferences.filter { !inUse.contains($0) }
    }

    /// Pure stopped-container selection. Only ordinary stopped containers are eligible; machine and
    /// builder containers are excluded even when stopped — deleting a stopped VM is irreversible
    /// data loss (see `PruneContainerInfo.isInfrastructure`).
    nonisolated static func deletableStoppedContainerIDs(_ containers: [PruneContainerInfo]) -> [String] {
        containers.filter { $0.isStopped && !$0.isInfrastructure }.map(\.id)
    }

    override func pruneImages() async throws -> PruneResult {
        try await pruneImages(allContainers: try await ContainerClient().list())
    }

    /// Takes the container list as a parameter (rather than fetching it here) so `pruneAll()` can
    /// share one fetch with `pruneStoppedContainers()` instead of each phase fetching its own.
    private func pruneImages(allContainers: [ContainerSnapshot]) async throws -> PruneResult {
        let allImages = try await ClientImage.list()
        // Full container list (running + stopped, incl. machines/builders) so every in-use image —
        // and every machine/builder image — is protected, matching the daemon's reclaimable calc.
        let unused = Self.unusedImageReferences(
            allImageReferences: allImages.map(\.reference),
            containerImageReferences: allContainers.map { $0.configuration.image.reference }
        )

        var result = PruneResult()
        // Untag each unused image, then GC orphaned blobs — the blob GC is what actually frees the
        // bytes (deleting a reference alone only untags), so its reported size is authoritative.
        for reference in unused {
            do {
                try await ClientImage.delete(reference: reference, garbageCollect: false)
                result.deletedImageCount += 1
            } catch {
                result.failedCount += 1
                Self.log.warning("pruneImages: failed to delete image", metadata: ["ref": "\(reference)", "error": "\(error)"])
            }
        }
        let (_, blobBytes) = try await ClientImage.cleanUpOrphanedBlobs()
        result.imagesFreedBytes = blobBytes

        await refresh()
        try? await fetchDiskUsage()
        return result
    }

    override func pruneStoppedContainers() async throws -> PruneResult {
        try await pruneStoppedContainers(allContainers: try await ContainerClient().list())
    }

    /// Takes the container list as a parameter (rather than fetching it here) so `pruneAll()` can
    /// share one fetch with `pruneImages()` instead of each phase fetching its own.
    private func pruneStoppedContainers(allContainers: [ContainerSnapshot]) async throws -> PruneResult {
        let client = ContainerClient()
        // Machine-backed containers, identified the same way `refreshAll()` separates them: a
        // container whose id is a machine's `containerId`. Builders are identified by the same
        // `role`-label server-side filter that populates the `builders` list (`fetchBuilderSnaps()`),
        // so this can never disagree with what the Builders section itself shows. Both are
        // infrastructure and must never be deleted, even when stopped.
        //
        // Unlike `refreshAll()`'s best-effort `try?` (a display refresh can tolerate showing stale
        // data), a failure here must abort the whole prune rather than silently treating every
        // machine/builder as an ordinary container — proceeding with an empty infrastructure set on
        // a transient XPC error would risk deleting a stopped VM or builder.
        let machineSnaps = try await MachineClient().list()
        let machineContainerIds = Set(machineSnaps.compactMap { $0.containerId })
        let builderIds = Set(try await Self.fetchBuilderSnaps().map { $0.id })

        let ids = Self.deletableStoppedContainerIDs(
            allContainers.map {
                PruneContainerInfo(
                    id: $0.id,
                    imageReference: $0.configuration.image.reference,
                    isStopped: $0.status == .stopped,
                    isInfrastructure: machineContainerIds.contains($0.id) || builderIds.contains($0.id)
                )
            }
        )

        var result = PruneResult()
        for id in ids {
            do {
                let size = try await client.diskUsage(id: id)  // tally before deleting
                try await client.delete(id: id)
                result.containersFreedBytes += size
                result.deletedContainerCount += 1
            } catch {
                result.failedCount += 1
                Self.log.warning("pruneStoppedContainers: failed to delete container", metadata: ["id": "\(id)", "error": "\(error)"])
            }
        }

        await refresh()
        try? await fetchDiskUsage()
        return result
    }

    override func pruneAll() async -> CleanUpAllResult {
        let allContainers: [ContainerSnapshot]
        do {
            allContainers = try await ContainerClient().list()
        } catch {
            // The one fetch both phases would share failed outright — neither can proceed.
            let message = error.localizedDescription
            return CleanUpAllResult(failureMessages: [
                "Removing unused images failed: \(message)",
                "Removing stopped containers failed: \(message)",
            ])
        }

        var combined = PruneResult()
        var failures: [String] = []
        do {
            combined = combined + (try await pruneImages(allContainers: allContainers))
        } catch {
            failures.append("Removing unused images failed: \(error.localizedDescription)")
        }
        do {
            combined = combined + (try await pruneStoppedContainers(allContainers: allContainers))
        } catch {
            failures.append("Removing stopped containers failed: \(error.localizedDescription)")
        }
        return CleanUpAllResult(result: combined, failureMessages: failures)
    }

    nonisolated static func mapDiskUsage(_ stats: DiskUsageStats) -> DiskUsageSummary {
        func category(_ usage: ResourceUsage) -> DiskUsageSummary.Category {
            DiskUsageSummary.Category(
                total: usage.total,
                active: usage.active,
                sizeBytes: usage.sizeInBytes,
                reclaimableBytes: usage.reclaimable
            )
        }
        return DiskUsageSummary(
            images: category(stats.images),
            containers: category(stats.containers),
            volumes: category(stats.volumes)
        )
    }

    override func fetchKernelInfo() async throws {
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        kernelInfo = Self.mapKernelInfo(kernel)
    }

    nonisolated static func mapKernelInfo(_ kernel: Kernel) -> KernelInfo {
        KernelInfo(path: kernel.path.path, platform: "\(kernel.platform.os.rawValue)/\(kernel.platform.architecture.rawValue)")
    }

    /// Native replication of `container system kernel set --binary`/`--tar`: installs a
    /// user-chosen kernel binary (local file) or archive member (local tar or remote URL) as the
    /// new default for the given architecture. There's no "list installed kernels" or update-check
    /// API on this daemon — this is the full extent of what `ClientKernel` supports.
    override func setKernel(options: KernelSetOptions, progress: ProgressUpdateHandler? = nil) async throws {
        let platform: SystemPlatform = options.architecture == "amd64" ? .linuxAmd : .linuxArm
        if let tarSource = options.tarSource {
            try await ClientKernel.installKernelFromTar(
                tarFile: tarSource,
                kernelFilePath: options.binaryPath,
                platform: platform,
                progressUpdate: progress,
                force: options.force
            )
        } else {
            try await ClientKernel.installKernel(kernelFilePath: options.binaryPath, platform: platform, force: options.force)
        }
        try await fetchKernelInfo()
    }

    override func fetchSystemConfig() async throws {
        let config = await resolvedSystemConfig()
        systemConfigInfo = Self.mapSystemConfig(config)
    }

    nonisolated static func mapSystemConfig(_ config: ContainerSystemConfig) -> SystemConfigInfo {
        SystemConfigInfo(
            vminitImage: config.vminit.image,
            kernelBinaryPath: config.kernel.binaryPath,
            kernelURL: config.kernel.url.absoluteString,
            builderImage: config.build.image
        )
    }

    // MARK: - Registries

    /// Same Keychain security domain `container registry login/logout/list` use
    /// (`ContainerAPIClient.Constants.keychainID`) — Berthly reads/writes the identical items the
    /// CLI and daemon do, in-process, no shelling out.
    private nonisolated static let registryKeychain = KeychainHelper(securityDomain: Constants.keychainID)

    /// Maps the Keychain's registry logins straight to `[Registry]`, sorted by host for a stable
    /// display order — a faithful mirror of `container registry list`, which is likewise just
    /// `keychain.list()`. No curated defaults, no persisted "signed-out" rows: the Keychain is
    /// the whole source of truth. Shown verbatim (e.g. `registry-1.docker.io`), same as the CLI.
    ///
    /// Takes plain `(hostname, username)` pairs rather than `RegistryInfo` directly: that type's
    /// memberwise init is internal to `ContainerizationOS` (only `KeychainQuery` itself
    /// constructs it), so it can't be fabricated from `BerthlyTests` — and we only need these two.
    nonisolated static func mapRegistries(keychainEntries: [(hostname: String, username: String)]) -> [Registry] {
        keychainEntries
            .map { Registry(host: $0.hostname, username: $0.username) }
            .sorted { $0.host < $1.host }
    }

    override func loadRegistries() async {
        let entries = (try? await Self.keychainList()) ?? []
        registries = Self.mapRegistries(keychainEntries: entries.map { (hostname: $0.hostname, username: $0.username) })
    }

    override func signInRegistry(host: String, username: String, password: String) async throws {
        let host = Reference.resolveDomain(domain: host.trimmingCharacters(in: .whitespaces))
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Host, username, and token are required.")
        }

        let containerSystemConfig = await resolvedSystemConfig()
        let scheme = try RequestScheme("auto").schemeFor(host: host, internalDnsDomain: containerSystemConfig.dns.domain)
        let client = RegistryClient(
            host: host,
            scheme: scheme.rawValue,
            authentication: BasicAuthentication(username: username, password: password),
            retryOptions: RetryOptions(maxRetries: 3, retryInterval: 300_000_000, shouldRetry: { $0.status.code >= 500 })
        )
        try await client.ping()

        do {
            try await Self.keychainSave(hostname: host, username: username, password: password)
        } catch let error as KeychainQuery.Error {
            throw Self.friendlyError(for: error, host: host) ?? error
        }
        await loadRegistries()
    }

    override func signOutRegistry(host: String) async throws {
        let host = Reference.resolveDomain(domain: host.trimmingCharacters(in: .whitespaces))
        do {
            try await Self.keychainDelete(hostname: host)
        } catch let error as KeychainQuery.Error {
            throw Self.friendlyError(for: error, host: host) ?? error
        }
        await loadRegistries()
    }

    /// macOS Keychain refuses to let a different process identity delete/overwrite an item —
    /// `container login` from the CLI creates entries Berthly can see (`list()`) but can't take
    /// ownership of. `errSecInvalidOwnerEdit` is macOS's exact signal for that case.
    private nonisolated static let errSecInvalidOwnerEdit: Int32 = -25244

    private nonisolated static func friendlyError(for error: KeychainQuery.Error, host: String) -> RegistryOperationError? {
        if case .unhandledError(let status) = error, status == errSecInvalidOwnerEdit {
            return RegistryOperationError(host: host)
        }
        return nil
    }

    /// `KeychainHelper`'s Security-framework calls are synchronous and can block on IPC to
    /// securityd — offload to a background queue rather than stalling the main actor.
    private nonisolated static func keychainList() async throws -> [RegistryInfo] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.list() })
            }
        }
    }

    private nonisolated static func keychainSave(hostname: String, username: String, password: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.save(hostname: hostname, username: username, password: password) })
            }
        }
    }

    private nonisolated static func keychainDelete(hostname: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try registryKeychain.delete(hostname: hostname) })
            }
        }
    }

    /// Streams `container`'s own daemon logs via unified logging (`/usr/bin/log stream`) — there's
    /// no XPC route for this (the CLI itself just shells out to `log`, see `SystemLogs.swift`), so
    /// this is a narrow, deliberate exception to the "no `Process()` calls" migration: it targets a
    /// stable Apple system binary, not the `container` CLI, so a container CLI bug still can't
    /// affect it.
    private nonisolated static let daemonLogPredicate = "subsystem = 'com.apple.container'"

    override func streamDaemonLogs(onLine: @MainActor @escaping (String) -> Void) async throws {
        // `log stream` only reports events emitted *after* it starts — the daemon's own activity
        // is sparse/bursty (long quiet stretches between background reconcile errors), so opening
        // this page would otherwise often show nothing at all for minutes. Backfill recent
        // history via `log show` first, then hand off to `log stream` for anything new.
        for line in await Self.fetchDaemonLogBackfill() {
            // The view may have already gone away while the backfill was running (it's a
            // one-shot subprocess, not covered by the cancellation handler below).
            if Task.isCancelled { return }
            onLine(line)
        }

        let (process, pipe) = try Self.launchLogProcess(arguments: [
            "log", "stream", "--info",
            "--style", "ndjson",
            "--predicate", Self.daemonLogPredicate,
        ])

        await withTaskCancellationHandler {
            do {
                for try await line in pipe.fileHandleForReading.bytes.lines {
                    if Task.isCancelled { break }
                    if let formatted = Self.formatDaemonLogEvent(line) {
                        onLine(formatted)
                    }
                }
            } catch {
                // Pipe closed because the process was terminated on cancel — expected.
            }
        } onCancel: {
            process.terminate()
        }
    }

    /// One-shot `log show --last 1h` so the Daemon Logs box has something to display immediately,
    /// rather than waiting on whatever `log stream` happens to report after the page opens.
    /// Unlike `log stream`, `log show` exits on its own once it's printed everything in the
    /// window, so this just drains its output instead of needing cancellation handling.
    nonisolated static func fetchDaemonLogBackfill() async -> [String] {
        guard let (_, pipe) = try? Self.launchLogProcess(arguments: [
            "log", "show", "--last", "1h", "--info",
            "--style", "ndjson",
            "--predicate", daemonLogPredicate,
        ]) else { return [] }

        var formatted: [String] = []
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if let event = formatDaemonLogEvent(line) { formatted.append(event) }
            }
        } catch {
            // Pipe closed when `log show` exits — expected, not an error worth surfacing.
        }
        return formatted
    }

    /// Launches `/usr/bin/env` with the given arguments (always `log show`/`log stream` here),
    /// piping stdout back for line-by-line reading — the shared setup behind both the one-shot
    /// backfill and the live tail.
    nonisolated private static func launchLogProcess(arguments: [String]) throws -> (process: Foundation.Process, pipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        return (process, pipe)
    }

    /// Decodes one `log stream --style ndjson` event and re-joins its timestamp/level/message as
    /// `"timestamp\tlevel\tmessage"` — the format `DaemonLogView.parseLine` (SystemView.swift)
    /// splits back apart — instead of leaving the daemon's own logging format to be guessed from
    /// free text. Returns `nil` for non-JSON lines, e.g. the "Filtering the log data..." banner
    /// `log stream` prints before the first event, so the log view never shows a stray unparsed
    /// line for it.
    nonisolated static func formatDaemonLogEvent(_ ndjsonLine: String) -> String? {
        struct Event: Decodable {
            let timestamp: String
            let messageType: String
            let eventMessage: String
        }
        guard let data = ndjsonLine.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data)
        else { return nil }

        // "YYYY-MM-DD HH:MM:SS.ffffff±HHMM" → "HH:MM:SS.fff": date is redundant for a live tail,
        // and microsecond/timezone precision isn't worth the column width in a fixed-width row.
        let time = event.timestamp.split(separator: " ", maxSplits: 1).last.map { String($0.prefix(12)) }
            ?? event.timestamp
        return "\(time)\t\(event.messageType)\t\(event.eventMessage)"
    }

    /// Resolves the Dockerfile to build from: an explicit path if given, else the CLI's own
    /// fallback (`Dockerfile`, then `Containerfile`, in `contextPath`) via `BuildFile.resolvePath`.
    nonisolated static func resolveDockerfilePath(for options: BuildOptions) throws -> String {
        if let file = options.dockerfilePath, !file.isEmpty {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ContainerizationError(.invalidArgument, message: "Dockerfile does not exist: \(file)")
            }
            return file
        }
        guard let resolved = try BuildFile.resolvePath(contextDir: options.contextPath),
              FileManager.default.fileExists(atPath: resolved) else {
            throw ContainerizationError(.invalidArgument, message: "No Dockerfile or Containerfile found in \(options.contextPath)")
        }
        return resolved
    }

    /// Replicates the CLI's `--secret id=<key>[,env=<VAR>|,src=<path>]` parsing
    /// (`BuildCommand.validate()`), resolving straight to `Data` since this app has no
    /// separate validate/run phase to defer the env/file read into.
    nonisolated static func resolveBuildSecrets(_ raw: [String]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for secret in raw {
            let parts = secret.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].hasPrefix("id=") else {
                throw ContainerizationError(.invalidArgument, message: "secret must start with id=<key>: \(secret)")
            }
            let key = String(parts[0].dropFirst(3))
            guard !key.isEmpty, !key.contains("=") else {
                throw ContainerizationError(.invalidArgument, message: "invalid secret id: \(secret)")
            }
            if parts.count == 1 || parts[1].hasPrefix("env=") {
                let envName = parts.count == 1 ? key : String(parts[1].dropFirst(4))
                guard let ptr = getenv(envName) else {
                    throw ContainerizationError(.invalidArgument, message: "secret env var doesn't exist: \(envName)")
                }
                result[key] = Data(bytes: ptr, count: strlen(ptr))
            } else if parts[1].hasPrefix("src=") {
                let path = String(parts[1].dropFirst(4))
                result[key] = try Data(contentsOf: URL(fileURLWithPath: path))
            } else {
                throw ContainerizationError(.invalidArgument, message: "invalid secret value: \(secret)")
            }
        }
        return result
    }

    /// Normalizes the target image reference the same way the CLI does (`Reference.parse` +
    /// `.normalize()`), falling back to a random tag when none was given (matches
    /// `BuildCommand.targetImageNames`'s default).
    nonisolated static func buildTags(for options: BuildOptions) throws -> [String] {
        let name = options.reference.isEmpty ? UUID().uuidString.lowercased() : options.reference
        let reference = try Reference.parse(name)
        reference.normalize()
        return [reference.description]
    }

    /// Parses `options.platform` (comma-separated `os/arch[/variant]` entries) or falls back to
    /// the host's own linux platform — the CLI's default when no `--platform`/`--os`/`--arch` is given.
    nonisolated static func buildPlatforms(for options: BuildOptions) throws -> [Platform] {
        guard let raw = options.platform, !raw.isEmpty else {
            return [try Platform(from: "linux/\(Arch.hostArchitecture().rawValue)")]
        }
        return try raw.split(separator: ",").map { try Platform(from: $0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Dials the running builder over VSOCK; if that fails (not running yet), starts it via
    /// `startBuilderContainer` (our replication of the CLI's non-public `BuilderStart.start`)
    /// and retries every 5s, up to a 300s deadline — matching `BuildCommand.run`'s own retry loop.
    private func dialOrStartBuilder(
        containerSystemConfig: ContainerSystemConfig,
        cpus: Int64?,
        memory: String?,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws -> ContainerBuild.Builder {
        let deadline = Date().addingTimeInterval(300)
        // Whether we've had to start the builder this call. Gates the user-facing messages so the
        // common fast path (builder already running → first dial succeeds) stays silent, and the
        // retry loop announces the start exactly once instead of on every failed dial.
        var announcedStart = false
        while true {
            do {
                let socket = try await ContainerClient().dial(id: ContainerBuild.Builder.builderContainerId, port: 8088)
                let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
                let builder = try ContainerBuild.Builder(socket: socket, group: group, logger: Self.log)
                _ = try await builder.info()
                if announcedStart { onLog("Build environment ready.") }
                return builder
            } catch {
                guard Date() < deadline else {
                    throw ContainerizationError(.timeout, message: "Timed out waiting for the builder to start.")
                }
                // Without this, the build log sits empty through the builder image download and VM
                // boot (tens of seconds on first build) and looks hung.
                if !announcedStart {
                    onLog("Starting the build environment…")
                    announcedStart = true
                }
                try await startBuilderContainer(containerSystemConfig: containerSystemConfig, cpus: cpus, memory: memory, onLog: onLog)
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Native replication of the CLI's non-public `BuilderStart.start()`: reuses a running/stopped
    /// "buildkit" container when its image/cpu/memory still match, otherwise (re)creates it —
    /// fetching the builder image, wiring the tmpfs `/run` + virtiofs exports mounts, network, and
    /// kernel exactly as the CLI does — then bootstraps the `container-builder-shim` process.
    private func startBuilderContainer(
        containerSystemConfig: ContainerSystemConfig,
        cpus: Int64?,
        memory: String?,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        let builderImage = containerSystemConfig.build.image
        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let exportsMount = systemHealth.appRoot.appendingPathComponent("builder").path
        if !FileManager.default.fileExists(atPath: exportsMount) {
            try FileManager.default.createDirectory(atPath: exportsMount, withIntermediateDirectories: true)
        }

        let builderPlatform = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: "v8")
        let resources = try Parser.resources(
            cpus: cpus,
            memory: memory,
            defaultCPUs: containerSystemConfig.build.cpus,
            defaultMemory: containerSystemConfig.build.memory
        )

        let client = ContainerClient()
        let builderContainerId = ContainerBuild.Builder.builderContainerId
        if let existing = try? await client.get(id: builderContainerId) {
            let imageChanged = existing.configuration.image.reference != builderImage
            let cpuChanged = existing.configuration.resources.cpus != resources.cpus
            let memChanged = existing.configuration.resources.memoryInBytes != resources.memoryInBytes
            let needsRecreate = imageChanged || cpuChanged || memChanged
            switch existing.status {
            case .running:
                guard needsRecreate else { return }
                try await client.stop(id: existing.id)
                try await client.delete(id: existing.id)
            case .stopped:
                guard needsRecreate else {
                    try await bootstrapBuilderShim(client: client, id: existing.id)
                    return
                }
                try await client.delete(id: existing.id)
            case .stopping:
                throw ContainerizationError(.invalidState, message: "Builder is stopping; wait until it's fully stopped before rebuilding.")
            case .unknown:
                break
            }
        }

        let useRosetta = containerSystemConfig.build.rosetta
        let shimArguments = ["--debug", "--vsock", useRosetta ? nil : "--enable-qemu"].compactMap { $0 }

        try Utility.validEntityName(builderContainerId)

        // The slow part on first build. `fetch` streams size events only when it actually pulls —
        // a cached image resolves via `get` with no events — so the reporter emits its throttled
        // "Downloading builder image… N MB" progress lines exactly when a real download happens,
        // and stays silent otherwise (no misleading line on the cached path).
        let pullReporter = DownloadReporter(label: "Downloading builder image (\(builderImage))", onLog: onLog)
        let image = try await ClientImage.fetch(
            reference: builderImage,
            platform: builderPlatform,
            containerSystemConfig: containerSystemConfig,
            progressUpdate: pullReporter.handler
        )
        _ = try await image.getCreateSnapshot(platform: builderPlatform)

        let imageDesc = ImageDescription(reference: builderImage, descriptor: image.descriptor)
        let environment = try await image.config(for: builderPlatform).config?.env ?? []

        let processConfig = ProcessConfiguration(
            executable: "/usr/local/bin/container-builder-shim",
            arguments: shimArguments,
            environment: environment,
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )

        var config = ContainerConfiguration(id: builderContainerId, image: imageDesc, process: processConfig)
        config.resources = resources
        config.labels = [
            ResourceLabelKeys.plugin: "builder",
            ResourceLabelKeys.role: ResourceRoleValues.builder,
        ]
        config.capAdd = ["ALL"]
        config.mounts = [
            Filesystem(type: .tmpfs, source: "", destination: "/run", options: []),
            Filesystem(type: .virtiofs, source: exportsMount, destination: "/var/lib/container-builder-shim/exports", options: []),
        ]
        config.rosetta = useRosetta

        guard let defaultNetwork = try await NetworkClient().builtin else {
            throw ContainerizationError(.invalidState, message: "default network is not present")
        }
        config.networks = [
            AttachmentConfiguration(network: defaultNetwork.id, options: AttachmentOptions(hostname: builderContainerId))
        ]
        config.dns = ContainerConfiguration.DNSConfiguration()

        let kernel = try await ClientKernel.getDefaultKernel(for: .current)

        try await client.create(configuration: config, options: .default, kernel: kernel)
        try await bootstrapBuilderShim(client: client, id: builderContainerId)
    }

    /// Starts the `container-builder-shim` process inside a freshly created (or reused, stopped)
    /// builder container. Mirrors the CLI's private `startBuildKit` helper, but swaps `ProcessIO`
    /// for plain `stdio: [nil, nil, nil]` — matching the detached-bootstrap pattern used elsewhere
    /// in this file, since we don't need the shim's own stdio, only for it to be running.
    private func bootstrapBuilderShim(client: ContainerClient, id: String) async throws {
        do {
            var dynamicEnv: [String: String] = [:]
            if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
                dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
            }
            let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil], dynamicEnv: dynamicEnv)
            try await process.start()
        } catch {
            try? await client.stop(id: id)
            try? await client.delete(id: id)
            throw error
        }
    }

    /// Native (XPC/gRPC, no CLI shelling) implementation of `container build`. Dials (and
    /// auto-starts, if needed) the "buildkit" builder container, then drives the same
    /// `Builder.build(_:)` gRPC pipeline the CLI uses.
    ///
    /// Log capture: `Builder.build` has no structured output callback — output is written
    /// directly to `config.terminal?.handle ?? FileHandle.standardError`. Passing a `Terminal`
    /// captures output but also switches the remote builder into ANSI/cursor-redraw "tty" mode,
    /// which isn't line-log friendly. Passing `terminal: nil` instead gets clean, line-oriented
    /// "plain" output (the same mode the old CLI-based implementation requested via
    /// `--progress plain`) — written to *this process's* stderr, so we temporarily dup2 fd 2 to a
    /// pipe for the duration of the build and restore it afterward. Polling is paused for the same
    /// window since it's the only other plausible stderr writer in this process.
    override func buildImage(
        options: BuildOptions,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        // Guards against two overlapping builds corrupting each other's stderr redirection below
        // (see the dup2 discussion further down) — e.g. a Cancel that doesn't wait for the
        // in-flight build's cleanup to finish before the UI allows starting a new one.
        guard !isBuilding else {
            throw ContainerizationError(.invalidState, message: "A build is already in progress.")
        }
        isBuilding = true
        defer { isBuilding = false }

        // Validate all local, daemon-independent input up front — before touching the builder —
        // so a typo'd Dockerfile path or malformed --secret fails immediately instead of after
        // possibly waiting through a full builder auto-start (image fetch, VM boot, shim bootstrap).
        let dockerfilePath = try Self.resolveDockerfilePath(for: options)
        let dockerfileData = try Data(contentsOf: URL(fileURLWithPath: dockerfilePath))
        let dockerignoreData = try? Data(contentsOf: URL(fileURLWithPath: dockerfilePath + ".dockerignore"))
        let secretsData = try Self.resolveBuildSecrets(options.secrets)
        let tags = try Self.buildTags(for: options)
        let platforms = try Self.buildPlatforms(for: options)

        let containerSystemConfig = await resolvedSystemConfig()
        let builder = try await dialOrStartBuilder(containerSystemConfig: containerSystemConfig, cpus: options.cpus.map { Int64($0) }, memory: options.memory, onLog: onLog)

        let systemHealth = try await ClientHealthCheck.ping(timeout: .seconds(10))
        let buildID = UUID().uuidString
        let tempURL = systemHealth.appRoot.appendingPathComponent("builder").appendingPathComponent(buildID)
        try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let exportDestination = tempURL.appendingPathComponent("out.tar")
        let export = ContainerBuild.Builder.BuildExport(
            type: "oci",
            destination: exportDestination,
            additionalFields: [:],
            rawValue: "type=oci"
        )

        let config = ContainerBuild.Builder.BuildConfig(
            buildID: buildID,
            contentStore: RemoteContentStoreClient(),
            buildArgs: options.buildArgs.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            secrets: secretsData,
            contextDir: options.contextPath,
            dockerfile: dockerfileData,
            dockerignore: dockerignoreData,
            labels: options.labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            noCache: options.noCache,
            platforms: platforms,
            terminal: nil,
            tags: tags,
            target: options.target ?? "",
            quiet: false,
            exports: [export],
            cacheIn: [],
            cacheOut: [],
            pull: options.pull,
            containerSystemConfig: containerSystemConfig
        )

        pollTask?.cancel()
        defer { startPolling() }

        // Redirect this process's own stderr into a pipe for the duration of the build so we can
        // stream it into `onLog`, then always restore it — `builder.build` writes there directly
        // (see doc comment above), and leaving it redirected past this point risks blocking any
        // other stderr writer once the pipe's kernel buffer fills, since nothing drains it anymore.
        let originalStderr = dup(STDERR_FILENO)
        guard originalStderr >= 0 else {
            throw ContainerizationError(.internalError, message: "failed to duplicate stderr for build log capture")
        }
        let pipe = Pipe()
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        // A single dedicated reader for the pipe's entire lifetime, rather than a `readabilityHandler`
        // that gets installed then torn down mid-flight: `FileHandle.availableData` blocks until data
        // arrives or EOF, so looping it in one background task means there's no second, separate read
        // racing a `readabilityHandler = nil` teardown (which isn't guaranteed synchronous) to drain
        // whatever's left once the build finishes.
        let readHandle = pipe.fileHandleForReading
        let drainTask = Task.detached(priority: .userInitiated) {
            while true {
                let data = readHandle.availableData
                if data.isEmpty { return }
                guard let str = String(data: data, encoding: .utf8) else { continue }
                for line in str.components(separatedBy: .newlines) where !line.isEmpty {
                    await MainActor.run { onLog(line) }
                }
            }
        }

        func restoreStderrAndDrain() async {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            try? pipe.fileHandleForWriting.close()
            // Closing the write end above delivers EOF to the read loop, which then returns.
            await drainTask.value
        }

        do {
            try await builder.build(config)
        } catch {
            await restoreStderrAndDrain()
            throw error
        }
        await restoreStderrAndDrain()

        try Task.checkCancellation()

        let result = try await ClientImage.load(from: exportDestination.path, force: false)
        guard result.rejectedMembers.isEmpty else {
            throw ContainerizationError(.internalError, message: "Build archive contains invalid members: \(result.rejectedMembers)")
        }
        for image in result.images {
            try await image.unpack(platform: nil)
            for tag in tags {
                _ = try await image.tag(new: tag)
            }
        }

        await refresh()
    }

    /// Pure translation of `RunOptions` into the vendored `container` package's own
    /// `Flags.Process`/`Flags.Management`/`Flags.Resource`/`Flags.Registry` argument bags —
    /// the same types the CLI's `run`/`create` commands build from parsed command-line flags,
    /// constructed here directly so `Utility.containerConfigFromFlags` can be called in-process
    /// over the native XPC API instead of shelling out to the `container` binary.
    /// Treats an empty string the same as `nil` — the UI already nils out blank fields before
    /// constructing `RunOptions`, but mapping this defensively keeps a blank field from turning
    /// into e.g. `cwd: ""` (a real, if empty, override) instead of "unset, use the image default".
    nonisolated private static func nilIfEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// Shell fallback order tried when exec'ing into a running container — bash first (most
    /// full-featured), falling back to `sh` for minimal images (e.g. Alpine) that lack it.
    nonisolated static let execShellCandidates = ["/bin/bash", "/bin/sh"]

    /// Builds the `ProcessConfiguration` for an exec'd shell session from the container's own
    /// init process — same base the CLI's `container exec` uses (`ContainerExec.run()`) — so
    /// env/user/cwd match what a real exec would see, rather than starting from a blank slate.
    nonisolated static func execProcessConfiguration(basedOn initProcess: ProcessConfiguration, shell: String) -> ProcessConfiguration {
        var config = initProcess
        config.executable = shell
        config.arguments = []
        config.terminal = true
        return config
    }

    /// Builds the `ProcessConfiguration` for a machine's login shell — same approach the CLI's
    /// `container machine run` uses (`MachineRun.run()`): exec `/sbin.machine/init -s` (the
    /// machine bundle's init binary, which resolves the right shell for the user itself) inside
    /// the container backing the machine, rather than execing a shell directly. Takes `home`/
    /// `user` directly rather than a whole `MachineSnapshot` — those are the only two fields
    /// used, and it keeps this testable without constructing vendored OCI/platform fixtures.
    nonisolated static func machineShellProcessConfiguration(home: String, user: ProcessConfiguration.User) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
            arguments: ["-s"],
            environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            workingDirectory: home,
            terminal: true,
            user: user
        )
    }

    nonisolated static func runProcessFlags(for options: RunOptions) -> Flags.Process {
        Flags.Process(
            cwd: nilIfEmpty(options.workdir),
            env: options.env.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            envFile: options.envFile,
            gid: nil,
            interactive: options.interactive,
            tty: options.tty,
            uid: nil,
            ulimits: options.ulimits,
            user: nilIfEmpty(options.user)
        )
    }

    nonisolated static func runManagementFlags(for options: RunOptions) -> Flags.Management {
        let dns: Flags.DNS = options.noDns
            ? Flags.DNS(domain: nil, nameservers: [], options: [], searchDomains: [])
            : Flags.DNS(
                domain: nilIfEmpty(options.dnsDomain),
                nameservers: options.dns,
                options: options.dnsOptions,
                searchDomains: options.dnsSearch
            )
        return Flags.Management(
            arch: Arch.hostArchitecture().rawValue,
            capAdd: options.capAdd,
            capDrop: options.capDrop,
            cidfile: nilIfEmpty(options.cidFile) ?? "",
            detach: !options.attach,
            dns: dns,
            dnsDisabled: options.noDns,
            entrypoint: nilIfEmpty(options.entrypoint),
            initImage: nil,
            kernel: nil,
            labels: options.labels.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" },
            mounts: options.mounts,
            name: nilIfEmpty(options.name),
            networks: options.networks,
            os: "linux",
            platform: nilIfEmpty(options.platform),
            publishPorts: options.ports,
            publishSockets: [],
            readOnly: options.readOnly,
            remove: options.remove,
            rosetta: options.rosetta,
            runtime: nil,
            ssh: options.ssh,
            shmSize: nilIfEmpty(options.shmSize),
            tmpFs: options.tmpfs,
            useInit: options.initProcess,
            virtualization: options.virtualization,
            volumes: options.volumes
        )
    }

    nonisolated static func runResourceFlags(for options: RunOptions) -> Flags.Resource {
        Flags.Resource(cpus: options.cpus.map { Int64($0) }, memory: nilIfEmpty(options.memory))
    }

    nonisolated static func runRegistryFlags(for options: RunOptions) -> Flags.Registry {
        Flags.Registry(scheme: options.insecureRegistry ? "http" : "auto")
    }

    /// Native (XPC API, no CLI shelling) implementation of `container run`/`container create`.
    /// Reuses the vendored package's own `Utility.containerConfigFromFlags` — the same image
    /// fetch/unpack, kernel resolution, volume/network/DNS resolution the CLI itself runs — so
    /// this doesn't have to reimplement any of that. `start == false` stops after `create`
    /// (left provisioned, not bootstrapped). `start && !attach` bootstraps and starts detached.
    /// `start && attach` captures the container's own stdout via our own pipe and waits for exit
    /// — for one-shot commands like `pwd`. This app never attaches an interactive terminal.
    @discardableResult
    override func runContainer(options: RunOptions) async throws -> String {
        let id = Utility.createContainerID(name: options.name)
        try Utility.validEntityName(id)

        let client = ContainerClient()
        if (try? await client.get(id: id)) != nil {
            throw ContainerCLIError(exitCode: 1, message: "A container named \"\(id)\" already exists.")
        }

        let containerSystemConfig = await resolvedSystemConfig()
        let (containerConfig, kernel, initImage) = try await Utility.containerConfigFromFlags(
            id: id,
            image: options.reference,
            arguments: options.command,
            process: Self.runProcessFlags(for: options),
            management: Self.runManagementFlags(for: options),
            resource: Self.runResourceFlags(for: options),
            registry: Self.runRegistryFlags(for: options),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: 3),
            containerSystemConfig: containerSystemConfig,
            progressUpdate: { _ in },
            log: Self.log
        )

        let createOptions = ContainerCreateOptions(autoRemove: options.remove)
        try await client.create(configuration: containerConfig, options: createOptions, kernel: kernel, initImage: initImage)

        if let cidFile = options.cidFile, !cidFile.isEmpty {
            FileManager.default.createFile(
                atPath: cidFile,
                contents: id.data(using: .utf8),
                attributes: [.posixPermissions: 0o644]
            )
        }

        guard options.start else {
            await refresh()
            return ""
        }

        do {
            if !options.attach {
                let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
                try await process.start()
                await refresh()
                return ""
            }

            let pipe = Pipe()
            let process = try await client.bootstrap(id: id, stdio: [nil, pipe.fileHandleForWriting, pipe.fileHandleForWriting])
            try await process.start()
            // Close our copy of the write end now that the daemon holds its own duped fd —
            // otherwise our read end never sees EOF, since we're still holding it open too.
            try pipe.fileHandleForWriting.close()

            let (exitCode, output) = try await withTaskCancellationHandler {
                async let waitResult = process.wait()
                let capturedOutput: String = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
                    }
                }
                return (try await waitResult, capturedOutput)
            } onCancel: {
                Task { try? await process.kill(SIGTERM) }
            }

            // A cancelled run kills the process via SIGTERM above, which makes `process.wait()`
            // return a real (non-zero) exit code rather than throwing — check cancellation
            // explicitly so this surfaces as `CancellationError` (caught below, cleaned up, and
            // recognized by callers as "the user cancelled") instead of a misleading
            // "command failed" `ContainerCLIError`.
            try Task.checkCancellation()

            await refresh()
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if exitCode != 0 {
                throw ContainerCLIError(exitCode: exitCode, message: trimmed)
            }
            return trimmed
        } catch let cliError as ContainerCLIError {
            // A non-zero exit is a normal outcome, not an infra failure — the container ran and
            // already exited on its own, so leave it in place (matching the CLI's own behavior)
            // rather than deleting it.
            throw cliError
        } catch {
            try? await client.delete(id: id, force: true)
            throw error
        }
    }

    /// Same derivation `container machine create` uses when no `--name` is given: strip the
    /// image reference down to `<imageName>-<tag-or-digest>`. Kept pure/testable since the
    /// native API (unlike the CLI) doesn't derive this for us.
    nonisolated static func machineID(for options: MachineCreateOptions) throws -> String {
        if let name = options.name, !name.isEmpty {
            return name
        }
        let reference = try Reference.parse(options.reference)
        reference.normalize()
        let imageName = reference.name.components(separatedBy: "/").last!
        let suffix = reference.tag ?? reference.digest ?? "latest"
        return "\(imageName)-\(suffix)"
    }

    /// Pure translation of `MachineCreateOptions` into the vendored package's own
    /// `Flags.MachineManagement`/`Flags.Registry` — see `runManagementFlags` above for why this
    /// replaces CLI-argument-array construction. `Flags.MachineManagement` has no full
    /// memberwise init, so every property is assigned explicitly post-construction to move it
    /// out of ArgumentParser's unset `.definition` state (the same trap `Flags.ImageFetch()`'s
    /// empty init has).
    nonisolated static func machineManagementFlags(for options: MachineCreateOptions) -> Flags.MachineManagement {
        var management = Flags.MachineManagement()
        management.arch = Arch.hostArchitecture().rawValue
        management.os = "linux"
        management.platform = nilIfEmpty(options.platform)
        return management
    }

    nonisolated static func machineRegistryFlags(for options: MachineCreateOptions) -> Flags.Registry {
        Flags.Registry(scheme: options.insecureRegistry ? "http" : "auto")
    }

    /// Overrides to layer onto the system default `MachineConfig` via `MachineConfig.with(_:)` —
    /// the boot-time cpu/memory/home-mount settings, as opposed to the image/platform fields
    /// `machineManagementFlags` covers.
    nonisolated static func machineBootConfigOverrides(for options: MachineCreateOptions) -> [String: String] {
        var kwargs: [String: String] = [:]
        if let cpus = options.cpus { kwargs["cpus"] = "\(cpus)" }
        if let memory = nilIfEmpty(options.memory) { kwargs["memory"] = memory }
        if let homeMount = nilIfEmpty(options.homeMount) { kwargs["home-mount"] = homeMount }
        return kwargs
    }

    /// Native (XPC API, no CLI shelling) implementation of `container machine create`. Reuses
    /// `MachineClient.machineConfigFromFlags` for image fetch/unpack and machine config assembly,
    /// same as `runContainer` reuses `Utility.containerConfigFromFlags`.
    override func createMachine(options: MachineCreateOptions) async throws {
        let id = try Self.machineID(for: options)
        try Utility.validEntityName(id)

        let containerSystemConfig = await resolvedSystemConfig()
        let bootConfig = try containerSystemConfig.machine.with(Self.machineBootConfigOverrides(for: options))

        let client = MachineClient()
        let (config, resources) = try await MachineClient.machineConfigFromFlags(
            id: id,
            image: options.reference,
            management: Self.machineManagementFlags(for: options),
            registry: Self.machineRegistryFlags(for: options),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: 3),
            containerSystemConfig: containerSystemConfig,
            progressUpdate: { _ in }
        )
        // The image fetch/unpack above can take a while; bail before creating anything if the
        // caller (e.g. a cancelled "Create machine" sheet) no longer wants this.
        try Task.checkCancellation()

        do {
            try await client.create(configuration: config, resources: resources, bootConfig: bootConfig)
        } catch let error as ContainerizationError {
            if let cause = error.cause as? ContainerizationError, cause.isCode(.exists) {
                let hint = (options.name?.isEmpty ?? true) ? " (give it a name to avoid this)" : ""
                throw ContainerizationError(.exists, message: cause.message + hint)
            }
            throw error
        }

        // From here on, a machine exists — checked cancellation points below (rather than just
        // relying on setDefault/bootMachineNatively's own awaits) mean a cancelled create doesn't
        // silently keep going through setDefault/boot; on cancellation the catch below deletes the
        // just-created machine so it doesn't linger with no user-visible trace that it happened.
        // A genuine (non-cancellation) setDefault/boot failure leaves the machine in place instead —
        // bootMachineNatively already stops it on failure, and the user can retry via startMachine
        // rather than losing the fetched/unpacked image and having to recreate from scratch.
        do {
            try Task.checkCancellation()
            if options.setDefault {
                try await client.setDefault(id: id)
            }
            try Task.checkCancellation()
            if options.boot {
                try await bootMachineNatively(id: id, client: client)
            }
        } catch {
            if error is CancellationError {
                try? await client.delete(id: id)
            }
            await refresh()
            throw error
        }

        await refresh()
    }

    /// Boots a container machine and, on its very first boot, runs the in-VM init script that
    /// sets up the host user — without this, a freshly created machine boots but is unusable.
    /// This mirrors the CLI's own (non-public) `bootMachine` helper, but swaps `ProcessIO` (which
    /// wires to the CLI's own terminal) for a plain `stdio: [nil, nil, nil]` process — we don't
    /// need the init script's output, only its exit code, matching the detached-run pattern in
    /// `runContainer`. On failure, the machine is stopped to leave it in a clean state.
    @discardableResult
    private func bootMachineNatively(id: String, client: MachineClient) async throws -> MachineSnapshot {
        var dynamicEnv: [String: String] = [:]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
        }
        let snapshot = try await client.boot(id: id, dynamicEnv: dynamicEnv)
        guard !snapshot.initialized else { return snapshot }

        do {
            guard let containerId = snapshot.containerId else {
                throw ContainerizationError(.invalidState, message: "container machine is running but has no container ID")
            }
            let processConfig = ProcessConfiguration(
                executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
                arguments: ["-u"],
                environment: snapshot.configuration.processEnvironment,
                terminal: false
            )
            let process = try await ContainerClient().createProcess(
                containerId: containerId,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()
            let exitCode = try await process.wait()
            guard exitCode == 0 else {
                throw ContainerizationError(.invalidState, message: "container machine failed to create user")
            }
        } catch {
            try? await client.stop(id: snapshot.id)
            throw error
        }
        return snapshot
    }

    override func pullImage(reference: String, platform: String? = nil, insecure: Bool = false, progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {
        let config = await resolvedSystemConfig()
        let ociPlatform: Platform? = try {
            guard let p = platform, !p.isEmpty else { return nil }
            return try Platform(from: p)
        }()
        let image = try await ClientImage.pull(
            reference: reference,
            platform: ociPlatform,
            scheme: insecure ? .http : .auto,
            containerSystemConfig: config,
            progressUpdate: progress
        )
        onUnpacking?()
        try await image.unpack(platform: ociPlatform)
        await refresh()
    }
}
