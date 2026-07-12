// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

@MainActor
struct VolumeMountResolverTests {

    private func makeContainer(name: String, status: ContainerStatus = .running,
                               mounts: [ContainerMount]) -> Container {
        Container(id: name, name: name, image: "img", status: status, ports: [],
                  cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "–",
                  uptime: "–", command: "", mounts: mounts, networks: [], environment: [])
    }

    private func makeVolume(name: String) -> Volume {
        Volume(id: name, name: name, type: .named, usedMB: 10, allocatedMB: 100,
               driver: "local", source: "/volumes/\(name)/volume.img", created: "Jun 12",
               labels: ["k=v"], options: ["size=1G"], mounts: [], fs: "ext4", reclaimable: true)
    }

    @Test func attachesMountsFromMatchingContainers() {
        let resolved = Volume.resolvingMounts(
            [makeVolume(name: "data")],
            containers: [makeContainer(name: "db", mounts: [
                ContainerMount(source: "/volumes/data/volume.img", destination: "/var/lib/db",
                               volumeName: "data", isReadOnly: false)
            ])]
        )
        #expect(resolved[0].mounts == [VolumeMount(containerName: "db", mountPath: "/var/lib/db", mode: "RW")])
        #expect(!resolved[0].reclaimable)
    }

    @Test func readOnlyMountMapsToROMode() {
        let resolved = Volume.resolvingMounts(
            [makeVolume(name: "assets")],
            containers: [makeContainer(name: "web", mounts: [
                ContainerMount(source: "x", destination: "/app/public",
                               volumeName: "assets", isReadOnly: true)
            ])]
        )
        #expect(resolved[0].mounts.first?.mode == "RO")
    }

    @Test func bindMountsWithoutVolumeNameAreIgnored() {
        let resolved = Volume.resolvingMounts(
            [makeVolume(name: "data")],
            containers: [makeContainer(name: "web", mounts: [
                ContainerMount(source: "./src", destination: "/app")  // bind mount: volumeName nil
            ])]
        )
        #expect(resolved[0].mounts.isEmpty)
        #expect(resolved[0].reclaimable)
    }

    @Test func mountsOfOtherVolumesAreIgnored() {
        let resolved = Volume.resolvingMounts(
            [makeVolume(name: "data")],
            containers: [makeContainer(name: "web", mounts: [
                ContainerMount(source: "x", destination: "/other", volumeName: "other-volume")
            ])]
        )
        #expect(resolved[0].mounts.isEmpty)
    }

    @Test func multipleContainersProduceOneMountEach() {
        let resolved = Volume.resolvingMounts(
            [makeVolume(name: "shared")],
            containers: [
                makeContainer(name: "web", mounts: [
                    ContainerMount(source: "x", destination: "/app/public", volumeName: "shared", isReadOnly: true)
                ]),
                makeContainer(name: "api", mounts: [
                    ContainerMount(source: "x", destination: "/srv/assets", volumeName: "shared", isReadOnly: true)
                ]),
            ]
        )
        #expect(resolved[0].mounts.map(\.containerName) == ["web", "api"])
        #expect(!resolved[0].reclaimable)
    }

    @Test func unmountedVolumeBecomesReclaimable() {
        let resolved = Volume.resolvingMounts([makeVolume(name: "cache")], containers: [])
        #expect(resolved[0].mounts.isEmpty)
        #expect(resolved[0].reclaimable)
    }

    @Test func preservesAllOtherVolumeFields() {
        let resolved = Volume.resolvingMounts([makeVolume(name: "data")], containers: [])[0]
        let original = makeVolume(name: "data")
        #expect(resolved.name == original.name)
        #expect(resolved.type == original.type)
        #expect(resolved.usedMB == original.usedMB)
        #expect(resolved.allocatedMB == original.allocatedMB)
        #expect(resolved.driver == original.driver)
        #expect(resolved.source == original.source)
        #expect(resolved.created == original.created)
        #expect(resolved.labels == original.labels)
        #expect(resolved.options == original.options)
        #expect(resolved.fs == original.fs)
    }
}

struct VolumeFootprintTests {

    /// A volume's footprint counts only the on-disk blocks actually written, not the sparse
    /// image's much larger apparent size — the same shape as a real `volume.img`.
    @Test func footprintReflectsOnDiskBlocksNotApparentSize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("berthly-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let img = dir.appendingPathComponent("volume.img")
        FileManager.default.createFile(atPath: img.path, contents: nil)
        let handle = try FileHandle(forWritingTo: img)
        // 2 MB of incompressible data at the front, then a hole out to 64 MB apparent size.
        var bytes = [UInt8](repeating: 0, count: 2 * 1_048_576)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        try handle.write(contentsOf: Data(bytes))
        try handle.truncate(atOffset: 64 * 1_048_576)
        try handle.close()

        let footprint = try #require(LiveContainerService.volumeFootprintMB(imagePath: img.path))
        #expect(footprint >= 1)
        #expect(footprint < 64)  // far below the 64 MB apparent size — the hole isn't counted
    }

    @Test func missingFileReturnsNil() {
        #expect(LiveContainerService.volumeFootprintMB(imagePath: "/nonexistent/volume.img") == nil)
    }
}

struct VolumeUsedMBTests {

    /// A `--size 2M` volume sits in a 128 MB image whose ext4 overhead alone (~2 MB) can
    /// exceed the nominal size; capping keeps the bar from reading past 100%.
    @Test func cappedAtConfiguredCapacityForTinyVolume() {
        #expect(LiveContainerService.volumeUsedMB(footprintMB: 3, configuredMB: 2) == 2)
    }

    /// The common case — a 512 GB default volume with 66 MB written shows the real footprint.
    @Test func rawFootprintWhenBelowCapacity() {
        #expect(LiveContainerService.volumeUsedMB(footprintMB: 66, configuredMB: 524_288) == 66)
    }

    /// Unknown capacity (no `sizeInBytes`) shows the footprint as-is rather than hiding it.
    @Test func rawFootprintWhenCapacityUnknown() {
        #expect(LiveContainerService.volumeUsedMB(footprintMB: 5, configuredMB: 0) == 5)
    }
}

struct VolumeConfiguredCapacityTests {

    private func volume(allocatedMB: Int) -> Volume {
        Volume(id: "v", name: "v", type: .named, usedMB: 10, allocatedMB: allocatedMB,
               driver: "local", source: "", created: "", labels: [], mounts: [], fs: "ext4",
               reclaimable: true)
    }

    /// A user-chosen size gauges usage meaningfully.
    @Test func explicitSizeHasConfiguredCapacity() {
        #expect(volume(allocatedMB: 1024).hasConfiguredCapacity)
    }

    /// The 512 GiB sparse default is not a real capacity — no gauge.
    @Test func sparseDefaultHasNoConfiguredCapacity() {
        #expect(!volume(allocatedMB: Volume.defaultSparseCapacityMB).hasConfiguredCapacity)
    }

    /// Unknown capacity (0) is not gaugeable either.
    @Test func unknownCapacityHasNoConfiguredCapacity() {
        #expect(!volume(allocatedMB: 0).hasConfiguredCapacity)
    }
}
