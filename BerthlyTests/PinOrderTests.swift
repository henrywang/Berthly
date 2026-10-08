// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

private struct Item: Identifiable { let id: String }

private func items(_ ids: String...) -> [Item] { ids.map(Item.init) }

struct PinOrderTests {

    @Test func sortedFollowsTheOrderAndPutsUnorderedIdsLast() {
        let result = PinOrder.sorted(items("a", "b", "c", "d"), by: ["c", "a"])
        #expect(result.map(\.id) == ["c", "a", "b", "d"])
    }

    @Test func sortedIgnoresOrderEntriesThatAreNotPresent() {
        let result = PinOrder.sorted(items("a", "b"), by: ["gone", "b", "a"])
        #expect(result.map(\.id) == ["b", "a"])
    }

    @Test func sortedWithEmptyOrderKeepsServiceOrder() {
        #expect(PinOrder.sorted(items("b", "a", "c"), by: []).map(\.id) == ["b", "a", "c"])
    }

    @Test func movedPlacesSourceBeforeTarget() {
        let result = PinOrder.moved(visible: ["a", "b", "c"], sources: ["c"], before: "a", remembered: [])
        #expect(result == ["c", "a", "b"])
    }

    @Test func movedToEndWhenNoTarget() {
        let result = PinOrder.moved(visible: ["a", "b", "c"], sources: ["a"], before: nil, remembered: [])
        #expect(result == ["b", "c", "a"])
    }

    @Test func movedBeforeSelfOrUnknownTargetDoesNotLoseItems() {
        #expect(PinOrder.moved(visible: ["a", "b", "c"], sources: ["b"], before: "b", remembered: []) == ["a", "c", "b"])
        #expect(PinOrder.moved(visible: ["a", "b"], sources: ["a"], before: "zzz", remembered: []) == ["b", "a"])
    }

    @Test func movedKeepsMultipleSourcesInTheirVisibleOrder() {
        let result = PinOrder.moved(visible: ["a", "b", "c", "d"], sources: ["d", "b"], before: "a", remembered: [])
        #expect(result == ["b", "d", "a", "c"])
    }

    @Test func movedRemembersIdsNotCurrentlyVisible() {
        let result = PinOrder.moved(visible: ["a", "b"], sources: ["b"], before: "a", remembered: ["x", "a", "b"])
        #expect(result == ["b", "a", "x"])
    }
}

@MainActor
struct PinOrderServiceTests {

    @Test func pinningAppendsAndUnpinningRemovesFromTheOrder() {
        let service = MockContainerService()
        service.pinnedContainerIDs = []
        service.pinnedContainerOrder = []
        service.togglePinContainer("a")
        service.togglePinContainer("b")
        #expect(service.pinnedContainerOrder == ["a", "b"])
        service.togglePinContainer("a")
        #expect(service.pinnedContainerOrder == ["b"])
        #expect(!service.pinnedContainerIDs.contains("a"))
    }

    @Test func movePinnedContainersReordersTheRenderedList() {
        let service = MockContainerService()
        let ids = Array(service.containers.prefix(3).map(\.id))
        service.pinnedContainerIDs = Set(ids)
        service.pinnedContainerOrder = ids

        service.movePinnedContainers(visible: service.pinnedContainers.map(\.id), sources: [ids[2]], before: ids[0])

        #expect(service.pinnedContainers.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func movePinnedMachinesReordersTheRenderedList() {
        let service = MockContainerService()
        let ids = service.machines.filter { !$0.isUtility }.prefix(2).map(\.id)
        #expect(ids.count == 2)
        service.pinnedMachineIDs = Set(ids)
        service.pinnedMachineOrder = ids

        service.movePinnedMachines(visible: service.pinnedMachines.map(\.id), sources: [ids[0]], before: nil)

        #expect(service.pinnedMachines.map(\.id) == [ids[1], ids[0]])
    }

    @Test func pinnedItemsFromBeforeReorderingStillDecode() throws {
        let old = Data(#"{"containers":["a"],"machines":["m"]}"#.utf8)
        let items = try JSONDecoder().decode(PinnedItems.self, from: old)
        #expect(items.containers == ["a"])
        #expect(items.containerOrder == nil)
    }

    @Test func pinnedItemsRoundTripTheOrder() throws {
        let original = PinnedItems(containers: ["a", "b"], machines: [], containerOrder: ["b", "a"], machineOrder: [])
        let decoded = try JSONDecoder().decode(PinnedItems.self, from: JSONEncoder().encode(original))
        #expect(decoded.containerOrder == ["b", "a"])
    }
}
