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
