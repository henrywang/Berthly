// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AsyncHTTPClient
import ContainerAPIClient
import ContainerBuild
import ContainerImagesServiceClient
import ContainerResource
import Containerization
import ContainerizationError
import ContainerizationExtras
import ContainerizationOCI
import ContainerizationOS
import Darwin
import Foundation
import Logging
import MachineAPIClient
import NIOCore
import NIOHTTP1
import NIOPosix
import TerminalProgress
internal import ContainerPersistence
internal import ContainerPlugin

extension LiveContainerService {
    func pullImageImpl(
        reference: String,
        platform: String?,
        insecure: Bool,
        progress: ProgressUpdateHandler?,
        onUnpacking: (() -> Void)?
    ) async throws {
        let config = await resolvedSystemConfig()
        let ociPlatform: Platform? = try {
            guard let p = platform, !p.isEmpty else { return nil }
            return try Platform(from: p)
        }()
        let image = try await ClientImage.pull(
            reference: reference,
            platform: ociPlatform,
            scheme: RegistrySchemeResolver.scheme(
                forReference: reference, insecure: insecure, internalDnsDomain: config.dns.domain
            ),
            containerSystemConfig: config,
            progressUpdate: progress
        )
        onUnpacking?()
        try await image.unpack(platform: ociPlatform)
        if insecure, let host = ImageStaleness.registryHost(for: reference) {
            Self.rememberInsecureHost(host)
        }
        await refresh()
    }

    func isKnownInsecureRegistryImpl(forReference reference: String) -> Bool {
        let knownInsecureHosts = UserDefaults.standard.stringArray(forKey: ImageStaleness.insecureHostsDefaultsKey) ?? []
        return ImageStaleness.isHostInsecure(reference: reference, knownInsecureHosts: knownInsecureHosts)
    }

    func checkForImageUpdatesImpl(force: Bool) async {
        guard isConnected, !isCheckingImageUpdates else { return }
        if !force, !ImageStaleness.isCheckDue(lastCheck: lastImageUpdateCheck, now: .now) { return }
        isCheckingImageUpdates = true
        defer { isCheckingImageUpdates = false }
        lastImageUpdateCheck = .now

        let config = await resolvedSystemConfig()
        let dnsDomain = config.dns.domain
        // Credentials are attempted only for hosts with a stored login: a Keychain lookup for a
        // never-signed-in host can still hit ACL prompts/errors, and anonymous works for public
        // registries (RegistryClient runs the token flow itself).
        let signedInHosts = Set(registries.map(\.host))
        let knownInsecureHosts = Set(UserDefaults.standard.stringArray(forKey: ImageStaleness.insecureHostsDefaultsKey) ?? [])
        let eligible = ImageStaleness.eligibleReferences(images: images)

        var results: [String: ImageUpdateInfo] = [:]
        await withTaskGroup(of: (String, ImageUpdateInfo)?.self) { group in
            var iterator = eligible.makeIterator()
            func addNext() {
                guard let reference = iterator.next() else { return }
                group.addTask {
                    await Self.checkOneImageUpdate(reference: reference, signedInHosts: signedInHosts,
                                                   knownInsecureHosts: knownInsecureHosts,
                                                   internalDnsDomain: dnsDomain, systemConfig: config)
                }
            }
            // Window of 4: enough parallelism to keep a large image list quick, small enough to
            // not burst-hammer a single registry host.
            for _ in 0..<4 { addNext() }
            for await result in group {
                if let (id, info) = result { results[id] = info }
                addNext()
            }
        }
        // A badge must be a *currently confirmable* claim: clear every reference this batch
        // checked before merging, so a reference whose check failed loses its old verdict
        // instead of pinning a stale "update available" indefinitely.
        for reference in eligible { imageUpdateInfo[reference] = nil }
        imageUpdateInfo.merge(results) { _, new in new }
    }

