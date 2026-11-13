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
    /// Server-side filter for `role == builder` — the same query that populates the `builders` list
    /// — so builder detection can't drift between what's shown as a builder in the UI and what
    /// `pruneStoppedContainers()` protects from deletion.
    static func fetchBuilderSnaps() async throws -> [ContainerSnapshot] {
        try await ContainerClient().list(
            filters: ContainerListFilters(labels: [ResourceLabelKeys.role: ResourceRoleValues.builder])
        )
    }

    /// The cluster plugin labels every node container it owns — control-plane and workers alike —
    /// with `plugin=<pluginName>`, the same filter the CLI's own cluster list uses. 1.6.1 renamed
    /// `container k8s` to `container cluster` (apple/container#2427), changing the value from
    /// `k8s` to `cluster`; clusters created before the rename keep `k8s`, so both must match.
    /// Needed so `pruneStoppedContainers()` doesn't delete a stopped cluster node: unlike the
    /// CLI's cluster delete, Berthly's delete path doesn't also remove the cluster's
    /// `~/.kube/config` entry, so an unprotected prune would strand a live kubeconfig context.
    nonisolated static let clusterPluginLabelValues: Set<String> = ["k8s", "cluster"]

    nonisolated static func isClusterNode(labels: [String: String]) -> Bool {
        guard let plugin = labels[ResourceLabelKeys.plugin] else { return false }
        return clusterPluginLabelValues.contains(plugin)
    }

    func refreshAll() async {
        let previousContainers = containers
        let previousMachines = machines

        let machineSnaps = (try? await MachineClient().list()) ?? []
        let machineContainerIds = Set(machineSnaps.compactMap { $0.containerId })

        let builderSnaps = (try? await Self.fetchBuilderSnaps()) ?? []
        let builderIds = Set(builderSnaps.map { $0.id })

        do {
            let allSnaps = try await ContainerClient().list()
            // Cluster nodes (control-plane and workers) are infrastructure, same as builders —
            // hidden from the Compute list rather than shown with Start/Stop actions that would
            // leave ~/.kube/config out of sync with the cluster's actual state (see isClusterNode).
            containers = allSnaps
                .filter {
                    !machineContainerIds.contains($0.id) && !builderIds.contains($0.id)
                        && !Self.isClusterNode(labels: $0.configuration.labels)
                }
                .map { mapContainer($0) }
        } catch {
            containers = []
        }
        let kernelName = Self.kernelName(try? await ClientKernel.getDefaultKernel(for: .current))
        let defaultMachineID = ((try? await MachineClient().getDefault()) ?? nil)
        machines  = machineSnaps.map { mapMachine($0, kernelName: kernelName, defaultMachineID: defaultMachineID) }
        builders  = builderSnaps.map { mapBuilder($0) }

        // Notify on pinned containers/machines whose status changed since the last poll
        // (e.g. crashed or stopped while the user wasn't looking). Matching old/new by id
        // makes this a no-op on a transient fetch failure — see `pinnedStatusChanges`.
        for change in pinnedStatusChanges(
            oldContainers: previousContainers, newContainers: containers,
            oldMachines: previousMachines, newMachines: machines,
            pinnedContainerIDs: pinnedContainerIDs, pinnedMachineIDs: pinnedMachineIDs
        ) {
            AppNotifier.shared.postPinnedStatusChanged(change)
        }

        images = ContainerImage.resolvingUsage(
            (try? await fetchImages()) ?? [], containers: containers, machines: machines
        )
        volumes   = Volume.resolvingMounts((try? await fetchVolumes()) ?? [], containers: containers)
        networks  = (try? await fetchNetworks()) ?? []
        await loadRegistries()
    }

    // MARK: - Fetch

    private func fetchImages() async throws -> [ContainerImage] {
        let config = await resolvedSystemConfig()
        let builderImage = config.build.image
        let initImage    = config.vminit.image
        let clientImages = try await ClientImage.list()
            .filter { !Utility.isInfraImage(name: $0.reference, builderImage: builderImage, initImage: initImage) }

        // Multiple references (retags) can share a digest — keep the first image seen per
        // digest to decode from, so a digest is fetched/decoded at most once this poll.
        var imageByDigest: [String: ClientImage] = [:]
        for img in clientImages where imageByDigest[img.digest] == nil {
            imageByDigest[img.digest] = img
        }

        let (results, newCache) = await ImageMetadataCacheReconciler.reconcile(
            digests: clientImages.map(\.digest),
            cache: imageMetadataCache
        ) { digest in
            guard let img = imageByDigest[digest],
                  let resource = try? await img.toImageResource(containerSystemConfig: config) else {
                return nil
            }
            return self.makeCachedMetadata(resource)
        }

        imageMetadataCache = newCache
        imageInspectData = newCache.mapValues(\.inspectData)
        return clientImages.map { mapImage($0, metadata: results[$0.digest]) }
    }

    private func fetchVolumes() async throws -> [Volume] {
        try await ClientVolume.list().map { cfg in mapVolume(cfg) }
    }

    private func fetchNetworks() async throws -> [Network] {
        try await NetworkClient().list().map { r in Self.mapNetwork(r) }
    }

    /// Display name for a machine's kernel: the default kernel binary's filename
    /// (e.g. `vmlinux-6.18.35-197-debug`). The `Kernel` type carries no version string,
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
            imageDigest: snap.configuration.image.digest,
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
            mounts: snap.configuration.mounts.map { fs in
                let volumeName: String? = {
                    if case .volume(let name, _, _, _) = fs.type { return name }
                    return nil
                }()
                return ContainerMount(source: fs.source, destination: fs.destination,
                                      volumeName: volumeName,
                                      isReadOnly: fs.options.contains("ro"))
            },
            networks: snap.networks.map { $0.network },
            networkAliases: Self.networkAliases(from: snap.configuration.networks),
            environment: proc.environment,
            startedDate: snap.startedDate
        )
    }

    /// Aliases live on the configured attachments, not the runtime `snap.networks`. Networks
    /// without aliases are left out.
    nonisolated static func networkAliases(from attachments: [AttachmentConfiguration]) -> [String: [String]] {
        var aliases: [String: [String]] = [:]
        for attachment in attachments where !attachment.options.aliases.isEmpty {
            aliases[attachment.network, default: []] += attachment.options.aliases
        }
        return aliases
    }

    /// Decodes everything `mapImage`/inspect views need from a fetched `ImageResource` once,
    /// so the result can be cached per digest instead of re-decoded on every poll tick.
    private func makeCachedMetadata(_ resource: ImageResource) -> CachedImageMetadata {
        let supportedArch = Set(["arm64", "amd64"])
        let displayVariants = resource.variants.filter {
            supportedArch.contains($0.platform.architecture)
        }
        let sizedVariants = resource.variants.filter {
            !($0.platform.os == "unknown" && $0.platform.architecture == "unknown")
        }
        let sizeBytes = sizedVariants.reduce(0) { $0 + $1.size }
        let arch = Array(Set(sizedVariants.map { $0.platform.architecture }).intersection(supportedArch)).sorted()
        let created: String = {
            let date = resource.configuration.creationDate
            guard date.timeIntervalSince1970 > 0 else { return "–" }
            return date.formatted(Date.FormatStyle().day(.defaultDigits).month(.abbreviated).year(.defaultDigits))
        }()

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
            if s.hasPrefix("#(nop) ") { s = String(s.dropFirst("#(nop) ".count)) }
            return s.trimmingCharacters(in: .whitespaces)
        }
        let inspectData = ImageInspectData(
            variants: variants,
            command: (ep + cmd).joined(separator: " "),
            workDir: cfg?.workingDir ?? "",
            user: cfg?.user ?? "",
            stopSignal: cfg?.stopSignal ?? "",
            env: cfg?.env ?? [],
            labels: cfg?.labels ?? [:],
            history: history
        )
        return CachedImageMetadata(arch: arch, sizeBytes: sizeBytes, created: created, inspectData: inspectData)
    }

    private func mapImage(_ img: ClientImage, metadata: CachedImageMetadata?) -> ContainerImage {
        let ref = img.reference
        let atIdx = ref.firstIndex(of: "@")
        let base = atIdx.map { String(ref[ref.startIndex ..< $0]) } ?? ref
        let colonIdx = base.lastIndex(of: ":")
        let repository = colonIdx.map { String(base[base.startIndex ..< $0]) } ?? base
        let tag = colonIdx.map { idx -> String in String(base[base.index(after: idx)...]) } ?? "latest"

        let isBuilt = img.description.descriptor.annotations?[AnnotationKeys.containerizationImageName] != nil

        return ContainerImage(
            // The daemon's own reference string, not a re-derived "repository:tag" — that
            // reconstruction drops any `@sha256:...` digest-only suffix, so two distinct untagged
            // (dangling) images could both collapse to "repo:latest" and collide. `img.reference`
            // is guaranteed unique because it's literally the local store's own key for this entry.
            id: ref,
            repository: repository,
            tag: tag,
            digest: img.digest,
            arch: metadata?.arch ?? [],
            sizeBytes: metadata?.sizeBytes ?? 0,
            created: metadata?.created ?? "–",
            source: isBuilt ? .built : .pulled,
            usage: .unused  // resolved against containers/machines by ContainerImage.resolvingUsage in refreshAll
        )
    }

    private func mapVolume(_ cfg: VolumeConfiguration) -> Volume {
        // Capacity is the *configured* size (`--size`; default 512 GB) — the volume's declared
        // logical size, i.e. what the user asked for. It is deliberately NOT the backing
        // image's apparent size: the driver over-provisions tiny volumes to a 128 MB minimum
        // image, so a `--size 2M` volume lives inside a 128 MB `volume.img`. `usedMB` is that
        // image's real on-disk footprint (host bytes actually consumed), capped at capacity so
        // a tiny volume whose ext4 overhead alone exceeds its nominal size can't read past 100%.
        let configuredMB = cfg.sizeInBytes.map { Int($0 / 1_048_576) } ?? 0
        let footprintMB = Self.volumeFootprintMB(imagePath: cfg.source) ?? 0
        let created = cfg.creationDate.formatted(Date.FormatStyle().day(.defaultDigits).month(.abbreviated).year(.defaultDigits))
        return Volume(
            id: cfg.name,
            name: cfg.name,
            type: cfg.isAnonymous ? .anonymous : .named,
            usedMB: Self.volumeUsedMB(footprintMB: footprintMB, configuredMB: configuredMB),
            allocatedMB: configuredMB,
            driver: cfg.driver,
            source: cfg.source,
            created: created,
            labels: cfg.labels.map { "\($0.key)=\($0.value)" }.sorted(),
            options: cfg.options.map { "\($0.key)=\($0.value)" }.sorted(),
            mounts: [],  // filled by Volume.resolvingMounts in refreshAll
            fs: cfg.format,
            reclaimable: true
        )
    }

    /// On-disk footprint of a volume's sparse backing image (`volume.img`) in MB — the bytes
    /// actually allocated on the host, not the file's (much larger) apparent size. `nil` when
    /// the file can't be read.
    nonisolated static func volumeFootprintMB(imagePath: String) -> Int? {
        let url = URL(fileURLWithPath: imagePath)
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let footprint = values.totalFileAllocatedSize else { return nil }
        return footprint / 1_048_576
    }

    /// Displayed "used" for a volume: the backing image's on-disk footprint, capped at the
    /// configured capacity so an over-provisioned tiny volume (whose ext4 overhead can exceed
    /// its nominal size) never reads past 100%. `configuredMB == 0` means capacity is unknown,
    /// so the raw footprint is shown as-is.
    nonisolated static func volumeUsedMB(footprintMB: Int, configuredMB: Int) -> Int {
        configuredMB > 0 ? min(footprintMB, configuredMB) : footprintMB
    }

    nonisolated static func mapNetwork(_ r: NetworkResource) -> Network {
        Network(
            id: r.id,
            name: r.name,
            // The plugin is "container-network-vmnet" for both modes — the NAT/host-only
            // distinction lives in the configuration's mode, not the plugin name.
            driver: r.configuration.mode == .hostOnly ? .hostOnly : .nat,
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

    private func mapMachine(_ snap: MachineSnapshot, kernelName: String, defaultMachineID: String?) -> Machine {
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
            homeMount: Self.mapHomeMount(snap.bootConfig.homeMount),
            isDefault: snap.id == defaultMachineID
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
}
