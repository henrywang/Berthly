// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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
import Darwin
import Foundation
import Logging
import MachineAPIClient
import NIOCore
import NIOHTTP1
import NIOPosix
import TerminalProgress
internal import ContainerPersistence
internal import ContainerPlugin

extension LiveContainerService {
    // MARK: - Polling

    func startPolling() {
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

    func poll() async {
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
            // Piggybacked here (not its own timer) so checks only happen while connected; the
            // isCheckDue gate keeps the registry traffic at on-connect + every 6h, never per tick.
            // The Settings toggle only gates this automatic path — manual checks (Images
            // toolbar) and the recreate action always work regardless.
            if case .connected = daemonState,
               ImageStaleness.automaticCheckEnabled(userDefaultValue: UserDefaults.standard.object(forKey: "checkImagesForUpdates")),
               ImageStaleness.isCheckDue(lastCheck: lastImageUpdateCheck, now: .now) {
                Task { await checkForImageUpdates() }
            }
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

    /// What `startDaemon()`'s connect-phase failure should do. Cancelling the connect phase doesn't
    /// undo the launchd registration/kickstart already issued, so `.repoll` lets a fresh `poll()`
    /// report the real state instead of guessing; a bare catch-all used to report `runOperation`'s
    /// Cancel button as a failure.
    enum StartDaemonFailureOutcome: Equatable {
        case repoll
        case reportError(String)
    }

    nonisolated static func startDaemonFailureOutcome(for error: Error) -> StartDaemonFailureOutcome {
        error is CancellationError ? .repoll : .reportError(error.localizedDescription)
    }

    /// Native `container system start`: registers (or restarts) the apiserver launchd service, waits
    /// for it, and installs the vminit image and default kernel on first run without the CLI's
    /// "install the kernel? [Y/n]" prompt; there's no terminal to answer it, and a daemon without a
    /// kernel can't run anything.
    func startDaemonImpl(onLog: (@MainActor (String) -> Void)?) async {
        guard !isStarting, !isStopping else { return }
        guard FileManager.default.fileExists(atPath: Self.apiServerExecutablePath) else {
            daemonState = .notInstalled
            return
        }
        isStarting = true
        daemonState = .connecting
        lastStartupWarning = nil

        do {
            onLog?("Starting container-apiserver…")
            try await launchDaemonIfNeeded()
            onLog?("Waiting for the daemon to respond…")
            try await pingDaemonWithRecovery(onLog: onLog)
            onLog?("Daemon responded — verifying the machine service…")
            _ = try await MachineClient().list()
        } catch {
            // This is also what makes `installContainer`/`upgradeContainer`'s trailing
            // `startDaemon()` call behave correctly on cancel: since this method never throws,
            // returning cleanly on `.repoll` (rather than reporting an error) means the caller
            // doesn't see one either.
            switch Self.startDaemonFailureOutcome(for: error) {
            case .repoll:
                isStarting = false
                await poll()
                return
            case .reportError(let message):
                daemonState = .error(message)
                isStarting = false
                return
            }
        }

        let containerSystemConfig = await resolvedSystemConfig()
        await installVminitImageIfNeeded(containerSystemConfig: containerSystemConfig, onLog: onLog)
        await installDefaultKernelIfNeeded(containerSystemConfig: containerSystemConfig, onLog: onLog)

        // Clear before polling — `poll()` no-ops while `isStarting` is true, so this must happen
        // before the call below, not in a `defer` (which wouldn't fire until after `poll()` returns).
        isStarting = false
        await poll()
    }

    /// Native `container system stop` (mirrors `SystemStop.swift`): stops every container on the
    /// machine, including CLI-launched and machine-backed ones, then deregisters every
    /// `com.apple.container.*` launchd service. It doesn't confirm, so every UI entry point must make
    /// that blast radius explicit first.
    func stopDaemonImpl() async {
        // `isStopping` makes the 5-second `poll()` timer stand down during a stop that can take 20+
        // seconds (see the guard in `poll()`); `isStarting` keeps a stop from overlapping a start.
        // Logged because a stuck flag from a call that never reached its `defer` would otherwise look
        // like the toggle doing nothing.
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

    /// Registers the `container-apiserver` launchd service with `SystemStart.run()`'s plist.
    /// `ServiceManager.register` (`launchctl bootstrap`) is a no-op for an already-loaded label and
    /// won't restart a stopped one, so an already-registered label is kickstarted instead.
    /// `nonisolated` so the synchronous `launchctl`/file I/O runs on the cooperative pool instead of
    /// freezing the main thread.
    private nonisolated func launchDaemonIfNeeded() async throws {
        // Matches `SystemStart.run()`'s first line: refresh the read-only copy of the user's
        // config that the apiserver itself reads at startup.
        try ConfigurationLoader.copyConfigurationToReadOnly()

        let domain = try ServiceManager.getDomainString()
        let fullLabel = "\(domain)/\(Self.apiServerLabel)"
        // A throwing check falls through to register(), a no-op for a loaded label;
        // `pingDaemonWithRecovery`'s kickstart retry covers a wrong guess either way.
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

    /// Pings the apiserver, with one kickstart-and-retry if the first ping fails: the real recovery
    /// when `launchDaemonIfNeeded` picks the wrong branch (register is a silent no-op for an
    /// already-loaded but stopped label).
    private nonisolated func pingDaemonWithRecovery(onLog: (@MainActor (String) -> Void)? = nil) async throws {
        do {
            _ = try await ClientHealthCheck.ping()
        } catch {
            await onLog?("Daemon didn't respond — restarting it and trying again…")
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
        // Static line up front: unlike the builder pull, this download can report no size events at
        // all (a resolved but not unpacked layer set, or a failure before the first size event), which
        // would leave the user with silence until "installed" or an error.
        onLog?("Downloading base container filesystem (\(reference))…")
        let reporter = onLog.map { onLog in
            DownloadReporter(label: "Downloading base container filesystem (\(reference))", onLog: onLog)
        }
        do {
            let image = try await ClientImage.pull(
                reference: reference,
                platform: nil,
                // Apple's registry — always https. Not routed through RegistrySchemeResolver so a
                // user's internal DNS domain can't accidentally match this fixed reference.
                scheme: .https,
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
    /// `startDaemonImpl` for why). Soft-fails like `installVminitImageIfNeeded`.
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
                expectedDigest: containerSystemConfig.kernel.digest,
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
}
