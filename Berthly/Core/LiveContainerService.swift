// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import class AppKit.NSApplication
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

/// Fields `mapImage`/inspect views need out of an `ImageResource`, decoded once per digest.
struct CachedImageMetadata {
    let arch: [String]
    let sizeBytes: Int64
    let created: String
    let inspectData: ImageInspectData
}

@MainActor
final class LiveContainerService: ContainerServiceBase {

    var pollTask: Task<Void, Never>?
    var isStarting = false
    var isStopping = false
    /// The in-flight elevated `osascript` (install/update), if any. Tracked so it can be killed
    /// on task cancellation and on app quit — an orphaned osascript otherwise blocks on its
    /// admin-password dialog forever and stalls every later authorization prompt behind it.
    var privilegedProcess: Foundation.Process?
    var isBuilding = false
    var systemConfig: ContainerSystemConfig?
    /// Decoded per-digest image metadata, keyed by `ClientImage.digest` (content-addressed,
    /// immutable). `toImageResource` walks the content store for the manifest index + OCI config
    /// of every platform variant — expensive enough that redoing it for every image on every 5s
    /// poll tick dominates steady-state CPU. Since a digest's content never changes, once decoded
    /// it's cached here and reused until the image is removed (evicted in `fetchImages`).
    var imageMetadataCache: [String: CachedImageMetadata] = [:]
    static let log = Logger(label: "app.berthly.container")
    // `?? { _ in }` inline doesn't infer `@Sendable` from context — a typed constant does.
    nonisolated static let noopProgressHandler: ProgressUpdateHandler = { _ in }

    // MARK: - Init

