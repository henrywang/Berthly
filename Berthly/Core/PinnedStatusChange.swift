// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

nonisolated enum PinnedResourceKind: Equatable {
    case container, machine
}

/// A pinned container/machine's status at time T differing from time T-1 poll.
nonisolated struct PinnedStatusChange: Equatable {
    let kind: PinnedResourceKind
    let id: String
    let name: String
    let oldStatus: ContainerStatus
    let newStatus: ContainerStatus
}

/// Diffs a poll's before/after snapshots for pinned containers/machines only, matching
/// by id. An id missing from either snapshot (not yet fetched, freshly pinned, removed,
/// or a transient fetch failure that reset the list to `[]`) is skipped rather than
/// treated as a transition — there's no real "old" or "new" status to compare in that
/// case, and skipping means a fetch blip can't manufacture a false notification.
nonisolated func pinnedStatusChanges(
    oldContainers: [Container], newContainers: [Container],
    oldMachines: [Machine], newMachines: [Machine],
    pinnedContainerIDs: Set<String>, pinnedMachineIDs: Set<String>
) -> [PinnedStatusChange] {
    var result: [PinnedStatusChange] = []

    let oldContainerByID = Dictionary(uniqueKeysWithValues: oldContainers.map { ($0.id, $0) })
    for new in newContainers where pinnedContainerIDs.contains(new.id) {
        guard let old = oldContainerByID[new.id], old.status != new.status else { continue }
        result.append(
            PinnedStatusChange(kind: .container, id: new.id, name: new.name, oldStatus: old.status, newStatus: new.status)
        )
    }

    let oldMachineByID = Dictionary(uniqueKeysWithValues: oldMachines.map { ($0.id, $0) })
    for new in newMachines where pinnedMachineIDs.contains(new.id) {
        guard let old = oldMachineByID[new.id], old.status != new.status else { continue }
        result.append(
            PinnedStatusChange(kind: .machine, id: new.id, name: new.name, oldStatus: old.status, newStatus: new.status)
        )
    }

    return result
}

nonisolated func pinnedStatusChangeText(_ change: PinnedStatusChange) -> (title: String, body: String) {
    let kindLabel = change.kind == .container ? "Container" : "Machine"
    switch change.newStatus {
    case .running:
        return ("\(kindLabel) Started", "\(change.name) is now running.")
    case .stopped:
        return ("\(kindLabel) Stopped", "\(change.name) has stopped.")
    case .error:
        return ("\(kindLabel) Error", "\(change.name) is in an error state.")
    case .paused:
        return ("\(kindLabel) Paused", "\(change.name) has been paused.")
    }
}
