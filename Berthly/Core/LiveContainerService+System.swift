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
    // MARK: - System page

    func fetchDiskUsageImpl() async throws {
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

    /// Pure stopped-container selection. Only ordinary stopped containers are eligible; machine,
    /// builder, and cluster node containers are excluded even when stopped — deleting a stopped VM
    /// or cluster node is irreversible data loss (see `PruneContainerInfo.isInfrastructure`).
    nonisolated static func deletableStoppedContainerIDs(_ containers: [PruneContainerInfo]) -> [String] {
        containers.filter { $0.isStopped && !$0.isInfrastructure }.map(\.id)
    }

    /// Takes the container list as a parameter (rather than fetching it here) so `pruneAll()` can
    /// share one fetch with `pruneStoppedContainers()` instead of each phase fetching its own.
    func pruneImages(allContainers: [ContainerSnapshot]) async throws -> PruneResult {
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

    /// Takes the container list as a parameter (rather than fetching it here) so `pruneAll()` can
    /// share one fetch with `pruneImages()` instead of each phase fetching its own.
    func pruneStoppedContainers(allContainers: [ContainerSnapshot]) async throws -> PruneResult {
        let client = ContainerClient()
        // Machine-backed containers, identified the same way `refreshAll()` separates them: a
        // container whose id is a machine's `containerId`. Builders are identified by the same
        // label server-side filter that populates the `builders` list (`fetchBuilderSnaps()`), and
        // cluster nodes by the same label check that hides them from the Compute list
        // (`isClusterNode`), so this can never disagree with what those UIs themselves show. All
        // three are infrastructure and must never be deleted, even when stopped.
        //
        // Unlike `refreshAll()`'s best-effort `try?` (a display refresh can tolerate showing stale
        // data), a failure here must abort the whole prune rather than silently treating every
        // machine/builder/cluster container as ordinary — proceeding with an empty infrastructure
        // set on a transient XPC error would risk deleting a stopped VM, builder, or cluster node.
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
                        || Self.isClusterNode(labels: $0.configuration.labels)
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

    /// Pure unused-volume selection, same shape as `unusedImageReferences`: the caller passes
    /// mounted-volume names from the *full* container list (running or stopped), so a volume a
    /// stopped container still mounts is protected — matching both the CLI's `volume prune` and
    /// the daemon's volume `reclaimable` definition.
    nonisolated static func unusedVolumeNames(allVolumeNames: [String], mountedVolumeNames: [String]) -> [String] {
        let mounted = Set(mountedVolumeNames)
        return allVolumeNames.filter { !mounted.contains($0) }
    }

    /// Pure unused-network selection. A network is prunable only when no container's configuration
    /// references it *and* it isn't the daemon's built-in default (which must survive even with
    /// nothing attached) — mirroring the CLI's `network prune`.
    nonisolated static func prunableNetworkIDs(_ networks: [PruneNetworkInfo], connectedNetworkIDs: [String]) -> [String] {
        let connected = Set(connectedNetworkIDs)
        return networks.filter { !$0.isBuiltin && !connected.contains($0.id) }.map(\.id)
    }

    /// Native replication of `container volume prune`: deletes every volume no container mounts.
    /// In-use is judged from every container's *configuration* (running or stopped), so a volume a
    /// stopped container still references survives — its data becomes reachable again the moment
    /// that container starts.
    func pruneVolumesImpl() async throws -> PruneResult {
        let allVolumes = try await ClientVolume.list()
        let allContainers = try await ContainerClient().list()
        let mounted = allContainers.flatMap { snap in
            snap.configuration.mounts.compactMap { $0.isVolume ? $0.volumeName : nil }
        }
        let names = Self.unusedVolumeNames(
            allVolumeNames: allVolumes.map(\.name),
            mountedVolumeNames: mounted
        )

        var result = PruneResult()
        for name in names {
            do {
                let size = try await ClientVolume.volumeDiskUsage(name: name)  // tally before deleting
                try await ClientVolume.delete(name: name)
                result.volumesFreedBytes += size
                result.deletedVolumeCount += 1
            } catch {
                result.failedCount += 1
                Self.log.warning("pruneVolumes: failed to delete volume", metadata: ["name": "\(name)", "error": "\(error)"])
            }
        }

        await refresh()
        try? await fetchDiskUsage()
        return result
    }

    /// Native replication of `container network prune`: deletes every non-builtin network no
    /// container's configuration references. Frees no disk space — networks are vmnet state, not
    /// storage — so the result carries only a count.
    func pruneNetworksImpl() async throws -> PruneResult {
        let networkClient = NetworkClient()
        let allNetworks = try await networkClient.list()
        let allContainers = try await ContainerClient().list()
        let connected = allContainers.flatMap { $0.configuration.networks.map(\.network) }
        let ids = Self.prunableNetworkIDs(
            allNetworks.map { PruneNetworkInfo(id: $0.id, isBuiltin: $0.isBuiltin) },
            connectedNetworkIDs: connected
        )

        var result = PruneResult()
        for id in ids {
            do {
                try await networkClient.delete(id: id)
                result.deletedNetworkCount += 1
            } catch {
                // Can race a concurrent `container run` attaching to a network selected above —
                // the daemon refuses the delete, which is the safe outcome; report, don't fail.
                result.failedCount += 1
                Self.log.warning("pruneNetworks: failed to delete network", metadata: ["id": "\(id)", "error": "\(error)"])
            }
        }

        await refresh()
        return result
    }

    func pruneAllImpl() async -> CleanUpAllResult {
        let allContainers: [ContainerSnapshot]
        do {
            allContainers = try await ContainerClient().list()
        } catch {
            // The one fetch both phases would share failed outright — neither can proceed.
            let message = error.localizedDescription
            return CleanUpAllResult(failureMessages: [
                "Removing unused images failed: \(message)",
                "Removing stopped containers failed: \(message)"
            ])
        }

        var combined = PruneResult()
        var failures: [String] = []
        do {
            combined += try await pruneImages(allContainers: allContainers)
        } catch {
            failures.append("Removing unused images failed: \(error.localizedDescription)")
        }
        do {
            combined += try await pruneStoppedContainers(allContainers: allContainers)
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

    func fetchKernelInfoImpl() async throws {
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        kernelInfo = Self.mapKernelInfo(kernel)
    }

    nonisolated static func mapKernelInfo(_ kernel: Kernel) -> KernelInfo {
        KernelInfo(path: kernel.path.path, platform: "\(kernel.platform.os.rawValue)/\(kernel.platform.architecture.rawValue)")
    }

    func fetchSystemConfigImpl() async throws {
        let config = await resolvedSystemConfig()
        systemConfigInfo = Self.mapSystemConfig(config)
    }

    nonisolated static func mapSystemConfig(_ config: ContainerSystemConfig) -> SystemConfigInfo {
        SystemConfigInfo(
            vminitImage: config.vminit.image,
            kernelBinaryPath: config.kernel.binaryPath,
            kernelURL: config.kernel.url.absoluteString,
            kernelDigest: config.kernel.digest,
            builderImage: config.build.image
        )
    }

    /// Flattens the resolved system configuration into the dotted key/value rows `container
    /// system property list` prints — every key, defaults included, in the CLI's TOML section
    /// order. Unset optionals render as an em dash rather than being omitted, so the list always
    /// shows the full settable surface.
    nonisolated static func mapSystemProperties(_ config: ContainerSystemConfig) -> [SystemProperty] {
        let containerDNS = config.container.dns
        return [
            SystemProperty(key: "build.rosetta", value: String(config.build.rosetta)),
            SystemProperty(key: "build.cpus", value: String(config.build.cpus)),
            SystemProperty(key: "build.memory", value: String(describing: config.build.memory)),
            SystemProperty(key: "build.image", value: config.build.image),
            SystemProperty(key: "container.cpus", value: String(config.container.cpus)),
            SystemProperty(key: "container.memory", value: String(describing: config.container.memory)),
            SystemProperty(key: "container.dns.domain", value: containerDNS?.domain ?? "–"),
            SystemProperty(key: "container.dns.nameservers", value: propertyListValue(containerDNS?.nameservers)),
            SystemProperty(key: "container.dns.searchDomains", value: propertyListValue(containerDNS?.searchDomains)),
            SystemProperty(key: "container.dns.options", value: propertyListValue(containerDNS?.options)),
            SystemProperty(key: "dns.domain", value: config.dns.domain ?? "–"),
            SystemProperty(key: "kernel.binaryPath", value: config.kernel.binaryPath),
            SystemProperty(key: "kernel.url", value: config.kernel.url.absoluteString),
            SystemProperty(key: "machine.cpus", value: String(config.machine.cpus)),
            SystemProperty(key: "machine.memory", value: String(describing: config.machine.memory)),
            SystemProperty(key: "machine.home-mount", value: config.machine.homeMount.rawValue),
            SystemProperty(key: "machine.virtualization", value: String(config.machine.virtualization)),
            SystemProperty(key: "network.subnet", value: config.network.subnet.map { String(describing: $0) } ?? "–"),
            SystemProperty(key: "network.subnetv6", value: config.network.subnetv6.map { String(describing: $0) } ?? "–"),
            SystemProperty(key: "registry.domain", value: config.registry.domain),
            SystemProperty(key: "vminit.image", value: config.vminit.image)
        ]
    }

    /// An empty list renders as the em dash too: for `[container.dns]` it means the same as
    /// unset (no default; the runtime falls back to the network gateway's resolver).
    private nonisolated static func propertyListValue(_ values: [String]?) -> String {
        guard let values, !values.isEmpty else { return "–" }
        return values.joined(separator: ", ")
    }

    func fetchSystemPropertiesImpl() async {
        systemProperties = Self.mapSystemProperties(await resolvedSystemConfig())
    }

    /// Streams `container`'s own daemon logs via unified logging (`/usr/bin/log stream`) — there's
    /// no XPC route for this (the CLI itself just shells out to `log`, see `SystemLogs.swift`), so
    /// this is a narrow, deliberate exception to the "no `Process()` calls" migration: it targets a
    /// stable Apple system binary, not the `container` CLI, so a container CLI bug still can't
    /// affect it.
    private nonisolated static let daemonLogPredicate = "subsystem = 'com.apple.container'"

    func streamDaemonLogsImpl(onLine: @MainActor @escaping (String) -> Void) async throws {
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
            "stream", "--info",
            "--style", "ndjson",
            "--predicate", Self.daemonLogPredicate
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
            "show", "--last", "1h", "--info",
            "--style", "ndjson",
            "--predicate", daemonLogPredicate
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

    /// Launches `/usr/bin/log` with the given arguments (`show …`/`stream …` here), piping stdout
    /// back for line-by-line reading — the shared setup behind both the one-shot backfill and the
    /// live tail. Uses the absolute path (not `/usr/bin/env log`) so a `PATH` planted in the
    /// environment can't redirect which `log` binary we run.
    nonisolated private static func launchLogProcess(arguments: [String]) throws -> (process: Foundation.Process, pipe: Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
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
}
