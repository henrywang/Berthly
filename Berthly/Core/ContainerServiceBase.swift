// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Observation
import TerminalProgress

/// Observable base class for the container service layer.
/// Inject via .environment(service as ContainerServiceBase).
/// Access in views via @Environment(ContainerServiceBase.self).
@Observable
@MainActor
class ContainerServiceBase {
    var daemonState: DaemonState = .checking
    var containers: [Container] = []
    var images: [ContainerImage] = []
    var imageInspectData: [String: ImageInspectData] = [:]
    var volumes: [Volume] = []
    var networks: [Network] = []
    var machines: [Machine] = []
    var builders: [Builder] = []
    var registries: [Registry] = []
    var buildContexts: [String: BuildContext] = [:]
    var pinnedContainerIDs: Set<String> = []
    var pinnedMachineIDs: Set<String> = []

    /// Set when `startDaemon()` connects fine but a background bootstrap step (installing the
    /// vminit filesystem image or default kernel) failed — the daemon reports `.connected`
    /// regardless (it's the correct state for most purposes), so without this the failure is
    /// otherwise invisible until an unrelated later operation fails for a confusing reason.
    /// `nil` means no warning; cleared at the start of every `startDaemon()` call.
    var lastStartupWarning: String? = nil

    /// The running daemon's version, from the health-check ping. `nil` before the first
    /// successful connect. Compared against `ContainerCompatibility.requiredVersion` to decide
    /// `.connected` vs `.versionMismatch`.
    var installedContainerVersion: String? = nil

    /// System-page data, fetched on demand when that page appears rather than on every
    /// `refresh()` poll — it's low-frequency, look-it-up-when-needed information.
    var diskUsage: DiskUsageSummary? = nil
    var kernelInfo: KernelInfo? = nil
    var systemConfigInfo: SystemConfigInfo? = nil

    func buildContext(for reference: String) -> BuildContext? { buildContexts[reference] }
    func saveBuildContext(_ ctx: BuildContext, for reference: String) { buildContexts[reference] = ctx }

    func isContainerPinned(_ id: String) -> Bool { pinnedContainerIDs.contains(id) }
    func isMachinePinned(_ id: String) -> Bool { pinnedMachineIDs.contains(id) }

    func togglePinContainer(_ id: String) {
        if !pinnedContainerIDs.insert(id).inserted { pinnedContainerIDs.remove(id) }
    }
    func togglePinMachine(_ id: String) {
        if !pinnedMachineIDs.insert(id).inserted { pinnedMachineIDs.remove(id) }
    }
    func buildImage(options: BuildOptions, onLog: @MainActor @escaping (String) -> Void) async throws {}
    @discardableResult
    func runContainer(options: RunOptions) async throws -> String { "" }
    func createMachine(options: MachineCreateOptions) async throws {}
    func createVolume(options: VolumeCreateOptions) async throws {}
    func createNetwork(options: NetworkCreateOptions) async throws {}

    func startContainer(_ id: String) async throws {}
    func stopContainer(_ id: String) async throws {}
    func restartContainer(_ id: String) async throws {}
    func deleteContainer(_ id: String) async throws {}

