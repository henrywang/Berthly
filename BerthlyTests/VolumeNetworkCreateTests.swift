// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerResource
import Testing
@testable import Berthly

struct VolumeCreateMappingTests {

    @Test func sizePassedThroughAsDriverOption() {
        let opts = VolumeCreateOptions(name: "data", size: "10G")
        #expect(LiveContainerService.volumeDriverOpts(for: opts) == ["size": "10G"])
    }

    @Test func blankOrNilSizeProducesNoDriverOptions() {
        #expect(LiveContainerService.volumeDriverOpts(for: VolumeCreateOptions(name: "data", size: nil)).isEmpty)
        #expect(LiveContainerService.volumeDriverOpts(for: VolumeCreateOptions(name: "data", size: "   ")).isEmpty)
    }

    @Test func sizeIsTrimmed() {
        let opts = VolumeCreateOptions(name: "data", size: "  512M  ")
        #expect(LiveContainerService.volumeDriverOpts(for: opts) == ["size": "512M"])
    }
}

struct NetworkCreateMappingTests {

    @Test func hostOnlyMapsToHostOnlyMode() {
        #expect(LiveContainerService.networkMode(hostOnly: true) == .hostOnly)
    }

    @Test func defaultMapsToNatMode() {
        #expect(LiveContainerService.networkMode(hostOnly: false) == .nat)
    }
}

@MainActor
struct VolumeNetworkMockTests {

    @Test func createVolumeAppendsNamedVolume() async throws {
        let mock = MockContainerService()
        let before = mock.volumes.count
        try await mock.createVolume(options: VolumeCreateOptions(name: "data", size: "10G"))
        #expect(mock.volumes.count == before + 1)
        #expect(mock.volumes.first { $0.name == "data" }?.type == .named)
    }

    @Test func createVolumeRejectsBlankName() async {
        let mock = MockContainerService()
        await #expect(throws: (any Error).self) {
            try await mock.createVolume(options: VolumeCreateOptions(name: "  ", size: nil))
        }
    }

    @Test func createNetworkAppendsWithSelectedMode() async throws {
        let mock = MockContainerService()
        try await mock.createNetwork(options: NetworkCreateOptions(name: "isolated", hostOnly: true, subnet: nil))
        #expect(mock.networks.first { $0.name == "isolated" }?.driver == .hostOnly)
    }

    @Test func createNetworkRejectsBlankName() async {
        let mock = MockContainerService()
        await #expect(throws: (any Error).self) {
            try await mock.createNetwork(options: NetworkCreateOptions(name: "", hostOnly: false, subnet: nil))
        }
    }
}
