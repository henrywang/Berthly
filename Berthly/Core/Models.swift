import Foundation

// MARK: - Compute selection (unified containers + machines)

enum ComputeItem: Hashable {
    case container(String) // containerID
    case machine(String)   // machineID
}

// MARK: - Daemon

enum DaemonState {
    case checking
    case notInstalled
    case installedButStopped
    case versionMismatch(installed: String, required: String)
    case connecting
    case stopping
    case connected
    case error(String)
}

// MARK: - Container

enum ContainerStatus: Equatable, Hashable {
    case running, stopped, error, paused
}

struct PortMapping: Hashable {
    let host: Int
    let container: Int

    var displayString: String { "\(host)→\(container)" }
}

struct ContainerMount: Hashable {
    let source: String
    let destination: String

    var displayString: String { "\(source) → \(destination)" }
}

struct Container: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: ContainerStatus
    let ports: [PortMapping]
    let cpuPercent: Double
    let memoryMB: Int
    let memoryLimitMB: Int
    let networkIOString: String
    let uptime: String
    let command: String
    let mounts: [ContainerMount]
    let networks: [String]
    let environment: [String]
    var startedDate: Date? = nil

    // Include status and image so SwiftUI detects section changes and late-arriving image data.
    // Hash by id only for stable Set membership across status/image transitions.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.status == rhs.status && lhs.image == rhs.image }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var portsDisplayString: String {
        ports.map(\.displayString).joined(separator: ", ")
    }

    var shortID: String { String(id.prefix(8)) }
}

// MARK: - Image

enum ImageSource { case built, pulled }

enum ImageUsage {
    case usedBy(Int)
    case unused
    case builderImage

    var displayString: String {
        switch self {
        case .usedBy(let n): return n == 1 ? "used by 1" : "used by \(n)"
        case .unused:        return "unused"
        case .builderImage:  return "builder image"
        }
    }
}

struct ContainerImage: Identifiable, Hashable {
    let id: String
    let repository: String
    let tag: String
    let arch: [String]
    let sizeBytes: Int64
    let created: String
    let source: ImageSource
    let usage: ImageUsage

    var fullName: String { "\(repository):\(tag)" }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Volume

enum VolumeType { case named, anonymous }

struct VolumeMount: Hashable {
    let containerName: String
    let mountPath: String
    let mode: String
}

struct Volume: Identifiable, Hashable {
    let id: String
    let name: String
    let type: VolumeType
    let usedMB: Int
    let allocatedMB: Int
    let driver: String
    let source: String
    let created: String
    let labels: [String]
    let mounts: [VolumeMount]
    let fs: String
    let reclaimable: Bool

