// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppIntents
import CoreSpotlight
import Observation

/// What changed between two index snapshots, keyed by entity id. A snapshot maps id to a
/// fingerprint of everything the index shows, so an unchanged poll costs nothing.
nonisolated struct IndexDiff: Equatable {
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

        let containerSnapshotNow = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, Self.fingerprint($0)) })
        let containerDiff = IndexDiff(previous: containerSnapshot, current: containerSnapshotNow)
        if !containerDiff.isEmpty {
            try? await index.indexAppEntities(containers.filter { containerDiff.upserts.contains($0.id) })
            try? await index.deleteAppEntities(identifiedBy: containerDiff.removals, ofType: ContainerEntity.self)
            containerSnapshot = containerSnapshotNow
        }

        let machineSnapshotNow = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, Self.fingerprint($0)) })
        let machineDiff = IndexDiff(previous: machineSnapshot, current: machineSnapshotNow)
        if !machineDiff.isEmpty {
            try? await index.indexAppEntities(machines.filter { machineDiff.upserts.contains($0.id) })
            try? await index.deleteAppEntities(identifiedBy: machineDiff.removals, ofType: MachineEntity.self)
            machineSnapshot = machineSnapshotNow
        }
    }

    nonisolated static func fingerprint(_ entity: ContainerEntity) -> String {
        "\(entity.name)|\(entity.image)|\(entity.status)"
    }

    nonisolated static func fingerprint(_ entity: MachineEntity) -> String {
        "\(entity.name)|\(entity.image)|\(entity.status)"
    }
}
