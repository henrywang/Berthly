// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

struct ContainerStatsMathTests {

    // MARK: - cpuPercent

    @Test func cpuPercentComputesFromCounterDelta() {
        // 2_000_000 µs of CPU over 1s on 2 cores = 100% of one core = 100/2 = 100% ... check math:
        // delta 2e6 µs / (1s * 1e6) = 2.0 core-seconds/s; / 2 cores * 100 = 100%.
        let pct = ContainerStatsMath.cpuPercent(
            previousUsec: 0, currentUsec: 2_000_000, elapsed: 1, cores: 2)
        #expect(pct == 100)
    }

    @Test func cpuPercentHalfOfOneCore() {
        // 500_000 µs over 1s on 4 cores = 0.5 core-seconds/s / 4 * 100 = 12.5%.
        let pct = ContainerStatsMath.cpuPercent(
            previousUsec: 1_000_000, currentUsec: 1_500_000, elapsed: 1, cores: 4)
        #expect(pct == 12.5)
    }

    @Test func cpuPercentZeroWithoutPreviousSample() {
        #expect(ContainerStatsMath.cpuPercent(
            previousUsec: nil, currentUsec: 5_000_000, elapsed: 2, cores: 4) == 0)
    }

    @Test func cpuPercentZeroWhenCurrentMissing() {
        #expect(ContainerStatsMath.cpuPercent(
            previousUsec: 1_000, currentUsec: nil, elapsed: 2, cores: 4) == 0)
    }

    @Test func cpuPercentZeroOnCounterReset() {
        // Counter went backwards (container restart) — don't report a negative/garbage spike.
        #expect(ContainerStatsMath.cpuPercent(
            previousUsec: 9_000_000, currentUsec: 1_000, elapsed: 2, cores: 4) == 0)
    }

    @Test func cpuPercentZeroWhenNoTimeElapsed() {
        #expect(ContainerStatsMath.cpuPercent(
            previousUsec: 0, currentUsec: 2_000_000, elapsed: 0, cores: 2) == 0)
    }

    @Test func cpuPercentClampsCoresToAtLeastOne() {
        // Guards against a divide-by-zero if a bogus core count ever arrives.
        let pct = ContainerStatsMath.cpuPercent(
            previousUsec: 0, currentUsec: 1_000_000, elapsed: 1, cores: 0)
        #expect(pct == 100)
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
