// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import TerminalProgress

/// Turns builder-image pull progress events into occasional, human-readable lines for the
/// append-only build log. The build log can't take a live-updating progress bar (each `onLog`
/// call appends a new line), so instead of emitting per event this throttles to one line each time
/// the downloaded byte count crosses the next `bucketBytes` boundary — a few-hundred-MB image
/// yields ~10–20 lines rather than thousands.
///
/// Only the `.add*` events are accumulated, matching what `PullImageSheet` observes actually
/// firing during a pull (the `.set*` variants don't arrive). Downloaded bytes are monotonic, so
/// bucketing on them is stable even though the discovered `total` grows as layers are resolved —
/// which is why we throttle on downloaded bytes, not on a percent-of-total that would jump around.
nonisolated struct BuilderPullProgress {
    let imageReference: String
    let bucketBytes: Int64
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private var lastEmittedBucket: Int64 = -1

    // 10 MiB buckets: the builder image is ~100 MB, so this yields ~10 progress lines — frequent
    // enough that a slow connection still shows steady movement, without flooding the log.
    init(imageReference: String, bucketBytes: Int64 = 10 * 1_048_576) {
        self.imageReference = imageReference
        self.bucketBytes = bucketBytes
    }

    /// Fold in a batch of events. Returns a log line to append iff a new `bucketBytes` boundary was
    /// crossed (which includes the very first size event — that's the "download started" signal).
    /// Returns `nil` when no download bytes moved (e.g. a cached fetch emits no size events, so no
    /// misleading "Downloading…" line ever appears).
    mutating func apply(_ events: [ProgressUpdateEvent]) -> String? {
        var sawSize = false
        for event in events {
            switch event {
            case .addSize(let n):      downloadedBytes += n; sawSize = true
            case .addTotalSize(let n): totalBytes += n
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
    /// is dropped until it's known, since it isn't reported until the first layers resolve.
    var logLine: String {
        let downloaded = Self.formatBytes(downloadedBytes)
        if totalBytes > 0 {
            return "Downloading builder image (\(imageReference))… \(downloaded) / \(Self.formatBytes(totalBytes))"
        }
        return "Downloading builder image (\(imageReference))… \(downloaded)"
    }

    /// MiB with one decimal (matching `PullImageSheet`'s size formatting), falling back to KB/B for
    /// small amounts.
    static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }
}

/// MainActor bridge from the fetch's `@Sendable` progress handler to the build log's `onLog`. Holds
/// the pure `BuilderPullProgress` and forwards any throttled line. Accumulating on the main actor
/// (rather than in an actor of its own) mirrors `PullImageSheet.handler` — events are network-paced
/// so the hop costs nothing, and it sidesteps a `@Sendable` closure trying to mutate captured state.
@MainActor
final class BuilderPullReporter {
    private var progress: BuilderPullProgress
    private let onLog: @MainActor (String) -> Void

    init(imageReference: String, onLog: @escaping @MainActor (String) -> Void) {
        self.progress = BuilderPullProgress(imageReference: imageReference)
        self.onLog = onLog
    }

    private func ingest(_ events: [ProgressUpdateEvent]) {
        if let line = progress.apply(events) { onLog(line) }
    }

    /// The `@Sendable` handler to hand to `ClientImage.fetch(progressUpdate:)`.
    nonisolated var handler: ProgressUpdateHandler {
        { [weak self] events in await self?.ingest(events) }
    }
}
