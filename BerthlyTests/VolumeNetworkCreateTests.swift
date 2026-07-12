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

/// Bounds verified against a live daemon: min 1 MiB, max just under 16 TiB, binary suffixes.
struct VolumeSizeValidationTests {

    @Test func blankIsValid() {  // means "use the 512 GB default"
        #expect(LiveContainerService.validateVolumeSize("") == nil)
        #expect(LiveContainerService.validateVolumeSize("   ") == nil)
    }

    @Test func acceptsSizesWithinBounds() {
        #expect(LiveContainerService.validateVolumeSize("1M") == nil)
        #expect(LiveContainerService.validateVolumeSize("10G") == nil)
        #expect(LiveContainerService.validateVolumeSize("8T") == nil)
    }

    @Test func rejectsBelowOneMiB() {
        #expect(LiveContainerService.validateVolumeSize("512K") != nil)
        #expect(LiveContainerService.validateVolumeSize("1048575") != nil)  // 1 byte under 1 MiB
    }

    @Test func acceptsExactlyOneMiB() {
        #expect(LiveContainerService.validateVolumeSize("1048576") == nil)
        #expect(LiveContainerService.validateVolumeSize("1M") == nil)
    }

    @Test func rejectsSixteenTiBAndUp() {
        #expect(LiveContainerService.validateVolumeSize("16T") != nil)
        #expect(LiveContainerService.validateVolumeSize("100T") != nil)
    }

    @Test func rejectsMalformed() {
        #expect(LiveContainerService.validateVolumeSize("abc") != nil)
        #expect(LiveContainerService.validateVolumeSize("10X") != nil)
        #expect(LiveContainerService.validateVolumeSize("G") != nil)
        #expect(LiveContainerService.validateVolumeSize("-5G") != nil)
    }

    @Test func parsesBinarySuffixes() {
        #expect(LiveContainerService.parseVolumeSizeBytes("1K") == 1_024)
        #expect(LiveContainerService.parseVolumeSizeBytes("1M") == 1_048_576)
        #expect(LiveContainerService.parseVolumeSizeBytes("2G") == 2_147_483_648)
        #expect(LiveContainerService.parseVolumeSizeBytes("512") == 512)
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
