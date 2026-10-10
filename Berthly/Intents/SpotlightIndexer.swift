// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppIntents
import CoreSpotlight
import Observation

/// What changed between two index snapshots, keyed by entity id. A snapshot maps id to a
/// fingerprint of everything the index shows, so an unchanged poll costs nothing.
nonisolated struct IndexDiff {
    var upserts: [String]
    var removals: [String]

    init(previous: [String: String], current: [String: String]) {
        upserts = current.filter { previous[$0.key] != $0.value }.keys.sorted()
        removals = previous.keys.filter { current[$0] == nil }.sorted()
    }

    var isEmpty: Bool { upserts.isEmpty && removals.isEmpty }
}

/// Keeps containers and machines in Spotlight's index in step with the service. Entities are
/// indexed through App Intents (`IndexedEntity`, macOS 15+), so the same code serves macOS 26
/// and 27; the macOS 27 `IndexedEntityQuery` reindex callback is not adopted because this
/// indexer already re-sends everything on launch.
@MainActor
final class SpotlightIndexer {
    private var containerSnapshot: [String: String] = [:]
    private var machineSnapshot: [String: String] = [:]
    private var hasSyncedSinceLaunch = false
    private var task: Task<Void, Never>?

    /// No indexing under tests: UI and unit test hosts must not write mock or real container
    /// names into the developer's system-wide Spotlight index.
    nonisolated static func shouldRun(environment: [String: String]) -> Bool {
        UpdaterService.shouldStartUpdater(environment: environment)
    }

    func start(service: ContainerServiceBase) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sync(service)
                await Self.nextChange(of: service)
            }
        }
    }

    /// `onChange` fires before the new value lands, but resuming only schedules this task's
    /// continuation, so it runs after the mutating turn has finished and sees the new state.
    private static func nextChange(of service: ContainerServiceBase) async {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = service.containers
                _ = service.machines
                _ = service.isConnected
            } onChange: {
                continuation.resume()
            }
        }
    }

    private func sync(_ service: ContainerServiceBase) async {
        // Before the first poll lands the lists are empty, and diffing that against a previous
        // launch's index would wipe it for nothing.
        guard service.isConnected else { return }
        let containers = ComputeEntityCatalog.containers(in: service)
        let machines = ComputeEntityCatalog.machines(in: service)
        let index = CSSearchableIndex.default()

        if !hasSyncedSinceLaunch {
            // Drops entries for items deleted while Berthly was not running.
            try? await index.deleteAppEntities(ofType: ContainerEntity.self)
            try? await index.deleteAppEntities(ofType: MachineEntity.self)
            containerSnapshot = [:]
            machineSnapshot = [:]
            hasSyncedSinceLaunch = true
        }

        containerSnapshot = await Self.sync(
            containers, previous: containerSnapshot, index: index,
            fingerprint: { Self.fingerprint(name: $0.name, image: $0.image, status: $0.status) })
        machineSnapshot = await Self.sync(
            machines, previous: machineSnapshot, index: index,
            fingerprint: { Self.fingerprint(name: $0.name, image: $0.image, status: $0.status) })
    }

    /// Returns the snapshot to keep: the new one after sending a change, the old one when nothing
    /// changed. Duplicate ids keep the first entry instead of trapping.
    private static func sync<Entity: IndexedEntity>(
        _ entities: [Entity], previous: [String: String], index: CSSearchableIndex,
        fingerprint: (Entity) -> String
    ) async -> [String: String] where Entity.ID == String {
        let current = Dictionary(entities.map { ($0.id, fingerprint($0)) }, uniquingKeysWith: { first, _ in first })
        let diff = IndexDiff(previous: previous, current: current)
        guard !diff.isEmpty else { return previous }
        try? await index.indexAppEntities(entities.filter { diff.upserts.contains($0.id) })
        try? await index.deleteAppEntities(identifiedBy: diff.removals, ofType: Entity.self)
        return current
    }

    nonisolated private static func fingerprint(name: String, image: String, status: String) -> String {
        "\(name)|\(image)|\(status)"
    }
}
