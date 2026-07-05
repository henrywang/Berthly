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

extension DiskUsageSummary {
    var totalSizeBytes: UInt64 { images.sizeBytes + containers.sizeBytes + volumes.sizeBytes }

    /// Images + containers only — what a combined "Clean Up All" would free. Excludes volumes:
    /// an unattached volume can hold real data the user means to reattach, so Clean Up never
    /// deletes one automatically (see `PruneContainerInfo`'s doc and `LiveContainerService`).
    var cleanableReclaimableBytes: UInt64 { images.reclaimableBytes + containers.reclaimableBytes }
}

extension DiskUsageSummary.Category {
    /// Reclaimable as a percentage of this category's total size, rounded to the nearest whole
    /// percent. `0` (not NaN/crash) when size is zero, so an empty category renders "0%" cleanly.
    var reclaimablePercent: Int {
        guard sizeBytes > 0 else { return 0 }
        return Int((Double(reclaimableBytes) / Double(sizeBytes) * 100).rounded())
    }
}

/// Human-readable byte size (KB/MB/GB), used throughout the System page's disk-usage displays and
/// by `PruneResult.summaryText` below.
func formatDiskBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1_024 { return String(format: "%.1f GB", mb / 1_024) }
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    let kb = Double(bytes) / 1024
    if kb >= 1 { return String(format: "%.0f KB", kb) }
    return "\(bytes) B"
}

/// A container reduced to just the fields the stopped-container cleanup needs, extracted from the
/// SDK's snapshot type at the service boundary so the selection stays a pure, testable function.
///
/// `isInfrastructure` marks machine-backed and builder containers. In apple/container a machine is
/// a container under the hood (which is why every mutating CLI command filters `.withoutMachines()`),
/// so a *stopped VM* would otherwise look like a prunable stopped container — deleting it is
/// irreversible data loss. Such containers are excluded from deletion; their images are separately
/// protected by the image cleanup, which treats every container's image as in-use.
struct PruneContainerInfo: Sendable, Equatable {
    let id: String
    let imageReference: String
    let isStopped: Bool
    let isInfrastructure: Bool
}

/// Outcome of a cleanup action — what it actually freed. Each disk category has its own action, so
/// a given result populates only its own fields (image cleanup fills the image fields, etc.).
/// Volumes have no cleanup action at all, by design.
struct PruneResult: Sendable, Equatable {
    var imagesFreedBytes: UInt64 = 0
    var containersFreedBytes: UInt64 = 0
    var deletedImageCount: Int = 0
    var deletedContainerCount: Int = 0
    /// Per-item delete failures (logged and skipped, not fatal). Lets the UI distinguish
    /// "nothing to remove" from "everything failed" when `deletedCount` is 0.
    var failedCount: Int = 0

    var totalFreedBytes: UInt64 { imagesFreedBytes + containersFreedBytes }
    var deletedCount: Int { deletedImageCount + deletedContainerCount }

    /// Combines two independent cleanup outcomes into one — used by "Clean Up All", which runs
    /// image and container cleanup as two separate calls (each keeping its own safety logic) but
    /// reports one aggregated result.
    static func + (lhs: PruneResult, rhs: PruneResult) -> PruneResult {
        PruneResult(
            imagesFreedBytes: lhs.imagesFreedBytes + rhs.imagesFreedBytes,
            containersFreedBytes: lhs.containersFreedBytes + rhs.containersFreedBytes,
            deletedImageCount: lhs.deletedImageCount + rhs.deletedImageCount,
            deletedContainerCount: lhs.deletedContainerCount + rhs.deletedContainerCount,
            failedCount: lhs.failedCount + rhs.failedCount
        )
    }

    /// Formats this result for display, whether it came from a single-category cleanup or the
    /// combined "Clean Up All" (a `+` of two independent results). Reads directly off
    /// `deletedImageCount`/`deletedContainerCount` rather than taking a caller-supplied noun, so the
    /// same formatting works for "8 images", "4 stopped containers", or both joined together without
    /// the caller needing to know which case it is.
    ///
    /// Guards on `totalFreedBytes > 0` in addition to `deletedCount > 0`: orphaned-blob GC
    /// (`cleanUpOrphanedBlobs()`) can free real bytes on a run where zero images were freshly
    /// untagged (e.g. blobs left over from an earlier partial failure) — without this, that case
    /// would misreport "Nothing to remove" despite disk space actually having been reclaimed.
    var summaryText: String {
        guard deletedCount > 0 || totalFreedBytes > 0 else {
            if failedCount > 0 {
                return "Couldn't remove anything — \(failedCount) operation\(failedCount == 1 ? "" : "s") failed. See the daemon logs for details."
            }
            return "Nothing to remove."
        }
        var parts: [String] = []
        if deletedImageCount > 0 {
            parts.append("\(deletedImageCount) image\(deletedImageCount == 1 ? "" : "s")")
        }
        if deletedContainerCount > 0 {
            parts.append("\(deletedContainerCount) stopped container\(deletedContainerCount == 1 ? "" : "s")")
        }
        var text = "Reclaimed \(formatDiskBytes(totalFreedBytes))"
        text += parts.isEmpty ? " of unused disk space." : " — removed \(parts.joined(separator: " and "))."
        if failedCount > 0 {
            text += " \(failedCount) couldn't be removed."
        }
        return text
    }
}

/// Outcome of "Clean Up All" — image cleanup and stopped-container cleanup run as two independent
/// calls (see `ContainerServiceBase.pruneAll()`), so either can fail without the other being skipped
/// or its success discarded. `result` is always the sum of whatever succeeded; `failureMessages`
/// holds one human-readable line per failed phase, empty when both succeeded.
struct CleanUpAllResult: Sendable, Equatable {
    var result: PruneResult = PruneResult()
    var failureMessages: [String] = []

    /// `nil` when both phases succeeded (caller should treat `result` as a plain success). Otherwise
    /// the message to show in an error alert — folding in `result.summaryText` first when something
    /// was still freed, so a real partial success is never hidden behind a bare failure message.
    var errorAlertMessage: String? {
        guard !failureMessages.isEmpty else { return nil }
        if result.deletedCount > 0 || result.totalFreedBytes > 0 {
            return "\(result.summaryText)\n\n\(failureMessages.joined(separator: "\n"))"
        }
        return failureMessages.joined(separator: "\n")
    }
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
