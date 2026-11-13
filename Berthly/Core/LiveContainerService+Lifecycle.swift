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
    // MARK: - Lifecycle actions

    // Call convention for `bootstrap`/`createProcess` `stdio:`: the XPC layer *closes every fd it
    // receives* (`XPCMessage.set(key:value:FileHandle)`), taking ownership. So pass `nil` for any
    // stream you don't need to capture (the common case here), and NEVER hand it a retained
    // `Pipe`'s `fileHandleForReading/Writing` — the `Pipe` (`closeOnDealloc: true`) would then close
    // that fd a second time on deinit, and once the number is reused the stale close clobbers an
    // unrelated descriptor (this is what broke container logs, fixed in 94df4fb). When you *do* need
    // to capture output, wrap the handed-off end `closeOnDealloc: false` and keep the opposite end
    // yourself — see the attach branch of `runContainer` and `TerminalSession.makeExecPipe`.
    func startContainerImpl(_ id: String) async throws {
        let client = ContainerClient()
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
        await refresh()
    }

    func stopContainerImpl(_ id: String) async throws {
        try await ContainerClient().stop(id: id)
        await refresh()
    }

    func restartContainerImpl(_ id: String) async throws {
        let client = ContainerClient()
        try await client.stop(id: id)
        let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
        try await process.start()
        await refresh()
    }

    // Fixed SIGKILL (the CLI's `container kill` default): the UI offers force-kill as the
    // unwedge action, not a general signal sender — other signals stay a CLI affair.
    func killContainerImpl(_ id: String) async throws {
        try await ContainerClient().kill(id: id, signal: "KILL")
        await refresh()
    }

    /// Default filename the export save panel suggests: `<name>-rootfs.tar` distinguishes a
    /// container filesystem dump from the image archives `saveImages` writes (`<name>.tar`).
    nonisolated static func exportArchiveFilename(for containerName: String) -> String {
        let sanitized = containerName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(sanitized)-rootfs.tar"
    }

    /// Native replication of `container export -o`: the daemon writes the archive to a private
    /// temp path first, which is moved into place only on success — a failed export never leaves
    /// a truncated tar at the user's chosen destination.
    func exportContainerImpl(_ id: String, to path: String) async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archive = tempDir.appendingPathComponent("archive.tar")
        try await ContainerClient().export(id: id, archive: archive)

        // The save panel already confirmed replacement — a leftover file would fail the move.
        let destination = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: archive, to: destination)
    }

    /// The CLI's `ContainerCommit` flow: export the rootfs, wrap it as a one-layer OCI archive
    /// built from the source image's config, then load it. Nothing daemon-side is new, so this
    /// needs no version gate beyond the running-container export Berthly's floor already has.
    func commitContainerImpl(_ id: String, reference: String) async throws -> String {
        let client = ContainerClient()
        let config = await resolvedSystemConfig()
        let target = try ClientImage.normalizeReference(reference, containerSystemConfig: config)
        let snapshot = try await client.get(id: id)
        let platform = snapshot.configuration.platform
        let sourceImage = try await ClientImage(description: snapshot.configuration.image).config(for: platform)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootfs = tempDir.appendingPathComponent("rootfs.tar")
        try await client.export(id: id, archive: rootfs)
        let archive = try ContainerCommitArchive.create(
            from: rootfs,
            in: tempDir,
            reference: target,
            platform: platform,
            imageConfig: ContainerCommitArchive.imageConfig(
                process: snapshot.configuration.initProcess,
                containerLabels: snapshot.configuration.labels,
                stopSignal: snapshot.configuration.stopSignal,
                sourceImage: sourceImage
            ),
            sourceImage: sourceImage
        )
        _ = try await loadImages(from: archive.path)
        return target
    }

    func deleteContainerImpl(_ id: String) async throws {
        try await ContainerClient().delete(id: id)
        if pinnedContainerIDs.remove(id) != nil {
            pinnedContainerOrder.removeAll { $0 == id }
            savePinnedItems()
        }
        await refresh()
    }

    func copyFilesImpl(direction: CopyDirection, containerID: String, hostPath: String, containerPath: String) async throws {
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

    func startMachineImpl(_ id: String) async throws {
        // Routes through the same helper `createMachine` uses, so user setup runs on every boot.
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

    func stopMachineImpl(_ id: String) async throws {
        try await MachineClient().stop(id: id)
        await refresh()
    }

    func deleteMachineImpl(_ id: String) async throws {
        try await MachineClient().delete(id: id)
        if pinnedMachineIDs.remove(id) != nil {
            pinnedMachineOrder.removeAll { $0 == id }
            savePinnedItems()
        }
        await refresh()
    }

    func setDefaultMachineImpl(_ id: String) async throws {
        try await MachineClient().setDefault(id: id)
        await refresh()
    }

    /// The `key=value` settings `container machine set` would receive for `options` — only
    /// fields the user actually set are included, so untouched settings keep their current
    /// values (`MachineConfig.with` merges over the machine's existing boot config).
    nonisolated static func machineSetKwargs(for options: MachineUpdateOptions) -> [String: String] {
        var kwargs: [String: String] = [:]
        if let cpus = options.cpus {
            kwargs["cpus"] = String(cpus)
        }
        if let memory = options.memory?.trimmingCharacters(in: .whitespaces), !memory.isEmpty {
            kwargs["memory"] = memory
        }
        if let homeMount = options.homeMount, !homeMount.isEmpty {
            kwargs["home-mount"] = homeMount
        }
        return kwargs
    }

    /// Native replication of `container machine set`: merges the changed settings over the
    /// machine's current boot config and persists it. The daemon applies the new config on the
    /// machine's next boot — a running machine is deliberately left running.
    func updateMachineImpl(_ id: String, options: MachineUpdateOptions) async throws {
        let kwargs = Self.machineSetKwargs(for: options)
        guard !kwargs.isEmpty else { return }
        let client = MachineClient()
        let snapshot = try await client.inspect(id: id)
        let newConfig = try snapshot.bootConfig.with(kwargs)
        try await client.setConfig(id: id, bootConfig: newConfig)
        await refresh()
    }

    /// Native replication of `container builder start` with default resources: reuses the same
    /// create-or-bootstrap path builds go through (`startBuilderContainer`), so a matching stopped
    /// builder is booted in place and a config-drifted one (image/cpu/memory/ssh — see the `ssh:
    /// false` note below) is recreated. Log output is dropped — the row's spinner covers the
    /// (fast, image-already-present) boot; first-ever builder creation with its image download
    /// normally happens via a build, which does stream logs.
    func startBuilderImpl(_ id: String) async throws {
        let config = await resolvedSystemConfig()
        // Matches the CLI's plain `container builder start`, which has no --ssh flag and so
        // always passes ssh: false to BuilderStart.start() — an ssh-enabled builder started
        // manually here (rather than by a build requesting it) gets recreated without forwarding,
        // same as upstream.
        try await startBuilderContainer(containerSystemConfig: config, cpus: nil, memory: nil, ssh: false, onLog: { _ in })
        await refresh()
    }

    func stopBuilderImpl(_ id: String) async throws {
        try await ContainerClient().stop(id: id)
        await refresh()
    }

    func deleteBuilderImpl(_ id: String) async throws {
        try await ContainerClient().delete(id: id)
        await refresh()
    }

    func deleteImageImpl(_ reference: String) async throws {
        try await ClientImage.delete(reference: reference)
        await refresh()
    }

    func deleteVolumeImpl(_ name: String) async throws {
        try await ClientVolume.delete(name: name)
        await refresh()
    }

    func deleteNetworkImpl(_ id: String) async throws {
        try await NetworkClient().delete(id: id)
        await refresh()
    }

    func createVolumeImpl(options: VolumeCreateOptions) async throws {
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

    /// The daemon's hard bounds on a volume's `--size`, verified against a live daemon:
    /// below 1 MiB it rejects with "volume size too small: minimum 1MiB"; at/above 16 TiB the
    /// ext4 layer rejects with "cannot set filesystem size to N bytes" (4 KiB-block ceiling).
    nonisolated static let minVolumeSizeBytes = 1_048_576                    // 1 MiB
    nonisolated static let maxVolumeSizeBytes = 16 * 1_099_511_627_776 - 1   // just under 16 TiB

    /// Pure/testable: validates the size string a user typed in the create sheet, pre-empting the
    /// daemon's own error round-trips with friendlier inline messages. Returns `nil` when the input
    /// is acceptable (including empty, which means "use the 512 GB default"), or a message otherwise.
    /// Suffixes are binary (`1M` == 1 MiB == 1 048 576 bytes), matching the daemon.
    nonisolated static func validateVolumeSize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }  // blank → daemon default
        guard let bytes = parseVolumeSizeBytes(trimmed) else {
            return "Enter a size like 10G, 512M, or 2T."
        }
        if bytes < minVolumeSizeBytes { return "Minimum volume size is 1 MB." }
        if bytes > maxVolumeSizeBytes { return "Maximum volume size is just under 16 TB." }
        return nil
    }

    /// Parses `<number><K|M|G|T|P>?` (binary suffixes, case-insensitive; no suffix means bytes)
    /// into a byte count, or `nil` if it isn't a well-formed size. Mirrors the daemon's parser.
    nonisolated static func parseVolumeSizeBytes(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let multipliers: [Character: Int] = [
            "k": 1_024, "m": 1_048_576, "g": 1_073_741_824,
            "t": 1_099_511_627_776, "p": 1_125_899_906_842_624
        ]
        let last = s[s.index(before: s.endIndex)]
        if let mult = multipliers[Character(last.lowercased())] {
            let numberPart = String(s.dropLast())
            guard let value = Double(numberPart), value > 0, value.isFinite else { return nil }
            let bytes = value * Double(mult)
            guard bytes.isFinite, bytes < Double(Int.max) else { return nil }
            return Int(bytes)
        }
        // No suffix: a plain byte count (integers only, matching the daemon).
        guard let bytes = Int(s), bytes > 0 else { return nil }
        return bytes
    }

    func createNetworkImpl(options: NetworkCreateOptions) async throws {
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

    // MARK: - Live stats

    /// Polls the daemon's `stats` endpoint every 2s and reduces the cumulative counters to
    /// display samples via `ContainerStatsDeltaTracker`. A failed read (container stopping,
    /// stats momentarily unavailable) yields nothing and keeps polling; the consumer's task
    /// cancellation ends the loop.
    func containerStatsStreamImpl(id: String) -> AsyncStream<ContainerStatsSample> {
        AsyncStream { continuation in
            let task = Task {
                var tracker = ContainerStatsDeltaTracker()
                while !Task.isCancelled {
                    if let stats = try? await ContainerClient().stats(id: id) {
                        continuation.yield(tracker.sample(
                            cpuUsageUsec: stats.cpuUsageUsec,
                            memoryUsageBytes: stats.memoryUsageBytes,
                            networkRxBytes: stats.networkRxBytes,
                            networkTxBytes: stats.networkTxBytes,
                            at: Date()
                        ))
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
