// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
import TerminalProgress
@testable import Berthly

@Suite struct BuilderPullProgressTests {

    @Test func firstSizeEventEmitsADownloadingLine() {
        var p = BuilderPullProgress(imageReference: "img:1", bucketBytes: 25 * 1_048_576)
        let line = p.apply([.addSize(1_000_000)])
        #expect(line != nil)
        #expect(line!.contains("Downloading builder image (img:1)"))
    }

    @Test func emitsOnlyAtBucketBoundaries() {
        var p = BuilderPullProgress(imageReference: "img", bucketBytes: 10_000_000)
        #expect(p.apply([.addSize(1_000_000)]) != nil)   // bucket 0 — first line
        #expect(p.apply([.addSize(1_000_000)]) == nil)   // still bucket 0
        #expect(p.apply([.addSize(8_000_000)]) != nil)   // 10M total → bucket 1
        #expect(p.apply([.addSize(500_000)]) == nil)     // still bucket 1
    }

    @Test func accumulatesDownloadedBytes() {
        var p = BuilderPullProgress(imageReference: "img", bucketBytes: 1_000_000)
        _ = p.apply([.addSize(500_000)])
        _ = p.apply([.addSize(700_000)])
        #expect(p.downloadedBytes == 1_200_000)
    }

    @Test func showsTotalOnlyOnceKnown() {
        var p = BuilderPullProgress(imageReference: "img", bucketBytes: 1)
        // No total yet → line has no "/".
        let first = p.apply([.addSize(1_048_576)])
        #expect(first != nil)
        #expect(first!.contains("/") == false)
        // Total arrives → subsequent line shows "downloaded / total".
        let second = p.apply([.addTotalSize(380 * 1_048_576), .addSize(1_048_576)])
        #expect(second!.contains(" / "))
    }

    @Test func noSizeEventProducesNoLine() {
        // A cached fetch (only total/items events, or nothing) must not emit a "Downloading" line.
        var p = BuilderPullProgress(imageReference: "img", bucketBytes: 1)
        #expect(p.apply([.addTotalSize(100), .addItems(1), .addTotalItems(2)]) == nil)
        #expect(p.apply([]) == nil)
    }

    @Test func formatsBytesInMiB() {
        #expect(BuilderPullProgress.formatBytes(45 * 1_048_576) == "45.0 MB")
        #expect(BuilderPullProgress.formatBytes(2048) == "2 KB")
        #expect(BuilderPullProgress.formatBytes(512) == "512 B")
    }
}
