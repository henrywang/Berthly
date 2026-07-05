import Foundation
import TerminalProgress

@MainActor
final class MockContainerService: ContainerServiceBase {

    override init() {
        super.init()
        daemonState = .connected
        installedContainerVersion = ContainerCompatibility.requiredVersion
        containers = [
            Container(id: "3f9a2b7c1d", name: "web-frontend",  image: "local/web:1.4",       status: .running, ports: [PortMapping(host: 3000, container: 3000)], cpuPercent: 12, memoryMB: 184,  memoryLimitMB: 1024, networkIOString: "1.2 MB/s", uptime: "2h 41m", command: #"nginx -g "daemon off;""#,   mounts: [ContainerMount(source: "./src", destination: "/app")], networks: ["app-net"], environment: ["NODE_ENV=production", "PORT=3000", "API_URL=http://api-service:8080"], startedDate: Date().addingTimeInterval(-(2*3600 + 41*60))),
            Container(id: "a17c44e9b2", name: "api-service",   image: "local/api:2.1",       status: .running, ports: [PortMapping(host: 8080, container: 8080)], cpuPercent: 34, memoryMB: 320,  memoryLimitMB: 2048, networkIOString: "3.4 MB/s", uptime: "5h 12m", command: "node server.js",               mounts: [], networks: ["app-net"], environment: ["NODE_ENV=production"],                                                                                            startedDate: Date().addingTimeInterval(-(5*3600 + 12*60))),
            Container(id: "c20e81f7a4", name: "datastore",     image: "local/datastore:15",  status: .running, ports: [PortMapping(host: 5432, container: 5432)], cpuPercent:  8, memoryMB: 512,  memoryLimitMB: 1024, networkIOString: "0.8 MB/s", uptime: "1d 3h",  command: "postgres",                       mounts: [], networks: ["app-net"], environment: [],                                                                                                               startedDate: Date().addingTimeInterval(-(27*3600))),
            Container(id: "7b3d09c5e1", name: "cache",         image: "local/cache:7",       status: .running, ports: [PortMapping(host: 6379, container: 6379)], cpuPercent:  2, memoryMB:  64,  memoryLimitMB:  512, networkIOString: "0.2 MB/s", uptime: "1d 3h",  command: "redis-server",                   mounts: [], networks: ["app-net"], environment: [],                                                                                                               startedDate: Date().addingTimeInterval(-(27*3600))),
            Container(id: "d4e5f6a7b8", name: "worker",        image: "local/worker:1.0",    status: .stopped, ports: [],                                          cpuPercent:  0, memoryMB:   0,  memoryLimitMB:  512, networkIOString: "–",        uptime: "–",      command: "python worker.py",                mounts: [], networks: [],          environment: []),
            Container(id: "b4c8d2e6f0", name: "edge-proxy",    image: "local/proxy:1.25",    status: .error,   ports: [PortMapping(host: 80, container: 80), PortMapping(host: 443, container: 443)], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 256, networkIOString: "–", uptime: "–", command: "nginx", mounts: [], networks: [], environment: []),
            Container(id: "1a2b3c4d5e", name: "sandbox",       image: "local/base:latest",   status: .paused,  ports: [],                                          cpuPercent:  0, memoryMB:   0,  memoryLimitMB:  512, networkIOString: "–",        uptime: "–",      command: "/bin/bash",                       mounts: [], networks: [],          environment: []),
        ]
        images = [
            ContainerImage(id: "3f9a2b7c1d", repository: "local/web",       tag: "1.4",    arch: ["arm64", "amd64"], sizeBytes: 182 * 1_048_576, created: "2h ago",  source: .built,  usage: .usedBy(3)),
            ContainerImage(id: "a17c44e9b2", repository: "local/api",       tag: "2.1",    arch: ["arm64"],          sizeBytes: 240 * 1_048_576, created: "5h ago",  source: .built,  usage: .usedBy(1)),
            ContainerImage(id: "c20e81f7a4", repository: "local/datastore", tag: "15",     arch: ["arm64", "amd64"], sizeBytes: 410 * 1_048_576, created: "1d ago",  source: .built,  usage: .usedBy(1)),
            ContainerImage(id: "7b3d09c5e1", repository: "local/cache",     tag: "7",      arch: ["arm64"],          sizeBytes:  38 * 1_048_576, created: "1d ago",  source: .built,  usage: .usedBy(1)),
            ContainerImage(id: "1a2b3c4d5e", repository: "local/base",      tag: "latest", arch: ["arm64", "amd64"], sizeBytes:  96 * 1_048_576, created: "3d ago",  source: .pulled, usage: .usedBy(2)),
            ContainerImage(id: "b4c8d2e6f0", repository: "local/proxy",     tag: "1.25",   arch: ["amd64"],          sizeBytes:  54 * 1_048_576, created: "2d ago",  source: .built,  usage: .unused),
            ContainerImage(id: "9f2c1a7e44", repository: "buildkit",        tag: "0.13",   arch: ["arm64", "amd64"], sizeBytes: 160 * 1_048_576, created: "1w ago",  source: .pulled, usage: .builderImage),
        ]
        volumes = [
            Volume(id: "pgdata",    name: "pgdata",    type: .named,     usedMB: 742, allocatedMB: 2048, driver: "local", source: "~/Library/Application Support/com.apple.container/volumes/pgdata",    created: "08:58", labels: ["app=datastore"], mounts: [VolumeMount(containerName: "datastore",  mountPath: "/var/lib/postgresql/data", mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "shared",    name: "shared-…",  type: .named,     usedMB: 318, allocatedMB:  512, driver: "local", source: "",                                                                     created: "08:30", labels: [],                mounts: [VolumeMount(containerName: "web-frontend", mountPath: "/shared",  mode: "RW"), VolumeMount(containerName: "api-service", mountPath: "/shared", mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "redis",     name: "redis-data", type: .named,    usedMB:  48, allocatedMB:  256, driver: "local", source: "",                                                                     created: "09:00", labels: [],                mounts: [VolumeMount(containerName: "cache",       mountPath: "/data",    mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "worker-q",  name: "worker-q…", type: .named,     usedMB:  12, allocatedMB:  128, driver: "local", source: "",                                                                     created: "09:05", labels: [],                mounts: [VolumeMount(containerName: "worker",      mountPath: "/queue",   mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "model",     name: "model-c…",  type: .named,     usedMB: 3400, allocatedMB: 4096, driver: "local", source: "",                                                                    created: "08:00", labels: [],                mounts: [],                                                                                                                                                     fs: "ext4", reclaimable: false),
            Volume(id: "anon1",     name: "8349ab8d…", type: .anonymous, usedMB: 214, allocatedMB: 1024, driver: "local", source: "",                                                                     created: "08:58", labels: [],                mounts: [VolumeMount(containerName: "datastore",  mountPath: "/tmp",     mode: "RW")], fs: "ext4", reclaimable: false),
            Volume(id: "anon2",     name: "1c4f0a7e…", type: .anonymous, usedMB:  96, allocatedMB:  512, driver: "local", source: "",                                                                     created: "08:58", labels: [],                mounts: [],                                                                                                                                                     fs: "ext4", reclaimable: true),
        ]
        networks = [
            Network(id: "app-net", name: "app-net", driver: .nat,      subnet: "192.168.65.0/24", gateway: "192.168.65.1", isDefault: false, scope: "local", ipv6Enabled: false, egress: "NAT → en0", attachable: true, backend: "vmnet", endpoints: [NetworkEndpoint(id: "e1", name: "web-frontend", ipv4: "192.168.65.2", kind: "CONTAINER", isRunning: true,  aliases: []), NetworkEndpoint(id: "e2", name: "api-service", ipv4: "192.168.65.3", kind: "CONTAINER", isRunning: true, aliases: [])]),
            Network(id: "data-net", name: "data-net", driver: .hostOnly, subnet: "192.168.66.0/24", gateway: "192.168.66.1", isDefault: false, scope: "local", ipv6Enabled: false, egress: "",          attachable: true, backend: "vmnet", endpoints: []),
            Network(id: "default",  name: "default",  driver: .nat,      subnet: "192.168.64.0/24", gateway: "192.168.64.1", isDefault: true,  scope: "local", ipv6Enabled: false, egress: "NAT → en0", attachable: true, backend: "vmnet", endpoints: [NetworkEndpoint(id: "e3", name: "dev",        ipv4: "192.168.64.3", kind: "MACHINE",   isRunning: true,  aliases: ["machine"]), NetworkEndpoint(id: "e4", name: "ci-runner", ipv4: "192.168.64.4", kind: "MACHINE", isRunning: false, aliases: ["machine"]), NetworkEndpoint(id: "e5", name: "default", ipv4: "192.168.64.2", kind: "MACHINE", isRunning: true, aliases: ["machine", "utility VM"])]),
        ]
        machines = [
            Machine(id: "dev",       name: "dev",       image: "ubuntu:24.04", status: .running, isUtility: false, diskUsedGB: 3.1, diskTotalGB: 8.0, uptimeString: "1h 12m", kernel: "6.12.4-arm64", resources: "4 vCPU · 4 GB", created: "Jun 20", homeMount: .readWrite),
            Machine(id: "ci-runner", name: "ci-runner", image: "alpine:3.22",  status: .stopped, isUtility: false, diskUsedGB: 0.48, diskTotalGB: 2.0, uptimeString: "–",      kernel: "6.12.4-arm64", resources: "2 vCPU · 2 GB", created: "Jun 22", homeMount: .readOnly),
            Machine(id: "default",   name: "default",   image: "debian:12",    status: .running, isUtility: true,  diskUsedGB: 1.2,  diskTotalGB: 4.0, uptimeString: "6d 4h",  kernel: "6.12.4-arm64", resources: "2 vCPU · 4 GB", created: "Jun 15", homeMount: .none),
        ]
        builders = [
            Builder(id: "default", name: "default", image: "buildkit:0.13", status: .running, autoStarted: true, cpus: 2, memoryGB: 2),
        ]
        registries = [
            Registry(id: "ghcr.io",    name: "GitHub Container Registry",        host: "ghcr.io",             scope: .pushAndPull, status: .signedIn(username: "apple-bot")),
            Registry(id: "docker.io",  name: "Docker Hub",                        host: "docker.io",           scope: .pullOnly,    status: .signedIn(username: "berthly")),
            Registry(id: "ecr",        name: "Amazon Elastic Container Registry", host: "ECR · us-east-1",   scope: .unknown,     status: .notSignedIn),
            Registry(id: "gar",        name: "Google Artifact Registry",           host: "us-docker.pkg.dev", scope: .unknown,     status: .notSignedIn),
        ]
        imageInspectData = Self.mockInspectData()
        buildContexts = [
            "local/web:1.4": BuildContext(contextPath: "/Users/dev/projects/web", dockerfilePath: nil),
            "local/api:2.1": BuildContext(contextPath: "/Users/dev/projects/api", dockerfilePath: "Containerfile"),
        ]
    }

    private static func mockInspectData() -> [String: ImageInspectData] {
        let webVariants = [
            ImageVariantInfo(arch: "arm64", archVariant: "v8", sizeBytes: 182 * 1_048_576, digest: "sha256:arm64variant001"),
            ImageVariantInfo(arch: "amd64", archVariant: nil,  sizeBytes: 188 * 1_048_576, digest: "sha256:amd64variant001"),
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
            "CMD [\"nginx\",\"-g\",\"daemon off;\"]",
        ]

        let apiVariants = [ImageVariantInfo(arch: "arm64", archVariant: "v8", sizeBytes: 240 * 1_048_576, digest: "sha256:apiarm64variant001")]
        let apiEnv = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", "NODE_ENV=production", "NODE_VERSION=22.2.0"]
        let apiHistory = ["ADD file:def456 in /", "WORKDIR /srv", "npm install", "CMD [\"node\",\"server.js\"]"]

        return [
            "3f9a2b7c1d": ImageInspectData(variants: webVariants, command: "nginx -g daemon off;", workDir: "/app", user: "www-data", stopSignal: "SIGTERM", env: webEnv, labels: webLabels, history: webHistory),
            "a17c44e9b2": ImageInspectData(variants: apiVariants, command: "node server.js", workDir: "/srv", user: "", stopSignal: "", env: apiEnv, labels: [:], history: apiHistory),
        ]
    }

    // MARK: - Operations (simulated in mock)

    override func startContainer(_ id: String) async throws {
        guard let i = containers.firstIndex(where: { $0.id == id }) else { return }
        let c = containers[i]
        containers[i] = Container(id: c.id, name: c.name, image: c.image, status: .running, ports: c.ports, cpuPercent: 0, memoryMB: 0, memoryLimitMB: c.memoryLimitMB, networkIOString: "–", uptime: "0m", command: c.command, mounts: c.mounts, networks: c.networks, environment: c.environment)
    }

    override func stopContainer(_ id: String) async throws {
        guard let i = containers.firstIndex(where: { $0.id == id }) else { return }
        let c = containers[i]
        containers[i] = Container(id: c.id, name: c.name, image: c.image, status: .stopped, ports: c.ports, cpuPercent: 0, memoryMB: 0, memoryLimitMB: c.memoryLimitMB, networkIOString: "–", uptime: "–", command: c.command, mounts: c.mounts, networks: c.networks, environment: c.environment)
    }

    override func restartContainer(_ id: String) async throws {
        try await stopContainer(id)
        try await startContainer(id)
    }

    override func deleteContainer(_ id: String) async throws {
        containers.removeAll { $0.id == id }
        pinnedContainerIDs.remove(id)
    }

    override func startMachine(_ id: String) async throws {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        let m = machines[i]
        machines[i] = Machine(id: m.id, name: m.name, image: m.image, status: .running,
                              isUtility: m.isUtility, diskUsedGB: m.diskUsedGB,
                              diskTotalGB: m.diskTotalGB, uptimeString: "0m",
                              kernel: m.kernel, resources: m.resources, created: m.created,
                              homeMount: m.homeMount)
    }

    override func stopMachine(_ id: String) async throws {
        guard let i = machines.firstIndex(where: { $0.id == id }) else { return }
        let m = machines[i]
        machines[i] = Machine(id: m.id, name: m.name, image: m.image, status: .stopped,
                              isUtility: m.isUtility, diskUsedGB: m.diskUsedGB,
                              diskTotalGB: m.diskTotalGB, uptimeString: "–",
                              kernel: m.kernel, resources: m.resources, created: m.created,
                              homeMount: m.homeMount)
    }

    override func deleteMachine(_ id: String) async throws {
        machines.removeAll { $0.id == id }
        pinnedMachineIDs.remove(id)
    }

    override func stopBuilder(_ id: String) async throws {
        guard let i = builders.firstIndex(where: { $0.id == id }) else { return }
        let b = builders[i]
        builders[i] = Builder(id: b.id, name: b.name, image: b.image, status: .stopped,
                              autoStarted: b.autoStarted, cpus: b.cpus, memoryGB: b.memoryGB)
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

    override func fetchDiskUsage() async throws {
        diskUsage = DiskUsageSummary(
            images: .init(total: 12, active: 4, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
            containers: .init(total: 6, active: 2, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
            volumes: .init(total: 3, active: 1, sizeBytes: 512_000_000, reclaimableBytes: 0)
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

    override func fetchKernelInfo() async throws {
        kernelInfo = KernelInfo(path: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186", platform: "linux/arm64")
    }

    override func setKernel(options: KernelSetOptions, progress: ProgressUpdateHandler? = nil) async throws {
        kernelInfo = KernelInfo(path: options.binaryPath, platform: "linux/\(options.architecture)")
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
            "08:00:02.481\tError\txpc client handler connection error [error=Connection invalid]",
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
            "#7 naming to \(options.reference) done",
        ]
        for line in lines {
            try? await Task.sleep(for: .milliseconds(300))
            try Task.checkCancellation()
            onLog(line)
        }
        let parts = options.reference.split(separator: ":", maxSplits: 1)
        let repo = String(parts.first ?? Substring(options.reference))
        let tag = parts.count > 1 ? String(parts[1]) : "latest"
        images.append(ContainerImage(id: UUID().uuidString, repository: repo, tag: tag,
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
    }

    override func startDaemon() async {
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
        try? await Task.sleep(for: .milliseconds(200))
        onLog("Updated successfully")
        installedContainerVersion = ContainerCompatibility.requiredVersion
        await startDaemon()
    }

    override func pullImage(reference: String, platform: String? = nil, insecure: Bool = false, progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {
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
        images.append(ContainerImage(id: UUID().uuidString, repository: repo, tag: tag,
                                     arch: ["arm64"], sizeBytes: totalBytes,
                                     created: "just now", source: .pulled, usage: .unused))
    }
}
