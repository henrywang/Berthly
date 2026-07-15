// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

/// The two cleanup selections decide what gets deleted; a bug here destroys user data, so they're
/// the pieces that earn tests. Two properties matter most: an image referenced only by a *stopped*
/// container must survive image cleanup (matching the daemon's reclaimable definition), and a
/// stopped machine/builder must never be swept up by the stopped-container cleanup.
struct PruneSelectionTests {

    // MARK: - Image selection

    @Test func deletesUnusedImagesAndKeepsInUseOnes() {
        let unused = LiveContainerService.unusedImageReferences(
            allImageReferences: ["nginx:latest", "redis:7", "dangling@sha256:abc"],
            containerImageReferences: ["nginx:latest"]
        )
        #expect(unused == ["redis:7", "dangling@sha256:abc"])
        #expect(!unused.contains("nginx:latest"))
    }

    @Test func protectsImageReferencedOnlyByAStoppedContainer() {
        // The caller passes image refs from *every* container, running or stopped — so an image a
        // stopped container still references is treated as in-use and left alone, even though that
        // container may be removed separately. Freed space stays ≤ the advertised reclaimable.
        let unused = LiveContainerService.unusedImageReferences(
            allImageReferences: ["app:1.0", "orphan:1.0"],
            containerImageReferences: ["app:1.0"]  // "app:1.0" is a stopped container's image
        )
        #expect(unused == ["orphan:1.0"])
        #expect(!unused.contains("app:1.0"))
    }

    @Test func protectsMachineAndBuilderImages() {
        // A machine/builder image is referenced by a container too, so it's in the in-use set and
        // never pruned.
        let unused = LiveContainerService.unusedImageReferences(
            allImageReferences: ["vmlinux:machine", "buildkit:0.13", "junk:1.0"],
            containerImageReferences: ["vmlinux:machine", "buildkit:0.13"]
        )
        #expect(unused == ["junk:1.0"])
    }

    @Test func noImagesToDeleteWhenAllInUse() {
        let unused = LiveContainerService.unusedImageReferences(
            allImageReferences: ["a", "b"],
            containerImageReferences: ["a", "b", "c"]
        )
        #expect(unused.isEmpty)
    }

    // MARK: - Stopped-container selection

    @Test func selectsOnlyStoppedNonInfrastructureContainers() {
        let ids = LiveContainerService.deletableStoppedContainerIDs([
            PruneContainerInfo(id: "running", imageReference: "a", isStopped: false, isInfrastructure: false),
            PruneContainerInfo(id: "stopped1", imageReference: "b", isStopped: true, isInfrastructure: false),
            PruneContainerInfo(id: "stopped2", imageReference: "c", isStopped: true, isInfrastructure: false),
        ])
        #expect(ids == ["stopped1", "stopped2"])
    }

    @Test func neverDeletesStoppedInfrastructure() {
        // The data-loss guard: a stopped VM/builder is a stopped container under the hood, but must
        // never be deleted.
        let ids = LiveContainerService.deletableStoppedContainerIDs([
            PruneContainerInfo(id: "vm1", imageReference: "vmlinux:machine", isStopped: true, isInfrastructure: true),
            PruneContainerInfo(id: "builder1", imageReference: "buildkit:0.13", isStopped: true, isInfrastructure: true),
            PruneContainerInfo(id: "job1", imageReference: "workload:1.0", isStopped: true, isInfrastructure: false),
        ])
        #expect(ids == ["job1"])
        #expect(!ids.contains("vm1"))
        #expect(!ids.contains("builder1"))
    }

    @Test func emptyInputsProduceEmptySelections() {
        #expect(LiveContainerService.unusedImageReferences(allImageReferences: [], containerImageReferences: []).isEmpty)
        #expect(LiveContainerService.deletableStoppedContainerIDs([]).isEmpty)
    }

    // MARK: - Volume selection

    @Test func deletesUnmountedVolumesAndKeepsMountedOnes() {
        let unused = LiveContainerService.unusedVolumeNames(
            allVolumeNames: ["pgdata", "model-cache", "scratch"],
            mountedVolumeNames: ["pgdata"]
        )
        #expect(unused == ["model-cache", "scratch"])
        #expect(!unused.contains("pgdata"))
    }