    /// One registry HEAD comparison. Returns `nil` on any failure — a background check must
    /// never surface an error; a missing entry simply means no badge.
    private nonisolated static func checkOneImageUpdate(
        reference: String, signedInHosts: Set<String>, knownInsecureHosts: Set<String>,
        internalDnsDomain: String?, systemConfig: ContainerSystemConfig
    ) async -> (String, ImageUpdateInfo)? {
        do {
            let ref = try Reference.parse(reference)
            guard let domain = ref.resolvedDomain, let tag = ref.tag else { return nil }
            // The canonicalized lookup key (case/trailing-dot folded) is used only to consult
            // the insecure-hosts memory — the raw `domain` still drives the actual connection,
            // so this can't have any side effect on DNS/URL construction.
            let isInsecure = knownInsecureHosts.contains(ImageStaleness.registryHost(for: reference) ?? domain)
            let target = try resolveRegistryConnectionTarget(
                host: domain, insecure: isInsecure, internalDnsDomain: internalDnsDomain
            )
            // try? on the lookup: a CLI-owned Keychain item Berthly can't read (see
            // errSecInvalidOwnerEdit) degrades to an anonymous check, not a failure.
            // Offloaded (keychainLookup, not a direct registryKeychain.lookup call) — several of
            // these run concurrently in checkForImageUpdates' task group, and the synchronous
            // Security-framework call would otherwise tie up the cooperative thread pool.
            let auth: Authentication? = signedInHosts.contains(domain)
                ? try? await Self.keychainLookup(hostname: domain)
                : nil
            let client = RegistryClient(
                host: target.host,
                scheme: target.scheme.rawValue,
                port: target.port,
                authentication: auth,
                retryOptions: RetryOptions(maxRetries: 1, retryInterval: 300_000_000, shouldRetry: { $0.status.code >= 500 })
            )
            let remote = try await client.resolve(name: ref.path, tag: tag)
            let local = try await ClientImage.get(reference: reference, containerSystemConfig: systemConfig)
            let comparable = ImageStaleness.comparableLocalDigest(ownDigest: local.digest, index: try await local.index())
            return (reference, ImageUpdateInfo(
                remoteDigest: remote.digest,
                localImageDigest: local.digest,
                isUpdateAvailable: remote.digest != comparable,
                checkedAt: .now
            ))
        } catch {
            // Any failure → no badge. Since apple/container 1.3.1 that includes an authenticated
            // registry reached over plain HTTP (internal host or insecure toggle): RegistryClient
            // throws `insecureCredentialExchange` rather than send credentials in the clear. The
            // caller clears every eligible reference before merging, so this can't pin a stale badge.
            return nil
        }
    }

    /// The stored configuration pins the digest the container was *created* from — reusing it
    /// verbatim would recreate the old container byte-for-byte. Everything else (id, mounts,
    /// networks, DNS, resources, labels, init process) is already resolved and carries over.
    nonisolated static func recreatedConfiguration(
        from config: ContainerConfiguration, imageDescriptor: Descriptor
    ) -> ContainerConfiguration {
        var newConfig = config
        newConfig.image = ImageDescription(reference: config.image.reference, descriptor: imageDescriptor)
        return newConfig
    }

