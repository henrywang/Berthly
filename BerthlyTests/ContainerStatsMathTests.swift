// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

struct ContainerStatsMathTests {

    // MARK: - cpuPercent

    // #235: percent of one core, like `container stats` and `docker stats` — two saturated cores
    // read 200%, not 200% divided by the host's core count.
    @Test func cpuPercentIsPerCoreAndCanExceed100() {
        // 2e6 µs of CPU over 1s = 2 core-seconds/s = 200%.
        let pct = ContainerStatsMath.cpuPercent(previousUsec: 0, currentUsec: 2_000_000, elapsed: 1)
        #expect(pct == 200)
    }

    @Test func cpuPercentHalfOfOneCore() {
        let pct = ContainerStatsMath.cpuPercent(previousUsec: 1_000_000, currentUsec: 1_500_000, elapsed: 1)
        #expect(pct == 50)
    }

    @Test func cpuPercentMatchesTheCLIsCPUUtilizationTimes100() {
        // The CLI's formula (ContainerStats.calculateCPUUtilization): cpuDelta / timeInterval.
        // 750_000 µs over 2s = 0.375 → the CLI table prints "37.50%".
        let pct = ContainerStatsMath.cpuPercent(previousUsec: 250_000, currentUsec: 1_000_000, elapsed: 2)
        #expect(pct == 0.375 * 100)
    }

    @Test func cpuPercentZeroWithoutPreviousSample() {
        #expect(ContainerStatsMath.cpuPercent(previousUsec: nil, currentUsec: 5_000_000, elapsed: 2) == 0)
    }

    @Test func cpuPercentZeroWhenCurrentMissing() {
        #expect(ContainerStatsMath.cpuPercent(previousUsec: 1_000, currentUsec: nil, elapsed: 2) == 0)
    }

    @Test func cpuPercentZeroOnCounterReset() {
        // Counter went backwards (container restart) — don't report a negative/garbage spike.
        #expect(ContainerStatsMath.cpuPercent(previousUsec: 9_000_000, currentUsec: 1_000, elapsed: 2) == 0)
    }

    @Test func cpuPercentZeroWhenNoTimeElapsed() {
        #expect(ContainerStatsMath.cpuPercent(previousUsec: 0, currentUsec: 2_000_000, elapsed: 0) == 0)
    }

    // MARK: - networkRateMBPerSecond

    @Test func networkSumsRxAndTxAsPerSecondRate() {
        // rx +1 MiB, tx +1 MiB over 2s => 2 MiB / 2s = 1 MB/s.
        let rate = ContainerStatsMath.networkRateMBPerSecond(
            previousRx: 0, currentRx: 1_048_576,
            previousTx: 0, currentTx: 1_048_576,
            elapsed: 2)
        #expect(rate == 1)
    }

    @Test func networkRateDividesByActualElapsed() {
        // Same 2 MiB of traffic over 4s is half the rate: 0.5 MB/s.
        let rate = ContainerStatsMath.networkRateMBPerSecond(
            previousRx: 0, currentRx: 1_048_576,
            previousTx: 0, currentTx: 1_048_576,
            elapsed: 4)
        #expect(rate == 0.5)
    }

