// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import ContainerPersistence
import Containerization
import Foundation
import Testing
@testable import Berthly

struct DiskUsageMappingTests {

    @Test func mapsAllThreeCategories() {
        let stats = DiskUsageStats(
            images: ResourceUsage(total: 12, active: 4, sizeInBytes: 3_400_000_000, reclaimable: 1_100_000_000),
            containers: ResourceUsage(total: 6, active: 2, sizeInBytes: 240_000_000, reclaimable: 0),
            volumes: ResourceUsage(total: 3, active: 1, sizeInBytes: 512_000_000, reclaimable: 90_000_000)
        )
        let summary = LiveContainerService.mapDiskUsage(stats)

        #expect(summary.images.total == 12)
        #expect(summary.images.active == 4)
        #expect(summary.images.sizeBytes == 3_400_000_000)
        #expect(summary.images.reclaimableBytes == 1_100_000_000)

        #expect(summary.containers.reclaimableBytes == 0)
        #expect(summary.volumes.sizeBytes == 512_000_000)
    }
}

struct KernelMappingTests {

    @Test func mapsPathAndPlatform() {
        let kernel = Kernel(path: URL(fileURLWithPath: "/opt/kata/vmlinux"), platform: .linuxArm)
        let info = LiveContainerService.mapKernelInfo(kernel)

        #expect(info.path == "/opt/kata/vmlinux")
        #expect(info.platform == "linux/arm64")
    }
}

struct SystemConfigMappingTests {

    @Test func extractsHighlightedFieldsAndEncodesRawJSON() throws {
        let config = ContainerSystemConfig()
        let info = try LiveContainerService.mapSystemConfig(config)

        #expect(info.vminitImage == config.vminit.image)
        #expect(info.kernelBinaryPath == config.kernel.binaryPath)
        #expect(info.kernelURL == config.kernel.url.absoluteString)
        #expect(info.builderImage == config.build.image)
        #expect(info.rawJSON.contains(config.vminit.image))
    }
}