    @Test func protectsVolumeMountedOnlyByAStoppedContainer() {
        // The caller passes mounts from *every* container's configuration, running or stopped —
        // a volume a stopped container still mounts holds data that becomes reachable again on
        // start, so it must survive the cleanup.
        let unused = LiveContainerService.unusedVolumeNames(
            allVolumeNames: ["stopped-data", "orphan"],
            mountedVolumeNames: ["stopped-data"]  // mounted by a stopped container
        )
        #expect(unused == ["orphan"])
    }

    @Test func emptyVolumeInputsProduceEmptySelection() {
        #expect(LiveContainerService.unusedVolumeNames(allVolumeNames: [], mountedVolumeNames: []).isEmpty)
    }

    // MARK: - Network selection

    @Test func deletesOnlyDisconnectedNonBuiltinNetworks() {
        let ids = LiveContainerService.prunableNetworkIDs(
            [
                PruneNetworkInfo(id: "app-net", isBuiltin: false),
                PruneNetworkInfo(id: "old-net", isBuiltin: false),
                PruneNetworkInfo(id: "default", isBuiltin: true),
            ],
            connectedNetworkIDs: ["app-net"]
        )
        #expect(ids == ["old-net"])
    }

    @Test func neverDeletesTheBuiltinNetworkEvenWhenUnused() {
        // The daemon's default network must survive with nothing attached — deleting it breaks
        // every future `container run` that doesn't name a network.
        let ids = LiveContainerService.prunableNetworkIDs(
            [PruneNetworkInfo(id: "default", isBuiltin: true)],
            connectedNetworkIDs: []
        )
        #expect(ids.isEmpty)
    }

    @Test func protectsNetworkReferencedOnlyByAStoppedContainer() {
        // In-use comes from every container's *configuration* (the CLI's rule) — a stopped
        // container's network must still be attachable when that container starts again.
        let ids = LiveContainerService.prunableNetworkIDs(
            [PruneNetworkInfo(id: "stopped-net", isBuiltin: false)],
            connectedNetworkIDs: ["stopped-net"]  // referenced by a stopped container
        )
        #expect(ids.isEmpty)
    }

    // MARK: - machine set kwargs

    @Test func machineSetKwargsIncludesOnlyProvidedFields() {
        let kwargs = LiveContainerService.machineSetKwargs(
            for: MachineUpdateOptions(cpus: 8, memory: "  16G ", homeMount: "ro"))
        #expect(kwargs == ["cpus": "8", "memory": "16G", "home-mount": "ro"])

        let partial = LiveContainerService.machineSetKwargs(
            for: MachineUpdateOptions(cpus: nil, memory: "", homeMount: nil))
        #expect(partial.isEmpty)  // nothing set → live updateMachine skips the daemon round-trip
    }

    // MARK: - Result aggregation

    @Test func resultAggregatesTotalsAndCounts() {
        let r = PruneResult(imagesFreedBytes: 1_100_000_000, deletedImageCount: 8)
        #expect(r.totalFreedBytes == 1_100_000_000)
        #expect(r.deletedCount == 8)

        let c = PruneResult(containersFreedBytes: 90_000_000, deletedContainerCount: 4)
        #expect(c.totalFreedBytes == 90_000_000)
        #expect(c.deletedCount == 4)
    }

    @Test func combiningResultsSumsEveryField() {
        // "Clean Up All" runs pruneImages() and pruneStoppedContainers() as two independent calls
        // and combines the results with `+` — each field must sum, including failures.
        let images = PruneResult(imagesFreedBytes: 1_100_000_000, deletedImageCount: 8, failedCount: 1)
        let containers = PruneResult(containersFreedBytes: 90_000_000, deletedContainerCount: 4)
        let combined = images + containers

        #expect(combined.imagesFreedBytes == 1_100_000_000)
        #expect(combined.containersFreedBytes == 90_000_000)
        #expect(combined.deletedImageCount == 8)
        #expect(combined.deletedContainerCount == 4)
        #expect(combined.failedCount == 1)
        #expect(combined.totalFreedBytes == 1_190_000_000)
        #expect(combined.deletedCount == 12)
    }

    // MARK: - summaryText

    @Test func summaryTextReportsCombinedImagesAndContainers() {
        let r = PruneResult(imagesFreedBytes: 1_100_000_000, containersFreedBytes: 90_000_000,
                             deletedImageCount: 8, deletedContainerCount: 4)
        #expect(r.summaryText == "Reclaimed 1.1 GB — removed 8 images and 4 stopped containers.")
    }

    @Test func summaryTextSingularizesCountOfOne() {
        let r = PruneResult(imagesFreedBytes: 100_000_000, deletedImageCount: 1)
        #expect(r.summaryText == "Reclaimed 95.4 MB — removed 1 image.")
    }