    @Test func networkZeroWithoutPreviousSample() {
        #expect(ContainerStatsMath.networkRateMBPerSecond(
            previousRx: nil, currentRx: 1_048_576,
            previousTx: nil, currentTx: 1_048_576,
            elapsed: 2) == 0)
    }

    @Test func networkZeroWhenNoTimeElapsed() {
        #expect(ContainerStatsMath.networkRateMBPerSecond(
            previousRx: 0, currentRx: 1_048_576,
            previousTx: 0, currentTx: 1_048_576,
            elapsed: 0) == 0)
    }

    @Test func networkZeroOnCounterReset() {
        #expect(ContainerStatsMath.networkRateMBPerSecond(
            previousRx: 5_000_000, currentRx: 10,
            previousTx: 0, currentTx: 10,
            elapsed: 2) == 0)
    }

    // MARK: - trend

    @Test func trendStableBelowSixSamples() {
        #expect(ContainerStatsMath.trend(for: [0, 10, 20, 30, 40]) == .stable)
    }

    @Test func trendUpWhenRisenMoreThanTwo() {
        // last (50) vs six-ago (10) => +40.
        #expect(ContainerStatsMath.trend(for: [10, 20, 30, 40, 45, 50]) == .up(40))
    }

    @Test func trendDownWhenFallenMoreThanTwo() {
        // last (10) vs six-ago (50) => -40, reported as .down(40).
        #expect(ContainerStatsMath.trend(for: [50, 40, 30, 20, 15, 10]) == .down(40))
    }

    @Test func trendStableWithinDeadband() {
        // Change of exactly +2 is not "more than 2" => stable.
        #expect(ContainerStatsMath.trend(for: [10, 11, 11, 11, 11, 12]) == .stable)
    }
}

// MARK: - Delta tracker

struct ContainerStatsDeltaTrackerTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test func firstSampleHasZeroRatesButRealMemory() {
        var tracker = ContainerStatsDeltaTracker()
        let sample = tracker.sample(
            cpuUsageUsec: 5_000_000, memoryUsageBytes: 256 * 1_048_576,
            networkRxBytes: 9_999, networkTxBytes: 9_999,
            at: t0)
        #expect(sample.cpuPercent == 0)
        #expect(sample.networkMBPerSecond == 0)
        #expect(sample.memoryMB == 256)
    }

    @Test func secondSampleComputesRatesFromCarriedCounters() {
        var tracker = ContainerStatsDeltaTracker()
        _ = tracker.sample(
            cpuUsageUsec: 0, memoryUsageBytes: 0,
            networkRxBytes: 0, networkTxBytes: 0,
            at: t0)
        // +2s wall clock: 2e6 µs CPU = 1 core-second/s = 100%; rx+tx +2 MiB over 2s = 1 MB/s.
        let sample = tracker.sample(
            cpuUsageUsec: 2_000_000, memoryUsageBytes: 128 * 1_048_576,
            networkRxBytes: 1_048_576, networkTxBytes: 1_048_576,
            at: t0.addingTimeInterval(2))
        #expect(sample.cpuPercent == 100)
        #expect(sample.networkMBPerSecond == 1)
        #expect(sample.memoryMB == 128)
    }

    @Test func counterResetYieldsZeroRatesThenRecovers() {
        var tracker = ContainerStatsDeltaTracker()
        _ = tracker.sample(cpuUsageUsec: 9_000_000, memoryUsageBytes: 0,
                           networkRxBytes: 9_000_000, networkTxBytes: 0,
                           at: t0)
        // Counters went backwards (container restart) — no negative/garbage spike.
        let reset = tracker.sample(cpuUsageUsec: 1_000, memoryUsageBytes: 0,
                                   networkRxBytes: 10, networkTxBytes: 0,
                                   at: t0.addingTimeInterval(2))
        #expect(reset.cpuPercent == 0)
        #expect(reset.networkMBPerSecond == 0)
        // The reset read becomes the new baseline: the next delta computes normally.
        let recovered = tracker.sample(cpuUsageUsec: 1_001_000, memoryUsageBytes: 0,
                                       networkRxBytes: 1_048_586, networkTxBytes: 0,
                                       at: t0.addingTimeInterval(3))
        #expect(recovered.cpuPercent == 100)
        #expect(recovered.networkMBPerSecond == 1)
    }

    @Test func missingCountersAreTreatedAsUnavailableNotCrash() {
        var tracker = ContainerStatsDeltaTracker()
        let sample = tracker.sample(cpuUsageUsec: nil, memoryUsageBytes: nil,
                                    networkRxBytes: nil, networkTxBytes: nil,
                                    at: t0)
        #expect(sample == ContainerStatsSample(cpuPercent: 0, memoryMB: 0, networkMBPerSecond: 0))
    }
}
