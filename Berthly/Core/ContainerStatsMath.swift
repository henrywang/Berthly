import Foundation

/// Pure helpers behind the container Overview's live metrics. The daemon's `stats` endpoint
/// hands back cumulative counters; turning those into a CPU percentage / network rate is delta
/// math that runs in `OverviewTab`'s poll loop. Extracted here so it's testable without a live
/// `ContainerClient` connection (per CLAUDE.md: logic doesn't belong trapped in a view).
enum ContainerStatsMath {
    /// Direction of a metric series over its trailing sparkline window.
    enum Trend: Equatable {
        case stable
        case up(Double)    // magnitude of the increase
        case down(Double)  // magnitude of the decrease (positive number)
    }

    /// CPU utilisation as a percentage of all cores, from the delta between two cumulative
    /// `cpu_usage_usec` reads. Returns 0 when there's no previous sample, the interval is
    /// non-positive, or the counter went backwards (a reset) — i.e. the "can't compute a rate
    /// yet" cases, so the first poll after opening a container reads 0%.
    static func cpuPercent(
        previousUsec: UInt64?,
        currentUsec: UInt64?,
        elapsed: TimeInterval,
        cores: Int
    ) -> Double {
        guard let cur = currentUsec, let prev = previousUsec,
              elapsed > 0, cur >= prev else { return 0 }
        return Double(cur - prev) / (elapsed * 1_000_000) / Double(max(1, cores)) * 100
    }

    /// Combined network throughput (rx + tx) as a true per-second rate, in MB/s, from the delta
    /// between two cumulative byte counters over `elapsed` seconds. "MB" here is mebibytes
    /// (÷1_048_576), matching how the memory figure is reported. Returns 0 for the first sample,
    /// a non-positive interval, or a counter reset.
    static func networkRateMBPerSecond(
        previousRx: UInt64?, currentRx: UInt64,
        previousTx: UInt64?, currentTx: UInt64,
        elapsed: TimeInterval
    ) -> Double {
        guard let pRx = previousRx, let pTx = previousTx,
              elapsed > 0, currentRx >= pRx, currentTx >= pTx else { return 0 }
        let bytes = Double((currentRx - pRx) + (currentTx - pTx))
        return bytes / 1_048_576 / elapsed
    }

    /// Trend of a series judged over its last 6 samples (the sparkline window): `.stable` until
    /// there are at least 6 points, then `.up`/`.down` only if the change from 6 samples ago
    /// exceeds ±2 (otherwise `.stable`).
    static func trend(for values: [Double]) -> Trend {
        guard values.count >= 6 else { return .stable }
        let delta = values[values.count - 1] - values[values.count - 6]
        if delta >  2 { return .up(delta) }
        if delta < -2 { return .down(-delta) }
        return .stable
    }
}
