// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerizationOCI
import Foundation

/// Pure staleness logic for Watchtower-style image-update detection: which local images are
/// worth a registry check, how digests compare, and how a container's pinned digest relates to
/// its tag. All `nonisolated` and free of XPC/network so `BerthlyTests` can cover the matrix
/// (`LiveContainerService.buildArguments(for:)` is the pattern).
nonisolated enum ImageStaleness {
    /// On-connect plus every 6 hours. Registry HEAD manifest requests don't count against
    /// Docker Hub pull limits (Watchtower relies on this), but there's no reason to ask more
    /// often than image publishers actually ship.
    static let checkInterval: TimeInterval = 6 * 3600

    /// Local references worth a remote HEAD: pulled from a real registry (a parseable domain),
    /// addressed by tag. Built images, domain-less names like `local/web:1.4`, digest-pinned
    /// pulls (`name@sha256:…` can never have a *newer* digest), and builder infrastructure are
    /// all skipped. Deduped preserving order.
    static func eligibleReferences(images: [ContainerImage]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for image in images {
            guard image.source == .pulled, image.usage != .builderImage else { continue }
            guard let ref = try? Reference.parse(image.id),
                  ref.domain != nil, ref.tag != nil, ref.digest == nil else { continue }
            if seen.insert(image.id).inserted { result.append(image.id) }
        }
        return result
    }

    /// The local digest that is actually comparable to a registry's root digest. When a pulled
    /// tag's remote root is a single manifest (not an index), the daemon wraps it in a
    /// synthesized index annotated `containerizationIndexIndirect` — so the image's own digest
    /// never equals the remote one and naive comparison false-positives forever. This unwraps
    /// exactly like the package-internal `ClientImage.resolved()` (not `public`, hence the
    /// reimplementation over the public `index()` data).
    static func comparableLocalDigest(ownDigest: String, index: Index) -> String {
        guard let indirect = index.annotations?[AnnotationKeys.containerizationIndexIndirect],
              ["1", "true"].contains(indirect.lowercased()),
              let manifest = index.manifests.first else {
            return ownDigest
        }
        return manifest.digest
    }

    /// A check result is only valid for the image bytes it was computed against: if the image's
    /// digest has moved since (user pulled or rebuilt), the stored info answers a question about
    /// an image that no longer exists locally → `.unknown`, not a stale verdict either way.
    static func availability(image: ContainerImage, info: ImageUpdateInfo?) -> ImageUpdateAvailability {
        guard let info, info.localImageDigest == image.digest else { return .unknown }
        return info.isUpdateAvailable ? .updateAvailable : .upToDate
    }

    /// Ref→image matching mirrors `ContainerImage.resolvingUsage` (id, fullName, or digest) so
    /// the badge and the "used by" count never disagree about which image a container runs.
    /// Pinned-digest drift beats a remote update: once the local image is newer than the
    /// container, "recreate to apply" is the actionable message regardless of the registry.
    static func staleness(
        containerImageRef: String, containerImageDigest: String?,
        images: [ContainerImage], updateInfo: [String: ImageUpdateInfo]
    ) -> ContainerImageStaleness {
        guard let image = images.first(where: {
            containerImageRef == $0.id || containerImageRef == $0.fullName || containerImageRef == $0.digest
        }) else { return .current }
        // Without a pinned digest there's no knowing what the container actually runs — it may
        // already be on the registry's digest — so neither stale verdict can be justified.
        guard let pinned = containerImageDigest else { return .current }
        if pinned != image.digest { return .localImageNewer }
        if availability(image: image, info: updateInfo[image.id]) == .updateAvailable {
            return .remoteUpdateAvailable
        }
        return .current
    }

    static func isCheckDue(lastCheck: Date?, now: Date, interval: TimeInterval = checkInterval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    /// Whether `poll()` may run its automatic registry check — the Settings "Check images for
    /// updates" toggle, defaulting on when unset (a fresh install, or a `UserDefaults` value of
    /// some other type). Only gates the automatic path: manual checks and recreate always work.
    static func automaticCheckEnabled(userDefaultValue: Any?) -> Bool {
        (userDefaultValue as? Bool) ?? true
    }

    // MARK: - Insecure-registry-host memory

    static let insecureHostsDefaultsKey = "insecureRegistryHosts"

    /// Case/trailing-dot folding shared by both entry points below — every write and every read
    /// of the insecure-hosts memory must go through one of them, or the same host typed/derived
    /// differently (case, a trailing FQDN dot) silently fragments into separate trust entries.
    private static func foldedHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// For a full image reference (pull/push/run, the update checker, recreate) — Docker Hub
    /// aliasing (`docker.io` → `registry-1.docker.io`) is already handled by `resolvedDomain`.
    static func registryHost(for reference: String) -> String? {
        guard let ref = try? Reference.parse(reference), let domain = ref.resolvedDomain else { return nil }
        return foldedHost(domain)
    }

    /// For an already-isolated bare host (sign-in's `host` parameter, which the caller resolves
    /// itself before this is ever relevant) — skips `Reference.parse`, which only detects a
    /// domain when a `/` separates it from a path; a bare `"host:port"` string with no path
    /// would otherwise misparse as an image name:tag pair with no domain at all.
    static func foldedBareHost(_ host: String) -> String {
        foldedHost(host)
    }

    /// Merge a newly-trusted host into the persisted array — dedupe via `Set`, sorted for a
    /// stable, diffable `UserDefaults` value.
    static func addingInsecureHost(_ host: String, to existing: [String]) -> [String] {
        var set = Set(existing)
        set.insert(host)
        return Array(set).sorted()
    }

    static func isHostInsecure(reference: String, knownInsecureHosts: [String]) -> Bool {
        guard let host = registryHost(for: reference) else { return false }
        return knownInsecureHosts.contains(host)
    }
}