    override init() {
        super.init()
        loadBuildContexts()
        loadPinnedItems()
        startPolling()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.privilegedProcess?.terminate()
            }
        }
    }

    // MARK: - Persistence

    override func saveBuildContext(_ ctx: BuildContext, for reference: String) {
        super.saveBuildContext(ctx, for: reference)
        saveBuildContexts()
    }

    override func togglePinContainer(_ id: String) {
        super.togglePinContainer(id)
        savePinnedItems()
    }

    override func togglePinMachine(_ id: String) {
        super.togglePinMachine(id)
        savePinnedItems()
    }

    override func movePinnedContainers(visible: [String], sources: [String], before target: String?) {
        super.movePinnedContainers(visible: visible, sources: sources, before: target)
        savePinnedItems()
    }

    override func movePinnedMachines(visible: [String], sources: [String], before target: String?) {
        super.movePinnedMachines(visible: visible, sources: sources, before: target)
        savePinnedItems()
    }

    // MARK: - Daemon

    override func refresh() async {
        await poll()
    }

    override func startDaemon(onLog: (@MainActor (String) -> Void)? = nil) async {
        await startDaemonImpl(onLog: onLog)
    }

    override func stopDaemon() async {
        await stopDaemonImpl()
    }

    // MARK: - Install

    override func upgradeContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        try await upgradeContainerImpl(onLog: onLog)
    }

    override func installContainer(onLog: @MainActor @escaping (String) -> Void) async throws {
        try await installContainerImpl(onLog: onLog)
    }

    // MARK: - Lifecycle

    override func startContainer(_ id: String) async throws {
        try await startContainerImpl(id)
    }

    override func stopContainer(_ id: String) async throws {
        try await stopContainerImpl(id)
    }

    override func restartContainer(_ id: String) async throws {
        try await restartContainerImpl(id)
    }

    override func killContainer(_ id: String) async throws {
        try await killContainerImpl(id)
    }

    override func exportContainer(_ id: String, to path: String) async throws {
        try await exportContainerImpl(id, to: path)
    }

    override func commitContainer(_ id: String, reference: String) async throws -> String {
        try await commitContainerImpl(id, reference: reference)
    }

    override func deleteContainer(_ id: String) async throws {
        try await deleteContainerImpl(id)
    }

    override func copyFiles(direction: CopyDirection, containerID: String, hostPath: String, containerPath: String) async throws {
        try await copyFilesImpl(direction: direction, containerID: containerID, hostPath: hostPath, containerPath: containerPath)
    }

    override func startMachine(_ id: String) async throws {
        try await startMachineImpl(id)
    }

    override func stopMachine(_ id: String) async throws {
        try await stopMachineImpl(id)
    }

    override func deleteMachine(_ id: String) async throws {
        try await deleteMachineImpl(id)
    }

    override func setDefaultMachine(_ id: String) async throws {
        try await setDefaultMachineImpl(id)
    }

    override func updateMachine(_ id: String, options: MachineUpdateOptions) async throws {
        try await updateMachineImpl(id, options: options)
    }

    override func startBuilder(_ id: String) async throws {
        try await startBuilderImpl(id)
    }

    override func stopBuilder(_ id: String) async throws {
        try await stopBuilderImpl(id)
    }

    override func deleteBuilder(_ id: String) async throws {
        try await deleteBuilderImpl(id)
    }

    override func deleteImage(_ reference: String) async throws {
        try await deleteImageImpl(reference)
    }

    override func deleteVolume(_ name: String) async throws {
        try await deleteVolumeImpl(name)
    }

    override func deleteNetwork(_ id: String) async throws {
        try await deleteNetworkImpl(id)
    }

    override func createVolume(options: VolumeCreateOptions) async throws {
        try await createVolumeImpl(options: options)
    }

    override func createNetwork(options: NetworkCreateOptions) async throws {
        try await createNetworkImpl(options: options)
    }

    override func containerStatsStream(id: String) -> AsyncStream<ContainerStatsSample> {
        containerStatsStreamImpl(id: id)
    }

    // MARK: - System

    override func pruneImages() async throws -> PruneResult {
        try await pruneImages(allContainers: try await ContainerClient().list())
    }

    override func pruneStoppedContainers() async throws -> PruneResult {
        try await pruneStoppedContainers(allContainers: try await ContainerClient().list())
    }

    override func fetchDiskUsage() async throws {
        try await fetchDiskUsageImpl()
    }

    override func pruneVolumes() async throws -> PruneResult {
        try await pruneVolumesImpl()
    }

    override func pruneNetworks() async throws -> PruneResult {
        try await pruneNetworksImpl()
    }

    override func pruneAll() async -> CleanUpAllResult {
        await pruneAllImpl()
    }

    override func fetchKernelInfo() async throws {
        try await fetchKernelInfoImpl()
    }

    override func fetchSystemConfig() async throws {
        try await fetchSystemConfigImpl()
    }

    override func fetchSystemProperties() async {
        await fetchSystemPropertiesImpl()
    }

    override func streamDaemonLogs(onLine: @MainActor @escaping (String) -> Void) async throws {
        try await streamDaemonLogsImpl(onLine: onLine)
    }

    // MARK: - Registries

    override func loadRegistries() async {
        await loadRegistriesImpl()
    }

    override func signInRegistry(host: String, username: String, password: String, insecure: Bool = false) async throws {
        try await signInRegistryImpl(host: host, username: username, password: password, insecure: insecure)
    }

    override func signOutRegistry(host: String) async throws {
        try await signOutRegistryImpl(host: host)
    }

    // MARK: - Build

    override func buildImage(
        options: BuildOptions,
        onLog: @MainActor @escaping (String) -> Void
    ) async throws {
        try await buildImageImpl(options: options, onLog: onLog)
    }

    // MARK: - Run

    @discardableResult
    override func runContainer(options: RunOptions, onLog: (@MainActor (String) -> Void)? = nil) async throws -> String {
        try await runContainerImpl(options: options, onLog: onLog)
    }

    // MARK: - Machines

    override func createMachine(options: MachineCreateOptions, onLog: (@MainActor (String) -> Void)? = nil) async throws {
        try await createMachineImpl(options: options, onLog: onLog)
    }

    // MARK: - Images

    override func pullImage(reference: String, platform: String? = nil, insecure: Bool = false,
                            progress: ProgressUpdateHandler? = nil, onUnpacking: (() -> Void)? = nil) async throws {
        try await pullImageImpl(reference: reference, platform: platform, insecure: insecure, progress: progress, onUnpacking: onUnpacking)
    }

    override func isKnownInsecureRegistry(forReference reference: String) -> Bool {
        isKnownInsecureRegistryImpl(forReference: reference)
    }

    override func checkForImageUpdates(force: Bool = false) async {
        await checkForImageUpdatesImpl(force: force)
    }

    override func recreateContainer(_ id: String, pullFirst: Bool, progress: ProgressUpdateHandler? = nil,
                                    onPhase: @MainActor @escaping (RecreatePhase) -> Void) async throws -> RecreateResult {
        try await recreateContainerImpl(id, pullFirst: pullFirst, progress: progress, onPhase: onPhase)
    }

    override func reclaimOrphanedImageBlobs() async throws -> UInt64 {
        try await reclaimOrphanedImageBlobsImpl()
    }

    override func pushImage(reference: String, destination: String? = nil, platform: String? = nil,
                            insecure: Bool = false, progress: ProgressUpdateHandler? = nil) async throws {
        try await pushImageImpl(reference: reference, destination: destination, platform: platform, insecure: insecure, progress: progress)
    }

    override func tagImage(reference: String, newReference: String) async throws -> String {
        try await tagImageImpl(reference: reference, newReference: newReference)
    }

    override func saveImages(references: [String], to path: String, platform: String? = nil) async throws {
        try await saveImagesImpl(references: references, to: path, platform: platform)
    }

    override func loadImages(from path: String, force: Bool = false, progress: ProgressUpdateHandler? = nil) async throws -> ImageLoadSummary {
        try await loadImagesImpl(from: path, force: force, progress: progress)
    }
}
