// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct ImageMetadataCacheReconcilerTests {
    @Test
    func cachedDigestsAreNotRequestedAgain() async {
        var decodeCalls = 0
        let (results, cache) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d1"],
            cache: ["d1": "M1"]
        ) { _ in
            decodeCalls += 1
            return "should-not-be-used"
        }
        let expected: [String: String] = ["d1": "M1"]
        #expect(decodeCalls == 0)
        #expect(results == expected)
        #expect(cache == expected)
    }

    @Test
    func sameDigestRetagsRequireOneDecode() async {
        var decodeCalls = 0
        let (results, cache) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d1", "d1", "d1"],
            cache: [String: String]()
        ) { _ in
            decodeCalls += 1
            return "M1"
        }
        let expected: [String: String] = ["d1": "M1"]
        #expect(decodeCalls == 1)
        #expect(results == expected)
        #expect(cache == expected)
    }

    @Test
    func newDigestsRequireDecoding() async {
        let (results, cache) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d2"],
            cache: [String: String]()
        ) { digest in "decoded-\(digest)" }
        let expected: [String: String] = ["d2": "decoded-d2"]
        #expect(results == expected)
        #expect(cache == expected)
    }

    @Test
    func removedDigestsAreEvicted() async {
        let (results, cache) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d1"],
            cache: ["d1": "M1", "d2": "M2"]
        ) { _ in
            Issue.record("decode should not run for an already-cached digest")
            return nil
        }
        let expected: [String: String] = ["d1": "M1"]
        #expect(results == expected)
        #expect(cache == expected)
    }

    @Test
    func failedDigestsRetryOnNextPollNotRepeatedlyWithinOnePoll() async {
        var decodeCalls = 0
        let (firstResults, firstCache) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d3", "d3", "d3"],
            cache: [String: String]()
        ) { _ in
            decodeCalls += 1
            return nil
        }
        #expect(decodeCalls == 1)
        #expect(firstResults.isEmpty)
        #expect(firstCache.isEmpty)

        let (secondResults, secondCache) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d3"],
            cache: firstCache
        ) { _ in
            decodeCalls += 1
            return "M3"
        }
        let expected: [String: String] = ["d3": "M3"]
        #expect(decodeCalls == 2)
        #expect(secondResults == expected)
        #expect(secondCache == expected)
    }

    @Test
    func everyImageSharingADigestReceivesIdenticalMetadata() async {
        let (results, _) = await ImageMetadataCacheReconciler.reconcile(
            digests: ["d1", "d1"],
            cache: [String: String]()
        ) { _ in "M1" }
        let imageDigests = ["d1", "d1"]
        let resolved = imageDigests.map { results[$0] }
        let expected: [String?] = ["M1", "M1"]
        #expect(resolved == expected)
    }
}
