// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import TerminalProgress

/// Turns a download's `ProgressUpdateEvent` stream into occasional, human-readable lines for an
/// append-only log. The log can't take a live-updating progress bar (each `onLog` call appends a
/// new line), so instead of emitting per event this throttles to one line each time the
/// downloaded byte count crosses the next `bucketBytes` boundary — a few-hundred-MB download
/// yields ~10–20 lines rather than thousands.
///
/// Two download shapes are both handled here: image pulls (builder image, vminit filesystem)
/// report incremental `.addSize` deltas per layer, matching what `PullImageSheet` observes, while
/// the kernel tar's plain HTTP download reports a single `.setSize` with the cumulative bytes
/// received so far. Both use `.addTotalSize`/`.setTotalSize` once headers/manifest resolve.
/// `downloadedBytes` is monotonic either way, so bucketing on it is stable even though
/// `totalBytes` can grow as more of it is discovered — which is why we throttle on downloaded
/// bytes, not on a percent-of-total that would jump around.
nonisolated struct DownloadProgress {
    let label: String
    let bucketBytes: Int64
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private var lastEmittedBucket: Int64 = -1

    // 10 MiB buckets: frequent enough that a slow connection still shows steady movement,
    // without flooding the log.
    init(label: String, bucketBytes: Int64 = 10 * 1_048_576) {
        self.label = label
        self.bucketBytes = bucketBytes
    }

    /// Fold in a batch of events. Returns a log line to append iff a new `bucketBytes` boundary
    /// was crossed (which includes the very first size event — that's the "download started"
    /// signal). Returns `nil` when no download bytes moved (e.g. a cached fetch emits no size
    /// events, so no misleading "Downloading…" line ever appears).
    mutating func apply(_ events: [ProgressUpdateEvent]) -> String? {
        var sawSize = false
        for event in events {
            switch event {
            case .addSize(let n): downloadedBytes += n; sawSize = true
            case .setSize(let n): downloadedBytes = n; sawSize = true
            case .addTotalSize(let n): totalBytes += n
            case .setTotalSize(let n): totalBytes = n
            default: break
            }
        }
        guard sawSize else { return nil }
        let bucket = downloadedBytes / bucketBytes
        guard bucket > lastEmittedBucket else { return nil }
        lastEmittedBucket = bucket
        return logLine
    }

    /// e.g. "Downloading builder image (ghcr.io/…/builder:0.12.0)… 45.0 MB / 380.0 MB". The total
    /// is dropped until it's known, since it isn't always reported until the download starts.
    /// Formatting is shared with the rest of the app's byte displays via `formatDiskBytes`.
    var logLine: String {
        let downloaded = formatDiskBytes(UInt64(downloadedBytes))
        if totalBytes > 0 {
            return "\(label)… \(downloaded) / \(formatDiskBytes(UInt64(totalBytes)))"
        }
        return "\(label)… \(downloaded)"
    }
}

/// MainActor bridge from a download's `@Sendable` progress handler to a log's `onLog`. Holds the
/// pure `DownloadProgress` and forwards any throttled line. Accumulating on the main actor
/// (rather than in an actor of its own) mirrors `PullImageSheet.handler` — events are network-paced
/// so the hop costs nothing, and it sidesteps a `@Sendable` closure trying to mutate captured state.
@MainActor
final class DownloadReporter {
    private var progress: DownloadProgress
    private let onLog: @MainActor (String) -> Void

    init(label: String, onLog: @escaping @MainActor (String) -> Void) {
        self.progress = DownloadProgress(label: label)
        self.onLog = onLog
    }

    private func ingest(_ events: [ProgressUpdateEvent]) {
        if let line = progress.apply(events) { onLog(line) }
    }

    /// The `@Sendable` handler to hand to a `progressUpdate:` parameter.
    nonisolated var handler: ProgressUpdateHandler {
        { [weak self] events in await self?.ingest(events) }
    }
}