    /// Copy a file or directory between the host and container `containerID`'s filesystem.
    /// `hostPath` is a path on the Mac, `containerPath` a path inside the container; `direction`
    /// decides which is the source. Missing parent directories on the destination are created
    /// automatically. See `LiveContainerService.copyArguments(...)` for the source/destination
    /// mapping and `resolvedHostDestination(...)` for how a chosen host *folder* becomes a target.
    func copyFiles(direction: CopyDirection, containerID: String, hostPath: String, containerPath: String) async throws {}
    func startMachine(_ id: String) async throws {}
    func stopMachine(_ id: String) async throws {}
    func deleteMachine(_ id: String) async throws {}
    func deleteImage(_ reference: String) async throws {}
    func deleteVolume(_ name: String) async throws {}
    func deleteNetwork(_ id: String) async throws {}
    func stopBuilder(_ id: String) async throws {}
    func pullImage(reference: String, platform: String? = nil, insecure: Bool = false, progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {}
    /// Create an additional local reference for an existing image (like `container image tag`).
    /// Returns the reference actually created: normalization can add a default registry host,
    /// a `library/` namespace, or `:latest` — the UI shows the result so that isn't a surprise.
    @discardableResult
    func tagImage(reference: String, newReference: String) async throws -> String { newReference }
    /// Export images as an OCI tar archive at `path` (like `container image save -o`). No
    /// progress reporting: the daemon's save API offers none, so callers show indeterminate
    /// progress. `platform` limits the archive to one platform; `nil` saves every variant.
    func saveImages(references: [String], to path: String, platform: String? = nil) async throws {}
    /// Import images from an OCI tar archive (like `container image load -i`) and unpack each
    /// (`progress` reports the unpack phase — the load phase itself is silent). `force` loads
    /// despite invalid archive member files, which are skipped and reported in the summary.
    func loadImages(from path: String, force: Bool = false, progress: ProgressUpdateHandler? = nil) async throws -> ImageLoadSummary {
        ImageLoadSummary(loadedReferences: [], rejectedMembers: [])
    }
    /// Push a local image to a registry. When `destination` is set and differs from `reference`,
    /// the image is retagged to that registry-qualified reference before pushing — the native push
    /// requires a registry host in the reference, which a locally-built name like `local/web:1.4`
    /// lacks. Progress mirrors `pullImage`.
    func pushImage(reference: String, destination: String? = nil, platform: String? = nil, insecure: Bool = false, progress: ProgressUpdateHandler? = nil) async throws {}
    /// `onLog` reports slow first-run bootstrap steps (kernel/vminit downloads) that otherwise
    /// happen silently inside daemon startup — the guided install flow shows them in its log.
    func startDaemon(onLog: (@MainActor (String) -> Void)? = nil) async {}
    func stopDaemon() async {}
    func upgradeContainer(onLog: @MainActor @escaping (String) -> Void) async throws {}
    /// First-time guided install of the `container` toolchain: download the pinned release's
    /// signed pkg, verify its signature, run the installer (admin prompt), then start the daemon.
    func installContainer(onLog: @MainActor @escaping (String) -> Void) async throws {}
    func refresh() async {}

    func fetchDiskUsage() async throws {}
    /// Remove images not used by any container. Safe/re-pullable cache cleanup. Returns what was freed.
    func pruneImages() async throws -> PruneResult { PruneResult() }
    /// Delete stopped containers (never machines or builders). More consequential than image
    /// cleanup — removes the container and its writable layer. Returns what was freed.
    func pruneStoppedContainers() async throws -> PruneResult { PruneResult() }
    /// "Clean Up All": runs image and stopped-container cleanup independently so a failure in one
    /// doesn't skip or discard a successful result from the other. Subclasses with a live daemon
    /// connection can override this to share a single container-list fetch between the two phases
    /// instead of each fetching its own (see `LiveContainerService`).
    func pruneAll() async -> CleanUpAllResult {
        var combined = PruneResult()
        var failures: [String] = []
        do {
            combined = combined + (try await pruneImages())
        } catch {
            failures.append("Removing unused images failed: \(error.localizedDescription)")
        }
        do {
            combined = combined + (try await pruneStoppedContainers())
        } catch {
            failures.append("Removing stopped containers failed: \(error.localizedDescription)")
        }
        return CleanUpAllResult(result: combined, failureMessages: failures)
    }
    func fetchKernelInfo() async throws {}
    func fetchSystemConfig() async throws {}
    func setKernel(options: KernelSetOptions, progress: ProgressUpdateHandler? = nil) async throws {}
    func streamDaemonLogs(onLine: @MainActor @escaping (String) -> Void) async throws {}

    /// Refreshes `registries` from the Keychain. Page-specific, fetched on demand (like
    /// `fetchDiskUsage`/`fetchKernelInfo`) rather than on every poll tick.
    func loadRegistries() async {}
    func signInRegistry(host: String, username: String, password: String) async throws {}
    func signOutRegistry(host: String) async throws {}

    var isConnected: Bool {
        if case .connected = daemonState { return true }
        return false
    }

    var runningContainers: [Container] { containers.filter { $0.status == .running } }
    // Excludes isUtility machines (e.g. the internal "default" VM) — same filter ComputeListView
    // applies, since these are runtime implementation details, not user-facing compute resources.
    var runningMachines: [Machine] { machines.filter { $0.status == .running && !$0.isUtility } }
    var errorContainerCount: Int { containers.filter { $0.status == .error }.count }
    var errorMachineCount: Int { machines.filter { $0.status == .error && !$0.isUtility }.count }

    var pinnedContainers: [Container] { containers.filter { pinnedContainerIDs.contains($0.id) } }
    var pinnedMachines: [Machine] { machines.filter { pinnedMachineIDs.contains($0.id) && !$0.isUtility } }
}