    @Test func summaryTextReportsNothingToRemoveWhenEmpty() {
        #expect(PruneResult().summaryText == "Nothing to remove.")
    }

    @Test func summaryTextReportsFailuresWhenNothingSucceeded() {
        let r = PruneResult(failedCount: 2)
        #expect(r.summaryText == "Couldn't remove anything — 2 operations failed. See the daemon logs for details.")
    }

    @Test func summaryTextAppendsFailureCountAlongsidePartialSuccess() {
        let r = PruneResult(imagesFreedBytes: 100_000_000, deletedImageCount: 1, failedCount: 1)
        #expect(r.summaryText == "Reclaimed 95.4 MB — removed 1 image. 1 couldn't be removed.")
    }

    @Test func summaryTextReportsVolumeCleanup() {
        let r = PruneResult(volumesFreedBytes: 512_000_000, deletedVolumeCount: 2)
        #expect(r.summaryText == "Reclaimed 488.3 MB — removed 2 unused volumes.")
    }

    @Test func summaryTextForNetworksOnlySkipsTheBytesPhrase() {
        // Networks free no disk space — "Reclaimed 0 B" would read like a bug.
        let r = PruneResult(deletedNetworkCount: 3)
        #expect(r.summaryText == "Removed 3 unused networks.")
    }

    @Test func summaryTextListsThreeCategoriesReadably() {
        let r = PruneResult(imagesFreedBytes: 1_048_576, containersFreedBytes: 1_048_576,
                            volumesFreedBytes: 1_048_576, deletedImageCount: 1,
                            deletedContainerCount: 1, deletedVolumeCount: 1)
        #expect(r.summaryText == "Reclaimed 3.0 MB — removed 1 image, 1 stopped container and 1 unused volume.")
    }

    @Test func combiningResultsSumsVolumeAndNetworkFields() {
        let volumes = PruneResult(volumesFreedBytes: 100, deletedVolumeCount: 1)
        let networks = PruneResult(deletedNetworkCount: 2, failedCount: 1)
        let combined = volumes + networks
        #expect(combined.volumesFreedBytes == 100)
        #expect(combined.deletedVolumeCount == 1)
        #expect(combined.deletedNetworkCount == 2)
        #expect(combined.failedCount == 1)
        #expect(combined.deletedCount == 3)
        #expect(combined.totalFreedBytes == 100)
    }

    // Regression: orphaned-blob GC can free real bytes on a run where nothing was freshly
    // untagged (deletedCount == 0) — the guard must not misreport this as "Nothing to remove."
    @Test func summaryTextReportsBytesFreedEvenWhenNothingWasCountedAsDeleted() {
        let r = PruneResult(imagesFreedBytes: 50_000_000)
        #expect(r.deletedCount == 0)
        #expect(r.summaryText == "Reclaimed 47.7 MB of unused disk space.")
    }

    // MARK: - CleanUpAllResult.errorAlertMessage

    @Test func errorAlertMessageIsNilWhenBothPhasesSucceed() {
        let outcome = CleanUpAllResult(result: PruneResult(deletedImageCount: 8), failureMessages: [])
        #expect(outcome.errorAlertMessage == nil)
    }

    @Test func errorAlertMessageIsJustFailuresWhenNothingSucceeded() {
        let outcome = CleanUpAllResult(result: PruneResult(), failureMessages: ["Removing unused images failed: boom"])
        #expect(outcome.errorAlertMessage == "Removing unused images failed: boom")
    }

    @Test func errorAlertMessageFoldsInPartialSuccessSummary() {
        // A real partial success (e.g. images cleaned, then the container step throws) must not be
        // hidden behind a bare failure message that implies nothing happened.
        let outcome = CleanUpAllResult(
            result: PruneResult(imagesFreedBytes: 100_000_000, deletedImageCount: 1),
            failureMessages: ["Removing stopped containers failed: boom"]
        )
        #expect(outcome.errorAlertMessage == "Reclaimed 95.4 MB — removed 1 image.\n\nRemoving stopped containers failed: boom")
    }

    @Test func errorAlertMessageJoinsMultipleFailures() {
        let outcome = CleanUpAllResult(result: PruneResult(), failureMessages: [
            "Removing unused images failed: boom",
            "Removing stopped containers failed: bang",
        ])
        #expect(outcome.errorAlertMessage == "Removing unused images failed: boom\nRemoving stopped containers failed: bang")
    }
}