    func recreateContainerImpl(
        _ id: String,
        pullFirst: Bool,
        progress: ProgressUpdateHandler?,
        onPhase: @MainActor @escaping (RecreatePhase) -> Void
    ) async throws -> RecreateResult {
        let client = ContainerClient()
        let snapshot = try await client.get(id: id)
        let originalConfig = snapshot.configuration
        let wasRunning = snapshot.status == .running
        let reference = originalConfig.image.reference
        let containerSystemConfig = await resolvedSystemConfig()

        // Pull phase — the only cancellable window: nothing destructive has happened yet, and a
        // pulled-but-unused image is harmless. Platform nil (all variants) so the stored digest
        // stays an index digest, comparable to what checkForImageUpdates checks against.
        // The same insecure-host lookup checkOneImageUpdate uses — without it, a badge could
        // correctly appear for a private HTTP registry, then this exact call would fail against it.
        let knownInsecureHosts = UserDefaults.standard.stringArray(forKey: ImageStaleness.insecureHostsDefaultsKey) ?? []
        let pullScheme = RegistrySchemeResolver.scheme(
            forReference: reference,
            insecure: ImageStaleness.isHostInsecure(reference: reference, knownInsecureHosts: knownInsecureHosts),
            internalDnsDomain: containerSystemConfig.dns.domain
        )
        var didPull = false
        if pullFirst, (try? Reference.parse(reference))?.domain != nil {
            onPhase(.pullingImage)
            let pulled = try await ClientImage.pull(reference: reference, platform: nil, scheme: pullScheme,
                                                    containerSystemConfig: containerSystemConfig,
                                                    progressUpdate: progress)
            try await pulled.unpack(platform: nil)
            didPull = true
        }
        try Task.checkCancellation()

        let image = try await ClientImage.fetch(reference: reference, scheme: pullScheme, containerSystemConfig: containerSystemConfig)
        _ = try await image.getCreateSnapshot(platform: originalConfig.platform)
        let newConfig = Self.recreatedConfiguration(from: originalConfig, imageDescriptor: image.descriptor)
        let kernel = try await ClientKernel.getDefaultKernel(for: .current)
        let initImage = containerSystemConfig.vminit.image

        // Last cancellation point: a cancel racing the fetch/kernel awaits above must land here,
        // not mid-replacement — the XPC calls below don't reliably honor cancellation, so a
        // cancel that slipped past would dismiss the sheet while the replacement continues.
        try Task.checkCancellation()

        // From here to the final start there are deliberately no cancellation checks: the old
        // container is being replaced, and aborting between delete and create would strand the
        // user with no container at all. The sheet only enables Cancel during the pull phase.
        if wasRunning {
            onPhase(.stoppingContainer)
            try await client.stop(id: id)
        }
        onPhase(.deletingContainer)
        do {
            try await client.delete(id: id)
        } catch let deleteError {
            // `ContainerClient.delete` wraps every failure as `.internalError` with the real
            // error buried in `cause`, so a notFound can't be matched directly. An --rm
            // container deletes itself on stop (autoRemove isn't part of the snapshot, so it
            // can't be detected up front — or preserved; the recreated container is plain);
            // post-stop absence is therefore success here.
            //
            // The follow-up `get` must distinguish a *confirmed* absence from a failed lookup:
            // `get` throws `.notFound` directly only when the container list came back empty —
            // any other outcome (the container still exists, or the lookup itself failed —
            // e.g. a transient XPC hiccup, which `list` wraps as `.internalError`) means absence
            // was never established, so proceeding to `create` could collide with a container
            // that's still there. Only a confirmed `.notFound` excuses the original delete error.
            var confirmedAbsent = false
            do {
                _ = try await client.get(id: id)
            } catch let lookupError as ContainerizationError where lookupError.isCode(.notFound) {
                confirmedAbsent = true
            } catch {
                // Lookup itself failed (or threw some other error) — absence is unconfirmed.
            }
            guard confirmedAbsent else { throw deleteError }
        }
        onPhase(.creatingContainer)
        do {
            try await client.create(configuration: newConfig, options: .default, kernel: kernel, initImage: initImage)
        } catch let createError {
            // Roll back to the original configuration — its image blobs are guaranteed present
            // (orphaned-blob GC only runs on explicit user request, after success).
            let restored: Bool
            do {
                try await client.create(configuration: originalConfig, options: .default, kernel: kernel, initImage: initImage)
                if wasRunning {
                    let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
                    try await process.start()
                }
                restored = true
            } catch {
                restored = false
            }
            await refresh()
            throw ContainerCLIError(exitCode: 1, message: restored
                ? "Couldn't create the updated container: \(createError.localizedDescription) The previous container was restored."
                : "Couldn't create the updated container: \(createError.localizedDescription) Restoring the previous container also failed — run it again manually from its image.")
        }
        if wasRunning {
            onPhase(.startingContainer)
            let process = try await client.bootstrap(id: id, stdio: [nil, nil, nil])
            try await process.start()
        }
        await refresh()
        return RecreateResult(wasRunning: wasRunning, didPull: didPull,
                              oldImageDigest: originalConfig.image.digest, newImageDigest: image.digest)
    }

    func reclaimOrphanedImageBlobsImpl() async throws -> UInt64 {
        // A same-tag re-pull *replaces* the reference in the image store, so there's no dangling
        // image row to delete — the old version is just unreferenced blobs, and this is blob GC
        // (the same call pruneImages finishes with), not an image delete.
        let (_, blobBytes) = try await ClientImage.cleanUpOrphanedBlobs()
        await refresh()
        try? await fetchDiskUsage()
        return blobBytes
    }

    private nonisolated static let pushOperationTracker = PushOperationTracker()

