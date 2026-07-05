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

    @Test func totalSizeSumsAllThreeCategories() {
        let summary = DiskUsageSummary(
            images: .init(total: 1, active: 1, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
            containers: .init(total: 1, active: 1, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
            volumes: .init(total: 1, active: 1, sizeBytes: 512_000_000, reclaimableBytes: 500_000_000)
        )
        #expect(summary.totalSizeBytes == 3_400_000_000 + 240_000_000 + 512_000_000)
    }

    @Test func cleanableReclaimableExcludesVolumes() {
        let summary = DiskUsageSummary(
            images: .init(total: 1, active: 1, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
            containers: .init(total: 1, active: 1, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
            volumes: .init(total: 1, active: 1, sizeBytes: 512_000_000, reclaimableBytes: 500_000_000)
        )
        // Volumes' 500 MB reclaimable is deliberately excluded — "Clean Up All" never deletes volumes.
        #expect(summary.cleanableReclaimableBytes == 1_100_000_000 + 90_000_000)
    }

    @Test func reclaimablePercentRoundsToNearestWhole() {
        let category = DiskUsageSummary.Category(total: 1, active: 0, sizeBytes: 1_000_000, reclaimableBytes: 333_333)
        #expect(category.reclaimablePercent == 33)
    }

    @Test func reclaimablePercentIsZeroForEmptyCategory() {
        let category = DiskUsageSummary.Category(total: 0, active: 0, sizeBytes: 0, reclaimableBytes: 0)
        #expect(category.reclaimablePercent == 0)
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
