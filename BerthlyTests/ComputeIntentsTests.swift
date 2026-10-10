// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

@MainActor
struct ComputeEntityCatalogTests {

    @Test func containersMatchByNameOrImageIgnoringCase() {
        let service = MockContainerService()
        let first = service.containers[0]

        let byName = ComputeEntityCatalog.containers(in: service, matching: first.name.uppercased())
        #expect(byName.contains { $0.id == first.id })

        let byImage = ComputeEntityCatalog.containers(in: service, matching: first.image)
        #expect(byImage.contains { $0.id == first.id })

        #expect(ComputeEntityCatalog.containers(in: service, matching: "no-such-thing-xyz").isEmpty)
    }

    @Test func lookupByIdentifiersReturnsOnlyThoseContainers() {
        let service = MockContainerService()
        let wanted = service.containers[0].id
        let result = ComputeEntityCatalog.containers(in: service, ids: [wanted, "missing"])
        #expect(result.map(\.id) == [wanted])
    }

    @Test func emptySearchTextReturnsEverything() {
        let service = MockContainerService()
        #expect(ComputeEntityCatalog.containers(in: service, matching: "").count == service.containers.count)
    }

    @Test func utilityMachinesAreNeverOffered() {
        let service = MockContainerService()
        let offered = Set(ComputeEntityCatalog.machines(in: service).map(\.id))
        let utility = Set(service.machines.filter(\.isUtility).map(\.id))
        #expect(offered.isDisjoint(with: utility))
        #expect(offered.count == service.machines.filter { !$0.isUtility }.count)
    }

    @Test func entityCarriesTheStatusLabelShownInTheApp() {
        let service = MockContainerService()
        let container = service.containers[0]
        #expect(ContainerEntity(container).status == container.status.label)
    }
}

struct IndexDiffTests {

    @Test func newChangedAndRemovedIdsAreSeparated() {
        let diff = IndexDiff(
            previous: ["a": "1", "b": "1", "c": "1"],
            current: ["b": "1", "c": "2", "d": "1"])
        #expect(diff.upserts == ["c", "d"])
        #expect(diff.removals == ["a"])
    }

    @Test func identicalSnapshotsAreEmpty() {
        #expect(IndexDiff(previous: ["a": "1"], current: ["a": "1"]).isEmpty)
    }

    @Test func indexingIsSkippedUnderTests() {
        #expect(!SpotlightIndexer.shouldRun(environment: ["XCTestConfigurationFilePath": "x"]))
        #expect(!SpotlightIndexer.shouldRun(environment: ["UITEST_USE_MOCK_SERVICE": "1"]))
        #expect(SpotlightIndexer.shouldRun(environment: [:]))
    }
}

@MainActor
struct ComputeIntentActionsTests {

    @Test func startContainerStartsTheContainer() async throws {
        let service = MockContainerService()
        let stopped = try #require(service.containers.first { $0.status == .stopped })
        try await ComputeIntentActions.start(.container(stopped.id), in: service)
        #expect(service.containers.first { $0.id == stopped.id }?.status == .running)
    }

    @Test func stopContainerStopsTheContainer() async throws {
        let service = MockContainerService()
        let running = try #require(service.containers.first { $0.status == .running })
        try await ComputeIntentActions.stop(.container(running.id), in: service)
        #expect(service.containers.first { $0.id == running.id }?.status == .stopped)
    }

    @Test func stopThenStartMachineChangesTheMachine() async throws {
        let service = MockContainerService()
        let machine = try #require(service.machines.first { !$0.isUtility })
        try await ComputeIntentActions.stop(.machine(machine.id), in: service)
        #expect(service.machines.first { $0.id == machine.id }?.status == .stopped)
        try await ComputeIntentActions.start(.machine(machine.id), in: service)
        #expect(service.machines.first { $0.id == machine.id }?.status == .running)
    }

    @Test func openAsksTheMainWindowToSelectTheItem() {
        let bridge = MenuBarBridge()
        ComputeIntentActions.open(.container("c1"), in: bridge)
        #expect(bridge.pendingIntent == .selectCompute(.container("c1")))
        ComputeIntentActions.open(.machine("m1"), in: bridge)
        #expect(bridge.pendingIntent == .selectCompute(.machine("m1")))
    }
}
