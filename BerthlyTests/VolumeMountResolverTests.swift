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

struct VolumeDiskUsageTests {

    /// A sparse file reports its logical size as the allocation and only the written blocks
    /// as usage — the same shape as a volume's backing `volume.img`.
    @Test func sparseFileReportsLogicalAndOnDiskSizes() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("berthly-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let img = dir.appendingPathComponent("volume.img")
        FileManager.default.createFile(atPath: img.path, contents: nil)
        let handle = try FileHandle(forWritingTo: img)
        // 2 MB of incompressible data at the front, then a hole out to 64 MB.
        var bytes = [UInt8](repeating: 0, count: 2 * 1_048_576)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        try handle.write(contentsOf: Data(bytes))
        try handle.truncate(atOffset: 64 * 1_048_576)
        try handle.close()

        let usage = try #require(LiveContainerService.volumeDiskUsage(imagePath: img.path))
        #expect(usage.allocatedMB == 64)
        #expect(usage.usedMB >= 1)
        #expect(usage.usedMB < 64)
    }

    @Test func missingFileReturnsNil() {
        #expect(LiveContainerService.volumeDiskUsage(imagePath: "/nonexistent/volume.img") == nil)
    }
}
