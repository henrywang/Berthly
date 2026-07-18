// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

private func makeContainer(id: String = "c1", name: String = "web", status: ContainerStatus) -> Container {
    Container(id: id, name: name, image: "local/web:1.4", status: status, ports: [],
              cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "–",
              uptime: "–", command: "", mounts: [], networks: [], environment: [])
}

private func makeMachine(id: String = "m1", name: String = "vm", status: ContainerStatus) -> Machine {
    Machine(id: id, name: name, image: "vm-image", status: status, isUtility: false,
            diskUsedGB: 0, diskTotalGB: 0, uptimeString: "–", kernel: "–", resources: "–",
            created: "–", homeMount: .none)
}

// MARK: - pinnedStatusChanges

struct PinnedStatusChangesTests {

    @Test func noEntryWhenStatusUnchanged() {
        let old = makeContainer(status: .running)
        let new = makeContainer(status: .running)
        let changes = pinnedStatusChanges(
            oldContainers: [old], newContainers: [new], oldMachines: [], newMachines: [],
            pinnedContainerIDs: ["c1"], pinnedMachineIDs: []
        )
        #expect(changes.isEmpty)
    }

    @Test func emitsEntryForPinnedContainerTransition() {
        let old = makeContainer(status: .running)
        let new = makeContainer(status: .error)
        let changes = pinnedStatusChanges(
            oldContainers: [old], newContainers: [new], oldMachines: [], newMachines: [],
            pinnedContainerIDs: ["c1"], pinnedMachineIDs: []
        )
        #expect(changes.count == 1)
        #expect(changes[0].kind == .container)
        #expect(changes[0].id == "c1")
        #expect(changes[0].oldStatus == .running)
        #expect(changes[0].newStatus == .error)
    }

    @Test func emitsEntryForPinnedMachineTransition() {
        let old = makeMachine(status: .stopped)
        let new = makeMachine(status: .running)
        let changes = pinnedStatusChanges(
            oldContainers: [], newContainers: [], oldMachines: [old], newMachines: [new],
            pinnedContainerIDs: [], pinnedMachineIDs: ["m1"]
        )
        #expect(changes.count == 1)
        #expect(changes[0].kind == .machine)
        #expect(changes[0].oldStatus == .stopped)
        #expect(changes[0].newStatus == .running)
    }

    @Test func ignoresUnpinnedIds() {
        let old = makeContainer(status: .running)
        let new = makeContainer(status: .error)
        let changes = pinnedStatusChanges(
            oldContainers: [old], newContainers: [new], oldMachines: [], newMachines: [],
            pinnedContainerIDs: [], pinnedMachineIDs: []
        )
        #expect(changes.isEmpty)
    }

    @Test func ignoresIdMissingFromOldSnapshot() {
        // Covers both "freshly pinned" and "reappeared after a transient fetch failure".
        let new = makeContainer(status: .running)
        let changes = pinnedStatusChanges(
            oldContainers: [], newContainers: [new], oldMachines: [], newMachines: [],
            pinnedContainerIDs: ["c1"], pinnedMachineIDs: []
        )
        #expect(changes.isEmpty)
    }

    @Test func ignoresIdMissingFromNewSnapshot() {
        let old = makeContainer(status: .running)
        let changes = pinnedStatusChanges(
            oldContainers: [old], newContainers: [], oldMachines: [], newMachines: [],
            pinnedContainerIDs: ["c1"], pinnedMachineIDs: []
        )
        #expect(changes.isEmpty)
    }
}

// MARK: - pinnedStatusChangeText

struct PinnedStatusChangeTextTests {

    @Test func containerTransitionsProduceExpectedText() {
        let cases: [(ContainerStatus, String, String)] = [
            (.running, "Container Started", "web is now running."),
            (.stopped, "Container Stopped", "web has stopped."),
            (.error, "Container Error", "web is in an error state."),
            (.paused, "Container Paused", "web has been paused.")
        ]
        for (newStatus, title, body) in cases {
            let change = PinnedStatusChange(
                kind: .container, id: "c1", name: "web", oldStatus: .running, newStatus: newStatus
            )
            let text = pinnedStatusChangeText(change)
            #expect(text.title == title)
            #expect(text.body == body)
        }
    }

    @Test func machineTransitionsUseMachineLabel() {
        let change = PinnedStatusChange(
            kind: .machine, id: "m1", name: "vm", oldStatus: .running, newStatus: .stopped
        )
        let text = pinnedStatusChangeText(change)
        #expect(text.title == "Machine Stopped")
        #expect(text.body == "vm has stopped.")
    }
}
