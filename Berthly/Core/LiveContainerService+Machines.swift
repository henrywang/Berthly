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
    /// `Flags.MachineManagement`/`Flags.Registry` — see `runManagementFlags` for why this
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

    /// `nil` fields keep upstream's default: the host user's name/uid/gid and `/home/<user>`. Same
    /// explicit-assignment reason as `machineManagementFlags` — `Flags.MachineUser` (1.6.0,
    /// apple/container#2322) has only an empty init.
    nonisolated static func machineUserFlags(for options: MachineCreateOptions) -> Flags.MachineUser {
        var user = Flags.MachineUser()
        user.user = nilIfEmpty(options.user)
        user.uid = options.uid
        user.gid = options.gid
        user.home = nilIfEmpty(options.home)
        return user
    }

    /// `MachineUserSetup.script` exits non-zero only when the image already has a different
    /// account with this uid or username, or something at the home path. Its stderr isn't captured
    /// (it would race the guest's output relay after exit), so name the account instead.
    nonisolated static func machineUserSetupFailureMessage(username: String, uid: UInt32, home: String) -> String {
        "container machine failed to create user '\(username)' (UID \(uid)): the image may already "
            + "have a different account with that UID or username, or something at \(home)"
    }

    nonisolated static func machineRegistryFlags(for options: MachineCreateOptions) -> Flags.Registry {
        // See runRegistryFlags: "auto" is gone (apple/container#2100), one scheme covers both the
        // image and init-image fetch, so the insecure toggle is the only path to http here.
        Flags.Registry(scheme: options.insecureRegistry ? "http" : "https")
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
    func createMachineImpl(options: MachineCreateOptions, onLog: (@MainActor (String) -> Void)?) async throws {
        let id = try Self.machineID(for: options)
        guard ManagedContainer.nameValid(id) else {
            throw ContainerizationError(.invalidArgument, message: "machine ID \(id) is not a valid machine ID")
        }

        let containerSystemConfig = await resolvedSystemConfig()
        let bootConfig = try containerSystemConfig.machine.with(Self.machineBootConfigOverrides(for: options))

        let client = MachineClient()
        let reporter = onLog.map { onLog in
            DownloadReporter(label: "Fetching image", onLog: onLog)
        }
        let config = try await MachineClient.machineConfigFromFlags(
            id: id,
            image: options.reference,
            management: Self.machineManagementFlags(for: options),
            user: Self.machineUserFlags(for: options),
            registry: Self.machineRegistryFlags(for: options),
            imageFetch: Flags.ImageFetch(maxConcurrentDownloads: 3),
            containerSystemConfig: containerSystemConfig,
            progressUpdate: reporter?.handler ?? Self.noopProgressHandler
        )
        // The image fetch/unpack above can take a while; bail before creating anything if the
        // caller (e.g. a cancelled "Create machine" sheet) no longer wants this.
        try Task.checkCancellation()

        do {
            try await client.create(configuration: config, bootConfig: bootConfig)
        } catch let error as ContainerizationError {
            if let cause = error.cause as? ContainerizationError, cause.isCode(.exists) {
                let hint = (options.name?.isEmpty ?? true) ? " (give it a name to avoid this)" : ""
                throw ContainerizationError(.exists, message: cause.message + hint)
            }
            throw error
        }

        // A host's transport insecurity isn't tied to what you pulled from it — remember it here
        // too so a later container pull/push against the same registry doesn't need re-asking.
        if options.insecureRegistry, let host = ImageStaleness.registryHost(for: options.reference) {
            Self.rememberInsecureHost(host)
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

    /// Boots a container machine and runs the in-VM user setup for the host user (see
    /// `machineUserSetupProcessConfiguration`) — without it, a fresh machine boots but is unusable.
    /// This mirrors the CLI's own (non-public) `bootMachine` helper, but swaps `ProcessIO` (which
    /// wires to the CLI's own terminal) for a plain `stdio: [nil, nil, nil]` process — we don't
    /// need the init script's output, only its exit code, matching the detached-run pattern in
    /// `runContainer`. On failure, the machine is stopped to leave it in a clean state.
    @discardableResult
    func bootMachineNatively(id: String, client: MachineClient) async throws -> MachineSnapshot {
        var dynamicEnv: [String: String] = [:]
        if let sshAuthSock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] {
            dynamicEnv["SSH_AUTH_SOCK"] = sshAuthSock
        }
        let snapshot = try await client.boot(id: id, dynamicEnv: dynamicEnv)
        let processConfig = Self.machineUserSetupProcessConfiguration(
            environment: snapshot.configuration.processEnvironment
        )

        do {
            guard let containerId = snapshot.containerId else {
                throw ContainerizationError(.invalidState, message: "container machine is running but has no container ID")
            }
            let process = try await ContainerClient().createProcess(
                containerId: containerId,
                processId: UUID().uuidString.lowercased(),
                configuration: processConfig,
                stdio: [nil, nil, nil]
            )
            try await process.start()
            let exitCode = try await process.wait()
            guard exitCode == 0 else {
                let account = snapshot.configuration.userSetup
                throw ContainerizationError(.invalidState, message: Self.machineUserSetupFailureMessage(
                    username: account.username, uid: account.uid, home: account.home
                ))
            }
        } catch {
            try? await client.stop(id: snapshot.id)
            throw error
        }
        return snapshot
    }
}