    var usagePercent: Double {
        guard allocatedMB > 0 else { return 0 }
        return Double(usedMB) / Double(allocatedMB)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Network

enum NetworkDriver: String { case nat, hostOnly }

struct NetworkEndpoint: Identifiable, Hashable {
    let id: String
    let name: String
    let ipv4: String
    let kind: String
    let isRunning: Bool
    let aliases: [String]
}

struct Network: Identifiable, Hashable {
    let id: String
    let name: String
    let driver: NetworkDriver
    let subnet: String
    let gateway: String
    let isDefault: Bool
    let scope: String
    let ipv6Enabled: Bool
    let egress: String
    let attachable: Bool
    let backend: String
    let endpoints: [NetworkEndpoint]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Machine

enum MachineHomeMount: String, Hashable {
    case readOnly
    case readWrite
    case none
}

struct Machine: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: ContainerStatus
    let isUtility: Bool
    let diskUsedGB: Double
    let diskTotalGB: Double
    let uptimeString: String
    let kernel: String
    let resources: String
    let created: String
    let homeMount: MachineHomeMount

    var diskUsagePercent: Double {
        guard diskTotalGB > 0 else { return 0 }
        return diskUsedGB / diskTotalGB
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.status == rhs.status }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Builder

enum BuilderStatus { case running, stopped }

struct Builder: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let status: BuilderStatus
    let autoStarted: Bool
    var cpus: Int
    var memoryGB: Int

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - System page

struct DiskUsageSummary: Hashable {
    struct Category: Hashable {
        let total: Int
        let active: Int
        let sizeBytes: UInt64
        let reclaimableBytes: UInt64
    }
    let images: Category
    let containers: Category
    let volumes: Category
}

struct KernelInfo: Hashable {
    let path: String
    let platform: String
}

/// Full set of arguments for installing/switching the default kernel — mirrors
/// `container system kernel set`. `tarSource` may be a local file path or a
/// remote URL; when set, `binaryPath` names the member to extract from the
/// archive rather than a path on the local disk.
nonisolated struct KernelSetOptions {
    var binaryPath: String
    var tarSource: String?
    var architecture: String  // "arm64" or "amd64"
    var force: Bool = false
}

struct SystemConfigInfo: Hashable {
    let vminitImage: String
    let kernelBinaryPath: String
    let kernelURL: String
    let builderImage: String
    /// Pretty-printed JSON of the full decoded config.toml, for the raw property-list viewer.
    let rawJSON: String
}

// MARK: - Image inspect (pre-extracted from OCI types, no framework imports in views)

struct ImageVariantInfo: Hashable {
    let arch: String
    let archVariant: String?
    let sizeBytes: Int64
    let digest: String
}

struct ImageInspectData {
    let variants: [ImageVariantInfo]
    let command: String          // entrypoint + cmd joined
    let workDir: String
    let user: String
    let stopSignal: String
    let env: [String]
    let labels: [String: String]
    let history: [String]       // cleaned createdBy lines
}

// MARK: - Pinned items

/// Persisted set of pinned container/machine ids, shown in the menu bar regardless of state.
/// Top-level and `nonisolated` (rather than nested in `LiveContainerService`) so its Codable
/// conformance isn't main-actor-isolated — same reasoning as `BuildContext` below.
nonisolated struct PinnedItems: Codable {
    var containers: Set<String>
    var machines: Set<String>
}

// MARK: - Build

/// Persisted per-image build settings, used to pre-fill the Rebuild sheet.
/// Custom Codable so future fields can be added without breaking old saved JSON.
nonisolated struct BuildContext: Codable, Hashable {
    var contextPath: String
    var dockerfilePath: String?
    var platform: String?
    var buildArgs: [String: String]
    var labels: [String: String]
    var target: String?
    var noCache: Bool

    init(
        contextPath: String,
        dockerfilePath: String? = nil,
        platform: String? = nil,
        buildArgs: [String: String] = [:],
        labels: [String: String] = [:],
        target: String? = nil,
        noCache: Bool = false
    ) {
        self.contextPath = contextPath
        self.dockerfilePath = dockerfilePath
        self.platform = platform
        self.buildArgs = buildArgs
        self.labels = labels
        self.target = target
        self.noCache = noCache
    }

    enum CodingKeys: String, CodingKey {
        case contextPath, dockerfilePath, platform, buildArgs, labels, target, noCache
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextPath = try c.decode(String.self, forKey: .contextPath)
        dockerfilePath = try c.decodeIfPresent(String.self, forKey: .dockerfilePath)
        platform = try c.decodeIfPresent(String.self, forKey: .platform)
        buildArgs = try c.decodeIfPresent([String: String].self, forKey: .buildArgs) ?? [:]
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        target = try c.decodeIfPresent(String.self, forKey: .target)
        noCache = try c.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
    }
}

/// Full set of arguments for a `container build` invocation. Not persisted —
/// build-machine-specific fields (cpus/memory/secrets/pull) always reset to
/// defaults; the rest is seeded from a `BuildContext` on Rebuild.
nonisolated struct BuildOptions {
    var reference: String
    var contextPath: String
    var dockerfilePath: String?
    var platform: String?
    var buildArgs: [String: String] = [:]
    var noCache: Bool = false
    var labels: [String: String] = [:]
    var target: String?
    var cpus: Int?
    var memory: String?
    var secrets: [String] = []
    var pull: Bool = false
}

// MARK: - Run / Create container

/// Full set of arguments for a `container run`/`container create` invocation.
/// `start == true` builds a `run` (create + start); `start == false` builds a
/// `create` (provision only, left stopped). When `start`, `attach` picks
/// foreground (no `-d`, waits for exit and captures the container's own
/// stdout — for one-shot commands like `pwd`) vs. detached (the default, for
/// long-running services). This app never attaches an interactive terminal —
/// that's a separate exec/terminal feature.
nonisolated struct RunOptions {
    var reference: String
    var name: String?
    var command: [String] = []
    var ports: [String] = []
    var volumes: [String] = []
    var env: [String: String] = [:]
    var platform: String?
    var start: Bool = true
    var attach: Bool = false
    var remove: Bool = false
    var labels: [String: String] = [:]
    var networks: [String] = []
    var workdir: String?
    var user: String?
    var entrypoint: String?
    var cpus: Int?
    var memory: String?
    var readOnly: Bool = false
    var initProcess: Bool = false
    var rosetta: Bool = false
    var ssh: Bool = false
    var shmSize: String?
    var tmpfs: [String] = []
    var mounts: [String] = []
    var envFile: [String] = []
    var ulimits: [String] = []
    var insecureRegistry: Bool = false
    var interactive: Bool = false
    var tty: Bool = false
    var virtualization: Bool = false
    var capAdd: [String] = []
    var capDrop: [String] = []
    var cidFile: String?
    var dns: [String] = []
    var dnsDomain: String?
    var dnsOptions: [String] = []
    var dnsSearch: [String] = []
    var noDns: Bool = false
}

/// Captures stderr text alongside the exit code — unlike a build, run/create
/// output isn't already visible in a streaming log, so the message matters.
struct ContainerCLIError: LocalizedError {
    let exitCode: Int32
    let message: String
    var errorDescription: String? {
        message.isEmpty ? "Command failed (exit code \(exitCode))." : message
    }
}

// MARK: - Create machine

/// Full set of arguments for a `container machine create` invocation.
/// Unlike a container, there's no separate "run" verb — `create` always
/// provisions the machine; `boot == false` maps to `--no-boot`.
nonisolated struct MachineCreateOptions {
    var reference: String
    var name: String?
    var platform: String?
    var cpus: Int?
    var memory: String?
    var homeMount: String?
    var boot: Bool = true
    var setDefault: Bool = false
    var insecureRegistry: Bool = false
}

// MARK: - Registry

enum RegistryStatus: Equatable, Hashable {
    case signedIn(username: String)
    case notSignedIn
}

enum RegistryScope { case pushAndPull, pullOnly, unknown }

struct Registry: Identifiable, Hashable {
    let id: String
    let name: String
    let host: String
    let scope: RegistryScope
    let status: RegistryStatus

    var isSignedIn: Bool {
        if case .signedIn = status { return true }
        return false
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
