// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import TerminalProgress

/// Mock-only: the runtime fields a lifecycle flip resets, in one place. Replaces four positional
/// 15-argument `Container(...)` reconstructions that kept drifting as `Container` gained fields —
/// three of them silently dropped `imageDigest` the day it was added.
extension Container {
    fileprivate func withRuntimeReset(status: ContainerStatus, imageDigest: String? = nil,
                                      uptime: String = "–", startedDate: Date? = nil) -> Container {
        Container(id: id, name: name, image: image, imageDigest: imageDigest ?? self.imageDigest,
                  status: status, ports: ports, cpuPercent: 0, memoryMB: 0,
                  memoryLimitMB: memoryLimitMB, networkIOString: "–", uptime: uptime,
                  command: command, mounts: mounts, networks: networks, environment: environment,
                  startedDate: startedDate)
    }
}

@MainActor
final class MockContainerService: ContainerServiceBase {

    override init() {
        super.init()
        daemonState = .connected
        installedContainerVersion = ContainerCompatibility.requiredVersion
        // Fixture literals: one entry per line scans best; wrapping these 15-argument
        // initializers would triple the section's height for no clarity gain.
        // swiftlint:disable line_length
        containers = [
            Container(id: "3f9a2b7c1d", name: "web-frontend", image: "local/web:1.4", imageDigest: "sha256:3f9a2b7c1d", status: .running, ports: [PortMapping(host: 3000, container: 3000)], cpuPercent: 12, memoryMB: 184, memoryLimitMB: 1024, networkIOString: "1.2 MB/s", uptime: "2h 41m", command: #"nginx -g "daemon off;""#, mounts: [ContainerMount(source: "./src", destination: "/app")], networks: ["app-net"], environment: ["NODE_ENV=production", "PORT=3000", "API_URL=http://api-service:8080"], startedDate: Date().addingTimeInterval(-(2*3600 + 41*60))),
            Container(id: "a17c44e9b2", name: "api-service", image: "local/api:2.1", imageDigest: "sha256:a17c44e9b2", status: .running, ports: [PortMapping(host: 8080, container: 8080)], cpuPercent: 34, memoryMB: 320, memoryLimitMB: 2048, networkIOString: "3.4 MB/s", uptime: "5h 12m", command: "node server.js", mounts: [], networks: ["app-net", "data-net"], environment: ["NODE_ENV=production"], startedDate: Date().addingTimeInterval(-(5*3600 + 12*60))),
            Container(id: "c20e81f7a4", name: "datastore", image: "local/datastore:15", imageDigest: "sha256:00olddig00", status: .running, ports: [PortMapping(host: 5432, container: 5432)], cpuPercent: 8, memoryMB: 512, memoryLimitMB: 1024, networkIOString: "0.8 MB/s", uptime: "1d 3h", command: "postgres", mounts: [], networks: ["data-net"], environment: [], startedDate: Date().addingTimeInterval(-(27*3600))),
            Container(id: "7b3d09c5e1", name: "cache", image: "local/cache:7", imageDigest: "sha256:7b3d09c5e1", status: .running, ports: [PortMapping(host: 6379, container: 6379)], cpuPercent: 2, memoryMB: 64, memoryLimitMB: 512, networkIOString: "0.2 MB/s", uptime: "1d 3h", command: "redis-server", mounts: [], networks: ["app-net"], environment: [], startedDate: Date().addingTimeInterval(-(27*3600))),
            Container(id: "d4e5f6a7b8", name: "worker", image: "local/worker:1.0", imageDigest: "sha256:d4e5f6a7b8", status: .stopped, ports: [], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 512, networkIOString: "–", uptime: "–", command: "python worker.py", mounts: [], networks: ["data-net"], environment: []),
            Container(id: "b4c8d2e6f0", name: "edge-proxy", image: "local/proxy:1.25", imageDigest: "sha256:b4c8d2e6f0", status: .error, ports: [PortMapping(host: 80, container: 80), PortMapping(host: 443, container: 443)], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 256, networkIOString: "–", uptime: "–", command: "nginx", mounts: [], networks: ["default"], environment: []),
            Container(id: "1a2b3c4d5e", name: "sandbox", image: "local/base:latest", imageDigest: "sha256:1a2b3c4d5e", status: .paused, ports: [], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 512, networkIOString: "–", uptime: "–", command: "/bin/bash", mounts: [], networks: [], environment: [])
        ]
        images = [
            ContainerImage(id: "local/web:1.4", repository: "local/web", tag: "1.4", digest: "sha256:3f9a2b7c1d", arch: ["arm64", "amd64"], sizeBytes: 182 * 1_048_576, created: "2h ago", source: .built, usage: .usedBy(3)),
            ContainerImage(id: "local/api:2.1", repository: "local/api", tag: "2.1", digest: "sha256:a17c44e9b2", arch: ["arm64"], sizeBytes: 240 * 1_048_576, created: "5h ago", source: .built, usage: .usedBy(1)),
            ContainerImage(id: "local/datastore:15", repository: "local/datastore", tag: "15", digest: "sha256:c20e81f7a4", arch: ["arm64", "amd64"], sizeBytes: 410 * 1_048_576, created: "1d ago", source: .built, usage: .usedBy(1)),
            ContainerImage(id: "local/cache:7", repository: "local/cache", tag: "7", digest: "sha256:7b3d09c5e1", arch: ["arm64"], sizeBytes: 38 * 1_048_576, created: "1d ago", source: .built, usage: .usedBy(1)),
            ContainerImage(id: "local/base:latest", repository: "local/base", tag: "latest", digest: "sha256:1a2b3c4d5e", arch: ["arm64", "amd64"], sizeBytes: 96 * 1_048_576, created: "3d ago", source: .pulled, usage: .usedBy(2)),
            ContainerImage(id: "local/proxy:1.25", repository: "local/proxy", tag: "1.25", digest: "sha256:b4c8d2e6f0", arch: ["amd64"], sizeBytes: 54 * 1_048_576, created: "2d ago", source: .built, usage: .unused),
            ContainerImage(id: "buildkit:0.13", repository: "buildkit", tag: "0.13", digest: "sha256:9f2c1a7e44", arch: ["arm64", "amd64"], sizeBytes: 160 * 1_048_576, created: "1w ago", source: .pulled, usage: .builderImage)
        ]
        let volumesRoot = "~/Library/Application Support/com.apple.container/volumes"
        volumes = [
            Volume(id: "pgdata", name: "pgdata", type: .named, usedMB: 742, allocatedMB: 2048, driver: "local", source: "\(volumesRoot)/pgdata/volume.img", created: "08:58", labels: ["app=datastore"], options: ["size=2G"], mounts: [VolumeMount(containerName: "datastore", mountPath: "/var/lib/postgresql/data", mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "shared", name: "shared-assets", type: .named, usedMB: 318, allocatedMB: 512, driver: "local", source: "\(volumesRoot)/shared-assets/volume.img", created: "08:30", labels: [], options: ["size=512M"], mounts: [VolumeMount(containerName: "web-frontend", mountPath: "/app/public", mode: "RO"), VolumeMount(containerName: "api-service", mountPath: "/srv/assets", mode: "RO")], fs: "ext4", reclaimable: false),
            Volume(id: "redis", name: "redis-data", type: .named, usedMB: 48, allocatedMB: 256, driver: "local", source: "\(volumesRoot)/redis-data/volume.img", created: "09:00", labels: [], options: ["size=256M"], mounts: [VolumeMount(containerName: "cache", mountPath: "/data", mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "worker-q", name: "worker-queue", type: .named, usedMB: 12, allocatedMB: 128, driver: "local", source: "\(volumesRoot)/worker-queue/volume.img", created: "09:02", labels: ["app=worker"], options: ["size=128M"], mounts: [VolumeMount(containerName: "worker", mountPath: "/var/spool/queue", mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "model", name: "model-cache", type: .named, usedMB: 3481, allocatedMB: 4096, driver: "local", source: "\(volumesRoot)/model-cache/volume.img", created: "Jun 12", labels: [], options: ["size=4G"], mounts: [], fs: "ext4", reclaimable: true),
            Volume(id: "anon1", name: "8349ab8d-e6db-4e58-98ab-6e34f08f1dae", type: .anonymous, usedMB: 214, allocatedMB: 1024, driver: "local", source: "\(volumesRoot)/8349ab8d-e6db-4e58-98ab-6e34f08f1dae/volume.img", created: "09:14", labels: ["com.apple.container.resource.anonymous=true"], options: [], mounts: [VolumeMount(containerName: "datastore", mountPath: "/var/lib/postgresql/pgdata", mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "anon2", name: "1c4f0a7e-93b1-4d02-8f6a-25c1de0a7b44", type: .anonymous, usedMB: 96, allocatedMB: 512, driver: "local", source: "\(volumesRoot)/1c4f0a7e-93b1-4d02-8f6a-25c1de0a7b44/volume.img", created: "08:58", labels: ["com.apple.container.resource.anonymous=true"], options: [], mounts: [], fs: "ext4", reclaimable: true),
            // Created without --size: the daemon's 512 GiB sparse default. Exercises the
            // on-disk-footprint presentation (no meaningful capacity gauge).
            Volume(id: "logs", name: "logs", type: .named, usedMB: 66, allocatedMB: Volume.defaultSparseCapacityMB, driver: "local", source: "\(volumesRoot)/logs/volume.img", created: "09:20", labels: [], options: [], mounts: [VolumeMount(containerName: "api-service", mountPath: "/var/log/app", mode: "RW")], fs: "ext4", reclaimable: false)
        ]
        networks = [
            Network(id: "app-net", name: "app-net", driver: .nat, subnet: "192.168.65.0/24", gateway: "192.168.65.1", isDefault: false, scope: "local", ipv6Enabled: false, egress: "NAT → en0", attachable: true, backend: "vmnet", endpoints: [NetworkEndpoint(id: "e1", name: "web-frontend", ipv4: "192.168.65.10", kind: "CONTAINER", isRunning: true, aliases: ["web", "frontend"]), NetworkEndpoint(id: "e2", name: "api-service", ipv4: "192.168.65.11", kind: "CONTAINER", isRunning: true, aliases: ["api"]), NetworkEndpoint(id: "e6", name: "cache", ipv4: "192.168.65.12", kind: "CONTAINER", isRunning: true, aliases: ["redis", "cache"])]),
            Network(id: "data-net", name: "data-net", driver: .hostOnly, subnet: "192.168.66.0/24", gateway: "192.168.66.1", isDefault: false, scope: "local", ipv6Enabled: false, egress: "", attachable: false, backend: "vmnet", endpoints: [NetworkEndpoint(id: "e7", name: "api-service", ipv4: "192.168.66.20", kind: "CONTAINER", isRunning: true, aliases: ["api"]), NetworkEndpoint(id: "e8", name: "datastore", ipv4: "192.168.66.21", kind: "CONTAINER", isRunning: true, aliases: ["db", "postgres"]), NetworkEndpoint(id: "e9", name: "worker", ipv4: "192.168.66.22", kind: "CONTAINER", isRunning: false, aliases: ["worker"])]),
            Network(id: "default", name: "default", driver: .nat, subnet: "192.168.64.0/24", gateway: "192.168.64.1", isDefault: true, scope: "local", ipv6Enabled: false, egress: "NAT → en0", attachable: true, backend: "vmnet", endpoints: [NetworkEndpoint(id: "e3", name: "dev", ipv4: "192.168.64.3", kind: "MACHINE", isRunning: true, aliases: ["machine"]), NetworkEndpoint(id: "e4", name: "ci-runner", ipv4: "192.168.64.4", kind: "MACHINE", isRunning: false, aliases: ["machine"]), NetworkEndpoint(id: "e5", name: "default", ipv4: "192.168.64.2", kind: "MACHINE", isRunning: true, aliases: ["machine", "utility VM"]), NetworkEndpoint(id: "e10", name: "edge-proxy", ipv4: "192.168.64.10", kind: "CONTAINER", isRunning: false, aliases: ["edge", "proxy"])])
        ]
        machines = [
            Machine(id: "dev", name: "dev", image: "ubuntu:24.04", status: .running, isUtility: false, diskUsedGB: 3.1, diskTotalGB: 8.0, uptimeString: "1h 12m", kernel: "6.12.4-arm64", resources: "4 vCPU · 4 GB", created: "Jun 20", homeMount: .readWrite, isDefault: true),
            Machine(id: "ci-runner", name: "ci-runner", image: "alpine:3.22", status: .stopped, isUtility: false, diskUsedGB: 0.48, diskTotalGB: 2.0, uptimeString: "–", kernel: "6.12.4-arm64", resources: "2 vCPU · 2 GB", created: "Jun 22", homeMount: .readOnly),
            Machine(id: "default", name: "default", image: "debian:12", status: .running, isUtility: true, diskUsedGB: 1.2, diskTotalGB: 4.0, uptimeString: "6d 4h", kernel: "6.12.4-arm64", resources: "2 vCPU · 4 GB", created: "Jun 15", homeMount: .none)
        ]
        builders = [
            Builder(id: "default", name: "default", image: "buildkit:0.13", status: .running, autoStarted: true, cpus: 2, memoryGB: 2)
        ]
        registries = [
            Registry(host: "ghcr.io", username: "apple-bot"),
            Registry(host: "registry-1.docker.io", username: "berthly")
        ]
        // Two staleness fixtures without adding rows (UI perf tests count rows): `sandbox`'s
        // image has a seeded remote update (badge on both the image row and the container row),
        // and `datastore`'s imageDigest above lags its image (recreate-without-pull path).
        imageUpdateInfo = ["local/base:latest": ImageUpdateInfo(remoteDigest: "sha256:feed5eed01", localImageDigest: "sha256:1a2b3c4d5e", isUpdateAvailable: true, checkedAt: Date())]
        lastImageUpdateCheck = Date()
        imageInspectData = Self.mockInspectData()
        buildContexts = [
            "local/web:1.4": BuildContext(contextPath: "/Users/dev/projects/web", dockerfilePath: nil),
            "local/api:2.1": BuildContext(contextPath: "/Users/dev/projects/api", dockerfilePath: "Containerfile")
        ]
    }

    private static func mockInspectData() -> [String: ImageInspectData] {
        let webVariants = [
            ImageVariantInfo(arch: "arm64", archVariant: "v8", sizeBytes: 182 * 1_048_576, digest: "sha256:arm64variant001"),
            ImageVariantInfo(arch: "amd64", archVariant: nil, sizeBytes: 188 * 1_048_576, digest: "sha256:amd64variant001")
        ]
        let webEnv = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "NODE_ENV=production", "PORT=3000", "NGINX_VERSION=1.25.4"]
        let webLabels: [String: String] = ["maintainer": "berthly@example.com", "version": "1.4", "org.opencontainers.image.title": "web-frontend"]
        let webHistory = [
            "ADD file:abc123 in /",
            "apt-get update && apt-get install -y nodejs npm",
            "WORKDIR /app",
            "npm ci --omit=dev",
            "COPY . .",
            "EXPOSE 3000",
            "CMD [\"nginx\",\"-g\",\"daemon off;\"]"
        ]

        let apiVariants = [ImageVariantInfo(arch: "arm64", archVariant: "v8", sizeBytes: 240 * 1_048_576, digest: "sha256:apiarm64variant001")]
        let apiEnv = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "NODE_ENV=production", "NODE_VERSION=22.2.0"]
        let apiHistory = ["ADD file:def456 in /", "WORKDIR /srv", "npm install", "CMD [\"node\",\"server.js\"]"]

        return [
            "sha256:3f9a2b7c1d": ImageInspectData(variants: webVariants, command: "nginx -g daemon off;", workDir: "/app", user: "www-data", stopSignal: "SIGTERM", env: webEnv, labels: webLabels, history: webHistory),
            "sha256:a17c44e9b2": ImageInspectData(variants: apiVariants, command: "node server.js", workDir: "/srv", user: "", stopSignal: "", env: apiEnv, labels: [:], history: apiHistory)
        ]
    }
    // swiftlint:enable line_length

    // MARK: - Operations (simulated in mock)

    override func startContainer(_ id: String) async throws {
        // Simulated daemon latency (like runContainer/createMachine below): rows show a spinner
        // while these are in flight, which an instant flip would make invisible in mock mode.
        try? await Task.sleep(for: .milliseconds(600))
        guard let i = containers.firstIndex(where: { $0.id == id }) else { return }
        containers[i] = containers[i].withRuntimeReset(status: .running, uptime: "0m")
    }

    override func stopContainer(_ id: String) async throws {
        try? await Task.sleep(for: .milliseconds(600))
        guard let i = containers.firstIndex(where: { $0.id == id }) else { return }
        containers[i] = containers[i].withRuntimeReset(status: .stopped)
    }

    override func restartContainer(_ id: String) async throws {
        try await stopContainer(id)
        try await startContainer(id)
    }

    override func killContainer(_ id: String) async throws {
        // No simulated latency, unlike stopContainer: SIGKILL is immediate — that's its point.
        guard let i = containers.firstIndex(where: { $0.id == id }) else { return }
        containers[i] = containers[i].withRuntimeReset(status: .stopped)
    }

    override func deleteContainer(_ id: String) async throws {
        containers.removeAll { $0.id == id }
        pinnedContainerIDs.remove(id)
    }

    override func checkForImageUpdates(force: Bool = false) async {
        guard !isCheckingImageUpdates else { return }
        isCheckingImageUpdates = true
        // Long enough for the toolbar spinner to be visible (and waitable in UI tests).
        try? await Task.sleep(for: .milliseconds(300))
        isCheckingImageUpdates = false
        lastImageUpdateCheck = Date()
        // Re-assert the seeded verdict: in mock mode the registry always says what init said.
        if let base = images.first(where: { $0.id == "local/base:latest" }) {
            imageUpdateInfo["local/base:latest"] = ImageUpdateInfo(
                remoteDigest: "sha256:feed5eed01", localImageDigest: base.digest,
                isUpdateAvailable: base.digest != "sha256:feed5eed01", checkedAt: Date()
            )
        }
    }

    override func recreateContainer(_ id: String, pullFirst: Bool, progress: ProgressUpdateHandler? = nil,
                                    onPhase: @MainActor @escaping (RecreatePhase) -> Void) async throws -> RecreateResult {
        guard let index = containers.firstIndex(where: { $0.id == id }) else {
            throw ContainerCLIError(exitCode: 1, message: "container \(id) not found")
        }
        let container = containers[index]
        let wasRunning = container.status == .running
        let oldDigest = container.imageDigest ?? ""

        // Pull only when the registry actually has something newer — mirroring the live gate,
        // and modeling what a same-tag re-pull really does: *replace* the reference's digest
        // (unlike mock pullImage, which appends a row for a brand-new reference).
        var didPull = false
        if pullFirst, staleness(of: container) == .remoteUpdateAvailable,
           let imageIndex = images.firstIndex(where: { $0.id == container.image || $0.fullName == container.image }) {
            onPhase(.pullingImage)
            let old = images[imageIndex]
            await progress?([.addTotalItems(4), .addTotalSize(old.sizeBytes)])
            for _ in 0..<4 {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                await progress?([.addItems(1), .addSize(old.sizeBytes / 4)])
            }
            let remoteDigest = imageUpdateInfo[old.id]?.remoteDigest ?? "sha256:\(UUID().uuidString.prefix(12).lowercased())"
            images[imageIndex] = ContainerImage(id: old.id, repository: old.repository, tag: old.tag,
                                                digest: remoteDigest, arch: old.arch, sizeBytes: old.sizeBytes,
                                                created: "just now", source: old.source, usage: old.usage)
            imageUpdateInfo[old.id] = ImageUpdateInfo(remoteDigest: remoteDigest, localImageDigest: remoteDigest,
                                                      isUpdateAvailable: false, checkedAt: Date())
            didPull = true
        }
        try Task.checkCancellation()

        // No cancellation checks past this point — same replace-window semantics as the live
        // service, so the sheet's cancel-gating is exercised honestly in mock mode.
        let steps: [RecreatePhase] = wasRunning
            ? [.stoppingContainer, .deletingContainer, .creatingContainer, .startingContainer]
            : [.deletingContainer, .creatingContainer]
        for step in steps {
            onPhase(step)
            try? await Task.sleep(for: .milliseconds(150))
        }
        let newDigest = images.first { $0.id == container.image || $0.fullName == container.image }?.digest ?? oldDigest
        // A non-running container lands stopped regardless of what it was (paused/error state
        // doesn't survive being replaced by a fresh container).
        containers[index] = container.withRuntimeReset(status: wasRunning ? .running : .stopped,
                                                       imageDigest: newDigest,
                                                       uptime: wasRunning ? "0m" : "–",
                                                       startedDate: wasRunning ? Date() : nil)
        return RecreateResult(wasRunning: wasRunning, didPull: didPull,
                              oldImageDigest: oldDigest, newImageDigest: newDigest)
    }

    override func reclaimOrphanedImageBlobs() async throws -> UInt64 {
        try? await Task.sleep(for: .milliseconds(200))
        return 96 * 1_048_576
    }

    // Records the arguments of the last copy so tests and previews can assert what the UI asked
    // for without a daemon. There's no host/guest filesystem to actually move bytes between here.
    // swiftlint:disable:next large_tuple
    private(set) var lastCopy: (direction: CopyDirection, containerID: String, hostPath: String, containerPath: String)?

    override func copyFiles(direction: CopyDirection, containerID: String, hostPath: String, containerPath: String) async throws {
        lastCopy = (direction, containerID, hostPath, containerPath)
    }

    /// Mirrors the daemon's stopped-only rule and writes a placeholder file, so the export flow
    /// is exercised end to end in mock mode (panel → service → file at the chosen path).
    override func exportContainer(_ id: String, to path: String) async throws {
        guard let container = containers.first(where: { $0.id == id }) else {
            throw ContainerCLIError(exitCode: 1, message: "container \(id) not found")
        }
        guard container.status == .stopped else {
            throw ContainerCLIError(exitCode: 1, message: "container is not stopped")
        }
        try Data("mock rootfs export of \(id)\n".utf8).write(to: URL(fileURLWithPath: path))
    }

    override func startMachine(_ id: String) async throws {
        try? await Task.sleep(for: .milliseconds(600))
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        let m = machines[i]
        machines[i] = Machine(id: m.id, name: m.name, image: m.image, status: .running,
                              isUtility: m.isUtility, diskUsedGB: m.diskUsedGB,
                              diskTotalGB: m.diskTotalGB, uptimeString: "0m",
                              kernel: m.kernel, resources: m.resources, created: m.created,
                              homeMount: m.homeMount, isDefault: m.isDefault)
    }

    override func stopMachine(_ id: String) async throws {
        try? await Task.sleep(for: .milliseconds(600))
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        let m = machines[i]
        machines[i] = Machine(id: m.id, name: m.name, image: m.image, status: .stopped,
                              isUtility: m.isUtility, diskUsedGB: m.diskUsedGB,
                              diskTotalGB: m.diskTotalGB, uptimeString: "–",
                              kernel: m.kernel, resources: m.resources, created: m.created,
                              homeMount: m.homeMount, isDefault: m.isDefault)
    }

    override func setDefaultMachine(_ id: String) async throws {
        // Exactly one holder: granting the badge revokes it everywhere else, same as the daemon.
        for i in machines.indices {
            machines[i].isDefault = machines[i].id == id
        }
    }

    override func updateMachine(_ id: String, options: MachineUpdateOptions) async throws {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        let m = machines[i]
        // The mock's `resources` is a display string ("4 vCPU · 4 GB") — patch only the parts
        // the options set, mirroring the live merge-over-current semantics.
        let parts = m.resources.components(separatedBy: " · ")
        let cpuPart = options.cpus.map { "\($0) CPU" } ?? (parts.first ?? "")
        let memoryTrimmed = options.memory?.trimmingCharacters(in: .whitespaces)
        let memPart = (memoryTrimmed?.isEmpty == false ? memoryTrimmed! : (parts.count > 1 ? parts[1] : ""))
        let homeMount: MachineHomeMount = switch options.homeMount {
        case "ro":   .readOnly
        case "rw":   .readWrite
        case "none": MachineHomeMount.none
        default:     m.homeMount
        }
        machines[i] = Machine(id: m.id, name: m.name, image: m.image, status: m.status,
                              isUtility: m.isUtility, diskUsedGB: m.diskUsedGB,
                              diskTotalGB: m.diskTotalGB, uptimeString: m.uptimeString,
                              kernel: m.kernel,
                              resources: [cpuPart, memPart].filter { !$0.isEmpty }.joined(separator: " · "),
                              created: m.created, homeMount: homeMount, isDefault: m.isDefault)
    }

    override func deleteMachine(_ id: String) async throws {
        machines.removeAll { $0.id == id }
        pinnedMachineIDs.remove(id)
    }

    override func startBuilder(_ id: String) async throws {
        guard let i = builders.firstIndex(where: { $0.id == id }) else { return }
        let b = builders[i]
        builders[i] = Builder(id: b.id, name: b.name, image: b.image, status: .running,
                              autoStarted: b.autoStarted, cpus: b.cpus, memoryGB: b.memoryGB)
    }

    override func stopBuilder(_ id: String) async throws {
        guard let i = builders.firstIndex(where: { $0.id == id }) else { return }
        let b = builders[i]
        builders[i] = Builder(id: b.id, name: b.name, image: b.image, status: .stopped,
                              autoStarted: b.autoStarted, cpus: b.cpus, memoryGB: b.memoryGB)
    }

    override func deleteBuilder(_ id: String) async throws {
        builders.removeAll { $0.id == id }
    }

    override func deleteImage(_ reference: String) async throws {
        images.removeAll { $0.fullName == reference }
    }

    override func deleteVolume(_ name: String) async throws {
        volumes.removeAll { $0.name == name }
    }

    override func deleteNetwork(_ id: String) async throws {
        networks.removeAll { $0.id == id }
    }

    override func createVolume(options: VolumeCreateOptions) async throws {
        let name = options.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Volume name is required.")
        }
        volumes.append(Volume(
            id: name, name: name, type: .named, usedMB: 0, allocatedMB: 0,
            driver: "local", source: "", created: "now", labels: [],
            options: options.size.map { ["size=\($0)"] } ?? [],
            mounts: [], fs: "ext4", reclaimable: true
        ))
    }

    override func createNetwork(options: NetworkCreateOptions) async throws {
        let name = options.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Network name is required.")
        }
        let subnet = options.subnet?.trimmingCharacters(in: .whitespaces)
        networks.append(Network(
            id: name, name: name, driver: options.hostOnly ? .hostOnly : .nat,
            subnet: subnet?.isEmpty == false ? subnet! : "192.168.70.0/24",
            gateway: "", isDefault: false, scope: "local", ipv6Enabled: false,
            egress: options.hostOnly ? "" : "NAT → en0", attachable: true, backend: "vmnet", endpoints: []
        ))
    }

    // Already seeded in init — nothing to reload.
    override func loadRegistries() async {}

    override func signInRegistry(host: String, username: String, password: String, insecure: Bool = false) async throws {
        let host = host.trimmingCharacters(in: .whitespaces)
        let username = username.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Host, username, and token are required.")
        }
        if let index = registries.firstIndex(where: { $0.host == host }) {
            registries[index] = Registry(host: host, username: username)
        } else {
            registries.append(Registry(host: host, username: username))
        }
    }

    // Sign out deletes the credential, so the row disappears — matching `container registry logout`.
    override func signOutRegistry(host: String) async throws {
        registries.removeAll { $0.host == host }
    }

    override func fetchDiskUsage() async throws {
        // Volumes derive from the seeded volume list (unlike the static image/container numbers)
        // so the row's Prune button appears exactly while unmounted volumes exist, and pruning
        // visibly zeroes the reclaimable figure.
        let mounted = volumes.filter { !$0.mounts.isEmpty }
        let volumeBytes = volumes.reduce(UInt64(0)) { $0 + UInt64($1.usedMB) * 1_048_576 }
        let reclaimableVolumeBytes = volumes.filter(\.mounts.isEmpty)
            .reduce(UInt64(0)) { $0 + UInt64($1.usedMB) * 1_048_576 }
        diskUsage = DiskUsageSummary(
            images: .init(total: 12, active: 4, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
            containers: .init(total: 6, active: 2, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
            volumes: .init(total: volumes.count, active: mounted.count,
                           sizeBytes: volumeBytes, reclaimableBytes: reclaimableVolumeBytes)
        )
    }

    override func pruneImages() async throws -> PruneResult {
        // Reflect the cleanup: images drop to fully-active with no reclaimable left.
        let freed = diskUsage?.images.reclaimableBytes ?? 0
        if let usage = diskUsage {
            diskUsage = DiskUsageSummary(
                images: .init(total: usage.images.active, active: usage.images.active,
                              sizeBytes: usage.images.sizeBytes - freed, reclaimableBytes: 0),
                containers: usage.containers,
                volumes: usage.volumes
            )
        }
        return PruneResult(imagesFreedBytes: freed, deletedImageCount: 8)
    }

    override func pruneStoppedContainers() async throws -> PruneResult {
        let freed = diskUsage?.containers.reclaimableBytes ?? 0
        if let usage = diskUsage {
            diskUsage = DiskUsageSummary(
                images: usage.images,
                containers: .init(total: usage.containers.active, active: usage.containers.active,
                                  sizeBytes: usage.containers.sizeBytes - freed, reclaimableBytes: 0),
                volumes: usage.volumes
            )
        }
        return PruneResult(containersFreedBytes: freed, deletedContainerCount: 4)
    }

    override func pruneVolumes() async throws -> PruneResult {
        let unused = volumes.filter(\.mounts.isEmpty)
        let freed = unused.reduce(UInt64(0)) { $0 + UInt64($1.usedMB) * 1_048_576 }
        volumes.removeAll(where: \.mounts.isEmpty)
        try? await fetchDiskUsage()  // re-derives the volumes row from the now-shorter list
        return PruneResult(volumesFreedBytes: freed, deletedVolumeCount: unused.count)
    }

    override func pruneNetworks() async throws -> PruneResult {
        // Same in-use rule as the live selection: a network any container's configuration
        // references (running or stopped) survives, as does the built-in default.
        let connected = Set(containers.flatMap(\.networks))
        let unused = networks.filter { !$0.isDefault && !connected.contains($0.id) }
        let unusedIDs = Set(unused.map(\.id))
        networks.removeAll { unusedIDs.contains($0.id) }
        return PruneResult(deletedNetworkCount: unused.count)
    }

    override func fetchKernelInfo() async throws {
        kernelInfo = KernelInfo(path: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186", platform: "linux/arm64")
    }

    override func setKernel(options: KernelSetOptions, progress: ProgressUpdateHandler? = nil) async throws {
        kernelInfo = KernelInfo(path: options.binaryPath, platform: "linux/\(options.architecture)")
    }

    override func fetchSystemProperties() async {
        systemProperties = [
            SystemProperty(key: "build.rosetta", value: "true"),
            SystemProperty(key: "build.cpus", value: "2"),
            SystemProperty(key: "build.memory", value: "2 GB"),
            SystemProperty(key: "build.image", value: "ghcr.io/apple/container-builder-shim/builder:latest"),
            SystemProperty(key: "container.cpus", value: "4"),
            SystemProperty(key: "container.memory", value: "1 GB"),
            SystemProperty(key: "dns.domain", value: "test"),
            SystemProperty(key: "kernel.binaryPath", value: "opt/kata/share/kata-containers/vmlinux-6.18.15-186"),
            SystemProperty(key: "kernel.url", value: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst"),
            SystemProperty(key: "machine.cpus", value: "4"),
            SystemProperty(key: "machine.memory", value: "8 GB"),
            SystemProperty(key: "machine.home-mount", value: "rw"),
            SystemProperty(key: "machine.virtualization", value: "false"),
            SystemProperty(key: "network.subnet", value: "192.168.64.0/24"),
            SystemProperty(key: "network.subnetv6", value: "–"),
            SystemProperty(key: "registry.domain", value: "docker.io"),
            SystemProperty(key: "vminit.image", value: "ghcr.io/apple/containerization/vminit:latest")
        ]
    }

    override func fetchDNSDomains() async {
        // Seed only on first fetch, so create/delete mutations survive later refetches.
        if dnsDomains == nil { dnsDomains = ["test"] }
    }

    override func createDNSDomain(_ name: String) async throws {
        let domain = name.trimmingCharacters(in: .whitespaces)
        if let problem = LiveContainerService.validateDNSDomainName(domain) {
            throw ContainerCLIError(exitCode: 1, message: problem)
        }
        var domains = dnsDomains ?? []
        guard !domains.contains(domain) else {
            throw ContainerCLIError(exitCode: 1, message: "domain \(domain) already exists")
        }
        domains.append(domain)
        dnsDomains = domains.sorted()
    }

    override func deleteDNSDomain(_ name: String) async throws {
        dnsDomains?.removeAll { $0 == name }
    }

    override func fetchSystemConfig() async throws {
        systemConfigInfo = SystemConfigInfo(
            vminitImage: "ghcr.io/apple/containerization/vminit:latest",
            kernelBinaryPath: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186",
            kernelURL: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst",
            builderImage: "ghcr.io/apple/container-builder-shim/builder:latest"
        )
    }

    override func streamDaemonLogs(onLine: @MainActor @escaping (String) -> Void) async throws {
        // Tab-joined "timestamp\tlevel\tmessage", matching what LiveContainerService.
        // formatDaemonLogEvent produces from real `log stream --style ndjson` output.
        for line in [
            "08:00:00.000\tInfo\tapiserver started",
            "08:00:01.000\tInfo\tlistening on com.apple.container.apiserver",
            "08:00:02.481\tError\txpc client handler connection error [error=Connection invalid]"
        ] {
            onLine(line)
        }
    }

    override func buildImage(
        options: BuildOptions,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        let lines = [
            "#1 [internal] load build definition from \(options.dockerfilePath ?? "Dockerfile")",
            "#1 DONE 0.0s",
            "#2 [internal] load .dockerignore",
            "#2 DONE 0.0s",
            "#3 [1/4] FROM ghcr.io/apple/container-base:latest",
            "#3 DONE 1.2s",
            "#4 [2/4] RUN apt-get update",
            "#4 DONE 3.4s",
            "#5 [3/4] COPY . .",
            "#5 DONE 0.1s",
            "#6 [4/4] RUN npm ci --omit=dev",
            "#6 DONE 8.7s",
            "#7 exporting to image",
            "#7 exporting layers done",
            "#7 writing image sha256:abc123 done",
            "#7 naming to \(options.reference) done"
        ]
        for line in lines {
            try? await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            onLog(line)
        }
        let parts = options.reference.split(separator: ":", maxSplits: 1)
        let repo = String(parts.first ?? Substring(options.reference))
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        // A name always points at exactly one piece of content — rebuilding an existing tag
        // replaces its entry rather than appending a second row with the same id (that append is
        // the same id-collision shape this file's other push/pull mutations now guard against).
        images.removeAll { $0.fullName == options.reference }
        images.append(ContainerImage(id: "\(repo):\(tag)", repository: repo, tag: tag,
                                     digest: "sha256:\(UUID().uuidString.prefix(12).lowercased())",
                                     arch: ["arm64"], sizeBytes: 182 * 1_048_576,
                                     created: "just now", source: .built, usage: .unused))
    }

    @discardableResult
    override func runContainer(options: RunOptions) async throws -> String {
        try? await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()

        let id = (options.name?.isEmpty == false ? options.name! : nil) ?? UUID().uuidString
        let ports = options.ports.compactMap { spec -> PortMapping? in
            let hostAndContainer = spec.split(separator: "/").first.map(String.init) ?? spec
            let parts = hostAndContainer.split(separator: ":")
            guard parts.count >= 2,
                  let host = Int(parts[parts.count - 2]),
                  let containerPort = Int(parts[parts.count - 1]) else { return nil }
            return PortMapping(host: host, container: containerPort)
        }
        let command = ([options.entrypoint].compactMap { $0 } + options.command).joined(separator: " ")
        // An attached run has already finished (foreground, waits for exit) by the time we
        // return — unlike a detached run, which is still going.
        let hasExited = options.start && options.attach
        let isRunning = options.start && !options.attach

        containers.append(Container(
            id: id,
            name: id,
            image: options.reference,
            imageDigest: images.first { $0.id == options.reference || $0.fullName == options.reference }?.digest,
            status: isRunning ? .running : .stopped,
            ports: ports,
            cpuPercent: 0,
            memoryMB: 0,
            memoryLimitMB: 512,
            networkIOString: "–",
            uptime: isRunning ? "0m" : "–",
            command: command.isEmpty ? "–" : command,
            mounts: [],
            networks: options.networks,
            environment: options.env.map { "\($0.key)=\($0.value)" }.sorted(),
            startedDate: isRunning ? Date() : nil
        ))

        guard hasExited else { return "" }
        return options.command.isEmpty ? "" : "(mock output for: \(options.command.joined(separator: " ")))"
    }

    override func createMachine(options: MachineCreateOptions) async throws {
        try? await Task.sleep(for: .milliseconds(500))
        try Task.checkCancellation()

        let id = (options.name?.isEmpty == false ? options.name! : nil) ?? UUID().uuidString
        let cpus = options.cpus ?? 2
        let memory = options.memory ?? "4G"

        let homeMount: MachineHomeMount
        switch options.homeMount {
        case "ro":   homeMount = .readOnly
        case "none": homeMount = .none
        default:     homeMount = .readWrite
        }

        machines.append(Machine(
            id: id,
            name: id,
            image: options.reference,
            status: options.boot ? .running : .stopped,
            isUtility: false,
            diskUsedGB: 0,
            diskTotalGB: 8,
            uptimeString: options.boot ? "0m" : "–",
            kernel: "–",
            resources: "\(cpus) CPU · \(memory)",
            created: "just now",
            homeMount: homeMount
        ))
        if options.setDefault {
            try await setDefaultMachine(id)
        }
    }

    override func startDaemon(onLog: (@MainActor (String) -> Void)? = nil) async {
        daemonState = .connecting
        try? await Task.sleep(for: .milliseconds(200))
        daemonState = .connected
    }

    override func stopDaemon() async {
        daemonState = .stopping
        try? await Task.sleep(for: .milliseconds(200))
        daemonState = .installedButStopped
    }

    override func upgradeContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        await stopDaemon()
        onLog("Updating to version \(ContainerCompatibility.requiredVersion)...")
        do {
            // Long enough to hold the progress screen up for a couple of XCUITest polls (it only
            // samples element existence ~once/sec), or an assertion that it survives the
            // daemon-state transition races it. No `try?`: cancellation propagates so Cancel
            // behaves like the live service's — abort, and restore the daemon.
            try await Task.sleep(for: .seconds(2))
        } catch {
            await startDaemon()
            throw error
        }
        onLog("Updated successfully")
        installedContainerVersion = ContainerCompatibility.requiredVersion
        await startDaemon()
    }

    override func installContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        // Cancellation propagates from the sleeps (no `try?`) so Cancel aborts the mock install
        // like it aborts the live one; nothing is installed yet, so there's nothing to restore.
        onLog("Downloading container-\(ContainerCompatibility.requiredVersion)-installer-signed.pkg…")
        try await Task.sleep(for: .milliseconds(400))
        onLog("Verifying package signature…")
        try await Task.sleep(for: .milliseconds(400))
        onLog("Installing…")
        try await Task.sleep(for: .milliseconds(400))
        // The live service reports the first-run kernel/vminit bootstrap downloads through the
        // same log — mirror one so the mock's install log reads like the real flow's.
        onLog("Downloading default kernel…")
        try await Task.sleep(for: .milliseconds(400))
        onLog("Default kernel installed")
        installedContainerVersion = ContainerCompatibility.requiredVersion
        await startDaemon()
    }

    override func pullImage(reference: String, platform: String? = nil, insecure: Bool = false,
                            progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {
        let layerCount = 8
        let totalBytes: Int64 = 145_000_000
        let bytesPerLayer = totalBytes / Int64(layerCount)
        await progress?([.addTotalItems(layerCount), .addTotalSize(totalBytes)])
        for _ in 0..<layerCount {
            try? await Task.sleep(for: .milliseconds(250))
            await progress?([.addItems(1), .addSize(bytesPerLayer)])
        }
        onUnpacking?()
        try? await Task.sleep(for: .milliseconds(600))
        let parts = reference.split(separator: ":", maxSplits: 1)
        let repo = String(parts.first ?? Substring(reference))
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        images.append(ContainerImage(id: "\(repo):\(tag)", repository: repo, tag: tag,
                                     digest: "sha256:\(UUID().uuidString.prefix(12).lowercased())",
                                     arch: ["arm64"], sizeBytes: totalBytes,
                                     created: "just now", source: .pulled, usage: .unused))
    }

    override func tagImage(reference: String, newReference: String) async throws -> String {
        guard let source = images.first(where: { $0.fullName == reference }) else {
            throw ContainerCLIError(exitCode: 1, message: "No such image: \(reference)")
        }
        let trimmed = newReference.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ContainerCLIError(exitCode: 1, message: "Target reference is required.")
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        let repo = String(parts.first ?? Substring(trimmed))
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        let full = "\(repo):\(tag)"
        // Same shape as pushImage's retag above: the new name shares the source's digest (a tag
        // doesn't copy content), and tagging onto an existing name replaces that entry rather
        // than appending a second row with the same id.
        images.removeAll { $0.fullName == full }
        images.append(ContainerImage(id: full, repository: repo, tag: tag,
                                     digest: source.digest, arch: source.arch,
                                     sizeBytes: source.sizeBytes, created: "just now",
                                     source: source.source, usage: .unused))
        return full
    }

    /// Records the last save so tests and previews can assert what the UI asked for — no tar is
    /// actually written (previews shouldn't touch the filesystem).
    private(set) var lastImageSave: (references: [String], path: String)?

    override func saveImages(references: [String], to path: String, platform: String? = nil) async throws {
        for reference in references where !images.contains(where: { $0.fullName == reference }) {
            throw ContainerCLIError(exitCode: 1, message: "No such image: \(reference)")
        }
        try? await Task.sleep(for: .milliseconds(400))
        lastImageSave = (references, path)
    }

    override func loadImages(from path: String, force: Bool = false, progress: ProgressUpdateHandler? = nil) async throws -> ImageLoadSummary {
        // Only the unpack phase reports progress (matching the live service).
        let entryCount = 5
        await progress?([.addTotalItems(entryCount)])
        for _ in 0..<entryCount {
            try? await Task.sleep(for: .milliseconds(150))
            await progress?([.addItems(1)])
        }
        // Round-trip the save flow's naming: `alpine_latest.tar` loads back as `alpine:latest`.
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "_", maxSplits: 1)
        let repo = parts.first.map(String.init) ?? "loaded"
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        let full = "\(repo):\(tag)"
        images.removeAll { $0.fullName == full }
        images.append(ContainerImage(id: full, repository: repo, tag: tag,
                                     digest: "sha256:\(UUID().uuidString.prefix(12).lowercased())",
                                     arch: ["arm64"], sizeBytes: 145_000_000,
                                     created: "just now", source: .pulled, usage: .unused))
        return ImageLoadSummary(loadedReferences: [full], rejectedMembers: [])
    }

    override func pushImage(reference: String, destination: String? = nil, platform: String? = nil,
                            insecure: Bool = false, progress: ProgressUpdateHandler? = nil) async throws {
        let source = images.first { $0.fullName == reference }
        let layerCount = 6
        let totalBytes = source?.sizeBytes ?? 120_000_000
        let bytesPerLayer = totalBytes / Int64(layerCount)
        await progress?([.addTotalItems(layerCount), .addTotalSize(totalBytes)])
        for _ in 0..<layerCount {
            try? await Task.sleep(for: .milliseconds(200))
            await progress?([.addItems(1), .addSize(bytesPerLayer)])
        }
        // Reflect a retag: the destination becomes a local reference sharing the SAME digest as the
        // source (retagging doesn't touch content) — this is exactly the shape that exposed the
        // id/digest collision bug, so the mock models it faithfully rather than glossing over it.
        // A name always points at exactly one piece of content, so retagging onto an *existing*
        // destination name replaces that entry rather than appending a second row with its id.
        if let destination, !destination.isEmpty, destination != reference {
            let parts = destination.split(separator: ":", maxSplits: 1)
            let repo = String(parts.first ?? Substring(destination))
            let tag = parts.count > 1 ? String(parts[1]) : "latest"
            images.removeAll { $0.fullName == destination }
            images.append(ContainerImage(id: "\(repo):\(tag)", repository: repo, tag: tag,
                                         digest: source?.digest ?? "sha256:\(UUID().uuidString.prefix(12).lowercased())",
                                         arch: source?.arch ?? ["arm64"], sizeBytes: totalBytes,
                                         created: "just now", source: source?.source ?? .built, usage: .unused))
        }
    }

    /// Synthetic live metrics so the Overview cards and sparklines behave in mock mode (they
    /// previously sat on "Collecting…" forever, because the view polled the real daemon
    /// directly). Values wander on slow sine curves from a per-container seed: alive-looking
    /// charts, deterministic across launches (no randomness — the seed is derived from the id's
    /// scalar sum, not `hashValue`, which is salted per process).
    override func containerStatsStream(id: String) -> AsyncStream<ContainerStatsSample> {
        let seed = Double(id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 40)
        return AsyncStream { continuation in
            let task = Task {
                var tick = 0.0
                while !Task.isCancelled {
                    continuation.yield(ContainerStatsSample(
                        cpuPercent: max(0, 8 + seed / 4 + 6 * sin(tick / 3)),
                        memoryMB: 120 + seed * 4 + 20 * sin(tick / 5),
                        networkMBPerSecond: max(0, 0.8 + 0.6 * sin(tick / 2))
                    ))
                    tick += 1
                    try? await Task.sleep(for: .seconds(1))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