    func pushImageImpl(reference: String, destination: String?, platform: String?, insecure: Bool, progress: ProgressUpdateHandler?) async throws {
        let config = await resolvedSystemConfig()
        let ociPlatform: Platform? = try {
            guard let p = platform, !p.isEmpty else { return nil }
            return try Platform(from: p)
        }()
        var image = try await ClientImage.get(reference: reference, containerSystemConfig: config)
        // Retag onto the registry-qualified destination first (push needs a host in the reference).
        // A no-op when the destination matches the source, e.g. re-pushing an already-qualified name.
        if let destination, !destination.isEmpty, destination != reference {
            image = try await image.tag(new: destination)
        }
        // Raced against a stall watchdog via `raceAgainstStall` (NOT a plain `withThrowingTaskGroup`
        // — see PushStallGuard.swift's doc comment: that implicitly awaits every child before
        // returning, which hangs forever if the XPC push call itself ignores cancellation). The
        // vendored registry client's Bearer retry is still uncapped in containerization 0.54.0 (see
        // `PushStallMonitor`), so without this a stuck auth loop hangs the call and the UI.
        let stallMonitor = PushStallMonitor()
        let watchedProgress: ProgressUpdateHandler = { events in
            // Only genuine completion events arm the watchdog — see `containsRealProgress`'s doc
            // comment for why a planning-only event (total item/byte counts) must not count.
            if containsRealProgress(events) {
                await stallMonitor.markProgress()
            }
            await progress?(events)
        }
        // `raceAgainstStall`'s operation runs on a separate, concurrently-executing Task — capture
        // an immutable snapshot of the (possibly just-retagged) image rather than the `var`.
        let imageToPush = image
        let pushDestination = destination ?? reference
        guard await Self.pushOperationTracker.begin(pushDestination) else {
            throw PushAlreadyInProgressError(destination: pushDestination)
        }
        try await raceAgainstStall(timeout: .seconds(60), monitor: stallMonitor) {
            do {
                try await imageToPush.push(
                    platform: ociPlatform,
                    scheme: RegistrySchemeResolver.scheme(
                        forReference: pushDestination, insecure: insecure, internalDnsDomain: config.dns.domain
                    ),
                    containerSystemConfig: config,
                    progressUpdate: watchedProgress
                )
                await Self.pushOperationTracker.finish(pushDestination)
            } catch {
                await Self.pushOperationTracker.finish(pushDestination)
                throw error
            }
        }
        if insecure, let host = ImageStaleness.registryHost(for: destination ?? reference) {
            Self.rememberInsecureHost(host)
        }
        // A retag created a new local reference — surface it in the list.
        await refresh()
    }

    func tagImageImpl(reference: String, newReference: String) async throws -> String {
        let config = await resolvedSystemConfig()
        let existing = try await ClientImage.get(reference: reference, containerSystemConfig: config)
        // The same normalization the CLI's `image tag` applies (default registry host, `library/`,
        // `:latest`) — without it the daemon stores the raw string and `image ls` shows a name
        // that doesn't round-trip through pull/push.
        let target = try ClientImage.normalizeReference(newReference, containerSystemConfig: config)
        _ = try await existing.tag(new: target)
        await refresh()
        return target
    }

    func saveImagesImpl(references: [String], to path: String, platform: String?) async throws {
        let config = await resolvedSystemConfig()
        let ociPlatform: Platform? = try {
            guard let p = platform, !p.isEmpty else { return nil }
            return try Platform(from: p)
        }()
        do {
            try await ClientImage.save(references: references, out: path, platform: ociPlatform, containerSystemConfig: config)
        } catch {
            // A failed save can leave a partial tar behind — nobody can load it, so don't leave it
            // sitting where the user asked for a good one.
            try? FileManager.default.removeItem(atPath: path)
            throw error
        }
    }

    func loadImagesImpl(from path: String, force: Bool, progress: ProgressUpdateHandler?) async throws -> ImageLoadSummary {
        let result = try await ClientImage.load(from: path, force: force)
        // Unpack like pull does (and like the CLI's `image load`) — a loaded-but-unpacked image
        // can't start a container.
        for image in result.images {
            try await image.unpack(platform: nil, progressUpdate: progress)
        }
        await refresh()
        return ImageLoadSummary(
            loadedReferences: result.images.map(\.reference),
            rejectedMembers: result.rejectedMembers
        )
    }
}
