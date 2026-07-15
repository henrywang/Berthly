// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import ContainerPersistence
import Containerization
import Foundation
import Testing
@testable import Berthly

struct SystemPropertyMappingTests {

    @Test func mapsEveryConfigSectionWithResolvedDefaults() {
        // A default-initialized config resolves every property to its documented default —
        // the mapping must surface all of them (the CLI's property list shows defaults too).
        let properties = LiveContainerService.mapSystemProperties(ContainerSystemConfig())
        let byKey = Dictionary(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })

        #expect(byKey["build.rosetta"] == "true")
        #expect(byKey["build.cpus"] == "2")
        #expect(byKey["container.cpus"] == "4")
        #expect(byKey["registry.domain"] == "docker.io")
        #expect(byKey["machine.home-mount"] == "rw")
        #expect(byKey["machine.virtualization"] == "false")
        // Unset optionals render as an em dash instead of disappearing.
        #expect(byKey["dns.domain"] == "–")
        #expect(byKey["network.subnet"] == "–")
        #expect(byKey["kernel.url"]?.hasPrefix("https://") == true)
    }

    @Test func rendersConfiguredOptionalsVerbatim() {
        let config = ContainerSystemConfig(dns: DNSConfig(domain: "test"))
        let properties = LiveContainerService.mapSystemProperties(config)
        #expect(properties.first(where: { $0.key == "dns.domain" })?.value == "test")
    }

    @Test func keyOrderFollowsTheTOMLSectionOrder() {
        // Stable, CLI-matching order — the view renders rows in array order.
        let keys = LiveContainerService.mapSystemProperties(ContainerSystemConfig()).map(\.key)
        #expect(keys.first == "build.rosetta")
        #expect(keys.last == "vminit.image")
        #expect(keys.count == Set(keys).count)  // no duplicate keys
    }
}

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

    @Test func kernelNameIsBinaryFilename() {
        let kernel = Kernel(path: URL(fileURLWithPath: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186"), platform: .linuxArm)
        #expect(LiveContainerService.kernelName(kernel) == "vmlinux-6.18.15-186")
    }

    @Test func kernelNameIsDashWhenNoKernel() {
        #expect(LiveContainerService.kernelName(nil) == "–")
    }
}

struct SystemConfigMappingTests {

    @Test func extractsHighlightedFields() {
        let config = ContainerSystemConfig()
        let info = LiveContainerService.mapSystemConfig(config)

        #expect(info.vminitImage == config.vminit.image)
        #expect(info.kernelBinaryPath == config.kernel.binaryPath)
        #expect(info.kernelURL == config.kernel.url.absoluteString)
        #expect(info.builderImage == config.build.image)
    }
}

struct DaemonLogEventFormattingTests {

    @Test func joinsTimeLevelAndMessageWithTabs() {
        let ndjson = """
            {"timestamp":"2026-07-05 03:36:02.423830-0400","messageType":"Error","eventMessage":"xpc client handler connection error [error=Connection invalid]"}
            """
        let formatted = LiveContainerService.formatDaemonLogEvent(ndjson)

        #expect(formatted == "03:36:02.423\tError\txpc client handler connection error [error=Connection invalid]")
    }

    @Test func trimsDateMicrosecondsAndTimezoneFromTimestamp() {
        let ndjson = """
            {"timestamp":"2026-07-05 12:00:00.000001-0700","messageType":"Info","eventMessage":"listening"}
            """
        let formatted = LiveContainerService.formatDaemonLogEvent(ndjson)

        #expect(formatted?.hasPrefix("12:00:00.000\t") == true)
    }

    @Test func returnsNilForNonJSONLines() {
        #expect(LiveContainerService.formatDaemonLogEvent("Filtering the log data using \"subsystem == ...\"") == nil)
    }
}
