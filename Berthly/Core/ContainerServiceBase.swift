// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Observation
import TerminalProgress

/// Observable base class for the container service layer.
/// Inject via .environment(service as ContainerServiceBase).
/// Access in views via @Environment(ContainerServiceBase.self).
/// A class rather than a protocol because `@Environment` needs a concrete `@Observable` type, so
/// abstract operations trap instead: a missing override must not silently report success.
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
    var pinnedContainerOrder: [String] = []
    var pinnedMachineOrder: [String] = []

    /// Remote digest-check results, keyed by `ContainerImage.id`. Lives here (not on the model)
    /// so badge views observe the dictionary through `@Environment` and re-render on check
    /// results without widening `ContainerImage.==`.
    var imageUpdateInfo: [String: ImageUpdateInfo] = [:]
    var lastImageUpdateCheck: Date?
    /// Drives the Images toolbar's check-in-progress spinner.
    var isCheckingImageUpdates = false

    /// Set when `startDaemon()` connects fine but a background bootstrap step (installing the
    /// vminit filesystem image or default kernel, or loading the user's `config.toml`) failed —
    /// the daemon reports `.connected` regardless (it's the correct state for most purposes), so
    /// without this the failure is otherwise invisible until an unrelated later operation fails
    /// for a confusing reason. `nil` means no warning; cleared at the start of every
    /// `startDaemon()` call.
    var lastStartupWarning: String?

    /// The running daemon's version, from the health-check ping. `nil` before the first
    /// successful connect. Compared against `ContainerCompatibility.requiredVersion` to decide
    /// `.connected` vs `.versionMismatch`.
    var installedContainerVersion: String?

    /// The version the System page compares `installedContainerVersion` against. Always the real
    /// pin, except in the mock's `patchBehind` state: when the pin equals `patchFloor`, no real
    /// daemon is patch-behind, so that state supplies its own pair to stay reachable (#194).
    var requiredContainerVersion = ContainerCompatibility.requiredVersion

    /// System-page data, fetched on demand when that page appears rather than on every
    /// `refresh()` poll — it's low-frequency, look-it-up-when-needed information.
    var diskUsage: DiskUsageSummary?
    var kernelInfo: KernelInfo?
    var systemConfigInfo: SystemConfigInfo?
    /// Resolved system properties (like `container system property list`), defaults included.
    /// Read-only in Berthly — editing stays a `config.toml` / CLI affair.
    var systemProperties: [SystemProperty]?

    func buildContext(for reference: String) -> BuildContext? { buildContexts[reference] }
    func saveBuildContext(_ ctx: BuildContext, for reference: String) { buildContexts[reference] = ctx }

    func isContainerPinned(_ id: String) -> Bool { pinnedContainerIDs.contains(id) }
    func isMachinePinned(_ id: String) -> Bool { pinnedMachineIDs.contains(id) }

    /// Pinning is the natural moment to ask for notification permission — it's the
    /// declared "notify me if this changes while I'm away" gesture, and the grant is
    /// settled well before any status-change notification would fire. Only requested on
    /// the transition into pinned, not on unpin.
    func togglePinContainer(_ id: String) {
        if !pinnedContainerIDs.insert(id).inserted {
            pinnedContainerIDs.remove(id)
            pinnedContainerOrder.removeAll { $0 == id }
        } else {
            pinnedContainerOrder.append(id)
            AppNotifier.shared.prepare()
        }
    }
    func togglePinMachine(_ id: String) {
        if !pinnedMachineIDs.insert(id).inserted {
            pinnedMachineIDs.remove(id)
            pinnedMachineOrder.removeAll { $0 == id }
        } else {
            pinnedMachineOrder.append(id)
            AppNotifier.shared.prepare()
        }
    }

    /// `visible` is the current on-screen order of the pinned list being reordered.
    func movePinnedContainers(visible: [String], sources: [String], before target: String?) {
        pinnedContainerOrder = PinOrder.moved(
            visible: visible, sources: sources, before: target, remembered: pinnedContainerOrder)
    }
    func movePinnedMachines(visible: [String], sources: [String], before target: String?) {
        pinnedMachineOrder = PinOrder.moved(
            visible: visible, sources: sources, before: target, remembered: pinnedMachineOrder)
    }
    func buildImage(options: BuildOptions, onLog: @MainActor @escaping (String) -> Void) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    @discardableResult
    func runContainer(options: RunOptions, onLog: (@MainActor (String) -> Void)? = nil) async throws -> String {
        assertionFailure("\(#function) must be overridden")
        return ""
    }
    func createMachine(options: MachineCreateOptions, onLog: (@MainActor (String) -> Void)? = nil) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func createVolume(options: VolumeCreateOptions) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func createNetwork(options: NetworkCreateOptions) async throws {
        assertionFailure("\(#function) must be overridden")
    }

    func startContainer(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func stopContainer(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func restartContainer(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Send SIGKILL to a running container (like `container kill`) — the unwedge path for a
    /// container that ignores `stopContainer`'s graceful SIGTERM. The process gets no chance to
    /// flush or clean up; the container itself remains, stopped.
    func killContainer(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func deleteContainer(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Export a stopped or running container's filesystem as a tar archive at `path` (like
    /// `container export -o`); callers gate the action on those two states. No progress
    /// reporting — the export API offers none.
    func exportContainer(_ id: String, to path: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Snapshot a container's filesystem into a new local image (like `container commit`).
    /// Returns the normalized reference created, as `tagImage` does.
    @discardableResult
    func commitContainer(_ id: String, reference: String) async throws -> String {
        assertionFailure("\(#function) must be overridden")
        return reference
    }

    /// Copy a file or directory between the host and container `containerID`'s filesystem.
    /// `hostPath` is a path on the Mac, `containerPath` a path inside the container; `direction`
    /// decides which is the source. Missing parent directories on the destination are created
    /// automatically. See `LiveContainerService.copyArguments(...)` for the source/destination
    /// mapping and `resolvedHostDestination(...)` for how a chosen host *folder* becomes a target.
    func copyFiles(direction: CopyDirection, containerID: String, hostPath: String, containerPath: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func startMachine(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func stopMachine(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func deleteMachine(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Make `id` the default machine (like `container machine set-default`) — the target of
    /// `container machine run` with no ID. Reflected in `Machine.isDefault` on the next refresh.
    func setDefaultMachine(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Reconfigure an existing machine's boot settings (like `container machine set`). Changes
    /// apply the next time the machine boots — a running machine keeps its current resources
    /// until stopped and started again.
    func updateMachine(_ id: String, options: MachineUpdateOptions) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func deleteImage(_ reference: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func deleteVolume(_ name: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func deleteNetwork(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Boot the stopped builder container — like `container builder start`. Uses the configured
    /// default CPU/memory (the CLI's `-c`/`-m` overrides stay a CLI affair); a later build reuses
    /// the running builder instead of paying the boot cost itself.
    func startBuilder(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func stopBuilder(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Delete the (stopped) builder container and its build cache — like `container builder
    /// delete`. The next build recreates the builder automatically, so this is the "reset a
    /// wedged/bloated builder" action, not a permanent removal. Callers gate on stopped status
    /// (the CLI requires `--force` to delete a running builder; the GUI just doesn't offer it).
    func deleteBuilder(_ id: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func pullImage(reference: String, platform: String? = nil, insecure: Bool = false,
                   progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {
        assertionFailure("\(#function) must be overridden")
    }

    func updateAvailability(for image: ContainerImage) -> ImageUpdateAvailability {
        ImageStaleness.availability(image: image, info: imageUpdateInfo[image.id])
    }
    func staleness(of container: Container) -> ContainerImageStaleness {
        ImageStaleness.staleness(containerImageRef: container.image, containerImageDigest: container.imageDigest,
                                 images: images, updateInfo: imageUpdateInfo)
    }
    /// Whether `reference`'s registry host has been remembered as insecure (Pull/Push/Run/
    /// Sign-in's "Allow insecure registry" toggle) — used to prefill Pull Latest's own toggle so
    /// re-pulling a known-insecure host's tag doesn't need re-asking.
    func isKnownInsecureRegistry(forReference reference: String) -> Bool {
        assertionFailure("\(#function) must be overridden")
        return false
    }
    /// Compare each eligible local image's digest against its registry (HEAD manifest, no pull)
    /// and record the results in `imageUpdateInfo`. Failures are silent per image — a background
    /// nicety must never alert; a failed check just means no badge.
    func checkForImageUpdates(force: Bool = false) async {
        assertionFailure("\(#function) must be overridden")
    }
    /// Watchtower-style update: optionally pull the container's tag, then stop/delete/recreate it
    /// from the stored configuration with the fresh image digest, restoring the prior run state.
    /// `onPhase` narrates steps for the sheet; only the pull phase honors cancellation.
    @discardableResult
    func recreateContainer(_ id: String, pullFirst: Bool, progress: ProgressUpdateHandler? = nil,
                           onPhase: @MainActor @escaping (RecreatePhase) -> Void) async throws -> RecreateResult {
        assertionFailure("\(#function) must be overridden")
        return RecreateResult(wasRunning: false, didPull: false, oldImageDigest: "", newImageDigest: "")
    }
    /// Garbage-collect content blobs no longer referenced by any image — what a same-tag re-pull
    /// leaves behind (apple/container *replaces* the reference, so there's no dangling image row
    /// to delete, only orphaned bytes). Returns freed bytes.
    @discardableResult
    func reclaimOrphanedImageBlobs() async throws -> UInt64 {
        assertionFailure("\(#function) must be overridden")
        return 0
    }
    /// Create an additional local reference for an existing image (like `container image tag`).
    /// Returns the reference actually created: normalization can add a default registry host,
    /// a `library/` namespace, or `:latest` — the UI shows the result so that isn't a surprise.
    @discardableResult
    func tagImage(reference: String, newReference: String) async throws -> String {
        assertionFailure("\(#function) must be overridden")
        return newReference
    }
    /// Export images as an OCI tar archive at `path` (like `container image save -o`). No
    /// progress reporting: the daemon's save API offers none, so callers show indeterminate
    /// progress. `platform` limits the archive to one platform; `nil` saves every variant.
    func saveImages(references: [String], to path: String, platform: String? = nil) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Import images from an OCI tar archive (like `container image load -i`) and unpack each
    /// (`progress` reports the unpack phase — the load phase itself is silent). `force` loads
    /// despite invalid archive member files, which are skipped and reported in the summary.
    func loadImages(from path: String, force: Bool = false, progress: ProgressUpdateHandler? = nil) async throws -> ImageLoadSummary {
        assertionFailure("\(#function) must be overridden")
        return ImageLoadSummary(loadedReferences: [], rejectedMembers: [])
    }
    /// Push a local image to a registry. When `destination` is set and differs from `reference`,
    /// the image is retagged to that registry-qualified reference before pushing — the native push
    /// requires a registry host in the reference, which a locally-built name like `local/web:1.4`
    /// lacks. Progress mirrors `pullImage`.
    func pushImage(reference: String, destination: String? = nil, platform: String? = nil,
                   insecure: Bool = false, progress: ProgressUpdateHandler? = nil) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// `onLog` reports slow first-run bootstrap steps (kernel/vminit downloads) that otherwise
    /// happen silently inside daemon startup — the guided install flow shows them in its log.
    func startDaemon(onLog: (@MainActor (String) -> Void)? = nil) async {
        assertionFailure("\(#function) must be overridden")
    }
    func stopDaemon() async {
        assertionFailure("\(#function) must be overridden")
    }
    func upgradeContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// First-time guided install of the `container` toolchain: download the pinned release's
    /// signed pkg, verify its signature, run the installer (admin prompt), then start the daemon.
    func installContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func refresh() async {
        assertionFailure("\(#function) must be overridden")
    }

    /// Live resource samples for a running container, one every couple of seconds, already in
    /// display units (see `ContainerStatsSample`). The stream runs until the consuming task is
    /// cancelled (the detail view ties it to `.task`); a stopped or missing container simply
    /// yields nothing further.
    func containerStatsStream(id: String) -> AsyncStream<ContainerStatsSample> {
        assertionFailure("\(#function) must be overridden")
        return AsyncStream { $0.finish() }
    }

    func fetchDiskUsage() async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Remove images not used by any container. Safe/re-pullable cache cleanup. Returns what was freed.
    func pruneImages() async throws -> PruneResult {
        assertionFailure("\(#function) must be overridden")
        return PruneResult()
    }
    /// Delete stopped containers (never machines or builders). More consequential than image
    /// cleanup — removes the container and its writable layer. Returns what was freed.
    func pruneStoppedContainers() async throws -> PruneResult {
        assertionFailure("\(#function) must be overridden")
        return PruneResult()
    }
    /// Delete volumes not mounted by any container (like `container volume prune`). The most
    /// consequential cleanup of all — an unattached volume can hold real data — so it never runs
    /// as part of `pruneAll()`; only its own explicitly-confirmed action calls it.
    func pruneVolumes() async throws -> PruneResult {
        assertionFailure("\(#function) must be overridden")
        return PruneResult()
    }
    /// Delete networks with no container connections (like `container network prune`). Never
    /// deletes the built-in default network. Frees no disk space, only tidies the network list.
    func pruneNetworks() async throws -> PruneResult {
        assertionFailure("\(#function) must be overridden")
        return PruneResult()
    }
    /// "Clean Up All": runs image and stopped-container cleanup independently so a failure in one
    /// doesn't skip or discard a successful result from the other. Subclasses with a live daemon
    /// connection can override this to share a single container-list fetch between the two phases
    /// instead of each fetching its own (see `LiveContainerService`).
    func pruneAll() async -> CleanUpAllResult {
        var combined = PruneResult()
        var failures: [String] = []
        do {
            combined += try await pruneImages()
        } catch {
            failures.append("Removing unused images failed: \(error.localizedDescription)")
        }
        do {
            combined += try await pruneStoppedContainers()
        } catch {
            failures.append("Removing stopped containers failed: \(error.localizedDescription)")
        }
        return CleanUpAllResult(result: combined, failureMessages: failures)
    }
    func fetchKernelInfo() async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func fetchSystemConfig() async throws {
        assertionFailure("\(#function) must be overridden")
    }
    /// Refreshes `systemProperties` from the resolved system configuration.
    func fetchSystemProperties() async {
        assertionFailure("\(#function) must be overridden")
    }
    func streamDaemonLogs(onLine: @MainActor @escaping (String) -> Void) async throws {
        assertionFailure("\(#function) must be overridden")
    }

    /// Refreshes `registries` from the Keychain. Page-specific, fetched on demand (like
    /// `fetchDiskUsage`/`fetchKernelInfo`) rather than on every poll tick.
    func loadRegistries() async {
        assertionFailure("\(#function) must be overridden")
    }
    func signInRegistry(host: String, username: String, password: String, insecure: Bool = false) async throws {
        assertionFailure("\(#function) must be overridden")
    }
    func signOutRegistry(host: String) async throws {
        assertionFailure("\(#function) must be overridden")
    }

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

    var pinnedContainers: [Container] {
        PinOrder.sorted(containers.filter { pinnedContainerIDs.contains($0.id) }, by: pinnedContainerOrder)
    }
    var pinnedMachines: [Machine] {
        PinOrder.sorted(machines.filter { pinnedMachineIDs.contains($0.id) && !$0.isUtility }, by: pinnedMachineOrder)
    }
}
