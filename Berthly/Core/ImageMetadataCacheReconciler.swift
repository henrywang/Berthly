// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

/// Reconciles a per-digest metadata cache against the current poll's set of digests.
///
/// Pulled out of `LiveContainerService.fetchImages` so the dedup/eviction rules are unit-testable
/// without a real daemon: `decode` is the only daemon-dependent piece, injected by the caller.
///
/// Rules:
/// - A digest already in `cache` is reused, never re-decoded.
/// - Multiple images can share a digest (retags); an uncached digest is decoded at most once per
///   call, and every image with that digest gets the same result — decoding per-reference instead
///   let an earlier row see a transient failure while a later row (same digest, retried within the
///   same poll) saw a success, splitting one digest across two different displayed states.
/// - A decode failure is left out of both `cache` and `results`, so the next poll retries it
///   instead of freezing a blank/failed state permanently.
/// - Cache entries for digests no longer present are dropped (image removed).
enum ImageMetadataCacheReconciler {
    static func reconcile<Digest: Hashable, Metadata>(
        digests: [Digest],
        cache: [Digest: Metadata],
        decode: (Digest) async -> Metadata?
    ) async -> (results: [Digest: Metadata], cache: [Digest: Metadata]) {
        var cache = cache
        var results: [Digest: Metadata] = [:]
        var attempted: Set<Digest> = []

        for digest in digests {
            if let cached = cache[digest] {
                results[digest] = cached
                continue
            }
            guard !attempted.contains(digest) else { continue }
            attempted.insert(digest)
            if let decoded = await decode(digest) {
                cache[digest] = decoded
                results[digest] = decoded
            }
        }

        let currentDigests = Set(digests)
        cache = cache.filter { currentDigests.contains($0.key) }
        return (results, cache)
    }
}
