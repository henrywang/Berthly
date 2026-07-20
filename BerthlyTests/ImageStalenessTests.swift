// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerizationOCI
import ContainerResource
import Foundation
import Testing
@testable import Berthly

struct ImageStalenessTests {

    private func image(
        id: String, digest: String = "sha256:aaa", source: ImageSource = .pulled,
        usage: ImageUsage = .unused
    ) -> ContainerImage {
        let base = id.firstIndex(of: "@").map { String(id[id.startIndex ..< $0]) } ?? id
        let colon = base.lastIndex(of: ":")
        let repo = colon.map { String(base[base.startIndex ..< $0]) } ?? base
        let tag = colon.map { String(base[base.index(after: $0)...]) } ?? "latest"
        return ContainerImage(id: id, repository: repo, tag: tag, digest: digest,
                              arch: ["arm64"], sizeBytes: 0, created: "-", source: source, usage: usage)
    }

    // MARK: - eligibleReferences

    @Test func eligibilityRequiresRegistryDomainTagAndPulledSource() {
        let images = [
            image(id: "docker.io/library/nginx:latest"),
            image(id: "ghcr.io/acme/api:2.1"),
            image(id: "local/web:1.4"),                                // no registry domain
            image(id: "docker.io/library/redis@sha256:\(String(repeating: "b", count: 64))"), // digest-pinned
            image(id: "docker.io/acme/tool:1.0", source: .built),      // built locally
            image(id: "ghcr.io/acme/buildkit:0.13", usage: .builderImage) // infra
        ]
        #expect(ImageStaleness.eligibleReferences(images: images)
                == ["docker.io/library/nginx:latest", "ghcr.io/acme/api:2.1"])
    }

    @Test func eligibilityDedupesPreservingOrder() {
        let images = [
            image(id: "ghcr.io/acme/api:2.1"),
            image(id: "docker.io/library/nginx:latest"),
            image(id: "ghcr.io/acme/api:2.1")
        ]
        #expect(ImageStaleness.eligibleReferences(images: images)
                == ["ghcr.io/acme/api:2.1", "docker.io/library/nginx:latest"])
    }

    // MARK: - comparableLocalDigest (indirect-index unwrap)

    private func descriptor(_ digest: String) -> Descriptor {
        Descriptor(mediaType: MediaTypes.imageManifest, digest: digest, size: 1)
    }

    @Test func directIndexComparesByOwnDigest() {
        let index = Index(manifests: [descriptor("sha256:inner")])
        #expect(ImageStaleness.comparableLocalDigest(ownDigest: "sha256:own", index: index) == "sha256:own")
    }

    @Test func indirectIndexUnwrapsToWrappedManifestDigest() {
        for flag in ["true", "1", "True"] {
            let index = Index(manifests: [descriptor("sha256:inner")],
                              annotations: [AnnotationKeys.containerizationIndexIndirect: flag])
            #expect(ImageStaleness.comparableLocalDigest(ownDigest: "sha256:own", index: index) == "sha256:inner")
        }
    }

    @Test func indirectIndexWithoutManifestsFallsBackToOwnDigest() {
        let index = Index(manifests: [],
                          annotations: [AnnotationKeys.containerizationIndexIndirect: "true"])
        #expect(ImageStaleness.comparableLocalDigest(ownDigest: "sha256:own", index: index) == "sha256:own")
    }

    // MARK: - availability

    @Test func availabilityUnknownWithoutCheckInfo() {
        #expect(ImageStaleness.availability(image: image(id: "a:1"), info: nil) == .unknown)
    }

    @Test func availabilityReflectsCheckResult() {
        let img = image(id: "a:1", digest: "sha256:aaa")
        let stale = ImageUpdateInfo(remoteDigest: "sha256:new", localImageDigest: "sha256:aaa",
                                    isUpdateAvailable: true, checkedAt: .now)
        let fresh = ImageUpdateInfo(remoteDigest: "sha256:aaa", localImageDigest: "sha256:aaa",
                                    isUpdateAvailable: false, checkedAt: .now)
        #expect(ImageStaleness.availability(image: img, info: stale) == .updateAvailable)
        #expect(ImageStaleness.availability(image: img, info: fresh) == .upToDate)
    }

    @Test func availabilityInvalidatedWhenImagePulledSinceCheck() {
        // The check ran against sha256:aaa; the user has since pulled and the image is now
        // sha256:new — the stored verdict describes bytes that no longer exist locally.
        let img = image(id: "a:1", digest: "sha256:new")
        let info = ImageUpdateInfo(remoteDigest: "sha256:new", localImageDigest: "sha256:aaa",
                                   isUpdateAvailable: true, checkedAt: .now)
        #expect(ImageStaleness.availability(image: img, info: info) == .unknown)
    }

    // MARK: - container staleness

    @Test func stalenessCurrentWhenDigestsMatchAndNoUpdate() {
        let img = image(id: "ghcr.io/acme/api:2.1", digest: "sha256:aaa")
        #expect(ImageStaleness.staleness(containerImageRef: "ghcr.io/acme/api:2.1",
                                         containerImageDigest: "sha256:aaa",
                                         images: [img], updateInfo: [:]) == .current)
    }

    @Test func stalenessLocalImageNewerWhenPinnedDigestLags() {
        let img = image(id: "ghcr.io/acme/api:2.1", digest: "sha256:new")
        #expect(ImageStaleness.staleness(containerImageRef: "ghcr.io/acme/api:2.1",
                                         containerImageDigest: "sha256:old",
                                         images: [img], updateInfo: [:]) == .localImageNewer)
    }

    @Test func stalenessDriftBeatsRemoteUpdate() {
        let img = image(id: "ghcr.io/acme/api:2.1", digest: "sha256:new")
        let info = ImageUpdateInfo(remoteDigest: "sha256:newest", localImageDigest: "sha256:new",
                                   isUpdateAvailable: true, checkedAt: .now)
        #expect(ImageStaleness.staleness(containerImageRef: "ghcr.io/acme/api:2.1",
                                         containerImageDigest: "sha256:old",
                                         images: [img], updateInfo: [img.id: info]) == .localImageNewer)
    }

    @Test func stalenessRemoteUpdateWhenPinnedMatchesLocal() {
        let img = image(id: "ghcr.io/acme/api:2.1", digest: "sha256:aaa")
        let info = ImageUpdateInfo(remoteDigest: "sha256:new", localImageDigest: "sha256:aaa",
                                   isUpdateAvailable: true, checkedAt: .now)
        #expect(ImageStaleness.staleness(containerImageRef: "ghcr.io/acme/api:2.1",
                                         containerImageDigest: "sha256:aaa",
                                         images: [img], updateInfo: [img.id: info]) == .remoteUpdateAvailable)
    }

    @Test func stalenessMatchesByFullNameLikeUsageResolver() {
        // Container refs match id, fullName, or digest — same rule as ContainerImage.resolvingUsage.
        let img = image(id: "ghcr.io/acme/api:2.1", digest: "sha256:new")
        #expect(ImageStaleness.staleness(containerImageRef: img.fullName,
                                         containerImageDigest: "sha256:old",
                                         images: [img], updateInfo: [:]) == .localImageNewer)
    }

    @Test func stalenessCurrentForUnknownImageOrNilDigest() {
        let img = image(id: "ghcr.io/acme/api:2.1", digest: "sha256:aaa")
        #expect(ImageStaleness.staleness(containerImageRef: "gone:1",
                                         containerImageDigest: "sha256:old",
                                         images: [img], updateInfo: [:]) == .current)
        #expect(ImageStaleness.staleness(containerImageRef: "ghcr.io/acme/api:2.1",
                                         containerImageDigest: nil,
                                         images: [img], updateInfo: [:]) == .current)
        // Even with a known remote update: an unpinned container may already run the remote
        // digest, so no stale verdict of either kind is justified.
        let info = ImageUpdateInfo(remoteDigest: "sha256:new", localImageDigest: "sha256:aaa",
                                   isUpdateAvailable: true, checkedAt: .now)
        #expect(ImageStaleness.staleness(containerImageRef: "ghcr.io/acme/api:2.1",
                                         containerImageDigest: nil,
                                         images: [img], updateInfo: [img.id: info]) == .current)
    }

    // MARK: - insecure-host memory

    @Test func registryHostCanonicalizesCase() {
        #expect(ImageStaleness.registryHost(for: "GHCR.io/acme/api:2.1") == "ghcr.io")
        #expect(ImageStaleness.registryHost(for: "LOCALHOST:18583/berthly-e2e/watchtower:latest") == "localhost:18583")
    }

    @Test func registryHostNilForATrailingDotDomain() {
        // Reference.parse itself rejects a domain with a trailing dot (the domain regex
        // requires a non-empty final label after each "."), so this never reaches
        // registryHost's own folding logic — trailing-dot trimming only matters for
        // foldedBareHost, which skips Reference.parse entirely. Documented here, not just
        // assumed, so a future change to either function doesn't silently break this.
        #expect(ImageStaleness.registryHost(for: "ghcr.io./acme/api:2.1") == nil)
    }

    @Test func registryHostNilForDomainlessOrDockerHubAlias() {
        #expect(ImageStaleness.registryHost(for: "local/web:1.4") == nil)
        #expect(ImageStaleness.registryHost(for: "docker.io/library/nginx:latest") == "registry-1.docker.io")
    }

    @Test func foldedBareHostDoesNotRequireAPath() {
        // signInRegistry's `host` is already an isolated bare host, never a full reference —
        // Reference.parse would misread "localhost:18581" (no slash) as an image:tag pair with
        // no domain at all, so this must NOT go through registryHost(for:).
        #expect(ImageStaleness.foldedBareHost("LOCALHOST:18581") == "localhost:18581")
        #expect(ImageStaleness.foldedBareHost("ghcr.io.") == "ghcr.io")
    }

    @Test func addingInsecureHostDedupesAndSorts() {
        #expect(ImageStaleness.addingInsecureHost("localhost:18581", to: []) == ["localhost:18581"])
        #expect(ImageStaleness.addingInsecureHost("localhost:18581", to: ["localhost:18581"]) == ["localhost:18581"])
        #expect(ImageStaleness.addingInsecureHost("a.example.com", to: ["z.example.com"])
                == ["a.example.com", "z.example.com"])
    }

    @Test func isHostInsecureMatchesCanonicalizedMembership() {
        let known = ["localhost:18581"]
        #expect(ImageStaleness.isHostInsecure(reference: "LOCALHOST:18581/berthly-e2e/x:1", knownInsecureHosts: known))
        #expect(!ImageStaleness.isHostInsecure(reference: "ghcr.io/acme/api:2.1", knownInsecureHosts: known))
        #expect(!ImageStaleness.isHostInsecure(reference: "local/web:1.4", knownInsecureHosts: known))
    }

    // MARK: - check cadence

    @Test func automaticCheckEnabledDefaultsOnWhenUnsetOrWrongType() {
        #expect(ImageStaleness.automaticCheckEnabled(userDefaultValue: nil))
        #expect(ImageStaleness.automaticCheckEnabled(userDefaultValue: "not a bool"))
        #expect(ImageStaleness.automaticCheckEnabled(userDefaultValue: true))
        #expect(!ImageStaleness.automaticCheckEnabled(userDefaultValue: false))
    }

    @Test func checkDueOnFirstRunAndAfterInterval() {
        let now = Date()
        #expect(ImageStaleness.isCheckDue(lastCheck: nil, now: now))
        #expect(ImageStaleness.isCheckDue(lastCheck: now.addingTimeInterval(-7 * 3600), now: now))
        #expect(!ImageStaleness.isCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now))
    }

    // MARK: - mock fixtures

    @MainActor @Test func mockFixturesSeedBothStalenessCases() {
        let mock = MockContainerService()
        let sandbox = mock.containers.first { $0.name == "sandbox" }
        let datastore = mock.containers.first { $0.name == "datastore" }
        let web = mock.containers.first { $0.name == "web-frontend" }
        #expect(sandbox.map(mock.staleness(of:)) == .remoteUpdateAvailable)
        #expect(datastore.map(mock.staleness(of:)) == .localImageNewer)
        #expect(web.map(mock.staleness(of:)) == .current, "unseeded fixtures must stay badge-free")
    }

    // MARK: - recreated configuration

    @Test func recreatedConfigurationSwapsOnlyTheImageDescriptor() {
        let process = ProcessConfiguration(executable: "/bin/server", arguments: ["--port", "8080"],
                                           environment: ["MODE=prod"], workingDirectory: "/srv",
                                           terminal: false, user: .id(uid: 0, gid: 0))
        var config = ContainerConfiguration(
            id: "api",
            image: ImageDescription(reference: "ghcr.io/acme/api:2.1", descriptor: descriptor("sha256:old")),
            process: process
        )
        config.labels = ["app": "api"]
        config.mounts = [Filesystem(type: .tmpfs, source: "", destination: "/run", options: [])]

        let recreated = LiveContainerService.recreatedConfiguration(from: config,
                                                                    imageDescriptor: descriptor("sha256:new"))

        #expect(recreated.image.digest == "sha256:new")
        #expect(recreated.image.reference == "ghcr.io/acme/api:2.1", "tag reference must survive the swap")
        #expect(recreated.id == config.id)
        #expect(recreated.labels == config.labels)
        #expect(recreated.mounts.map(\.destination) == ["/run"])
        #expect(recreated.initProcess.executable == "/bin/server")
    }

    // MARK: - mock recreate

    @MainActor @Test func mockRecreatePreservesRunStateAndClearsStaleness() async throws {
        let mock = MockContainerService()
        let datastore = try #require(mock.containers.first { $0.name == "datastore" })
        #expect(mock.staleness(of: datastore) == .localImageNewer)

        var phases: [RecreatePhase] = []
        let result = try await mock.recreateContainer(datastore.id, pullFirst: false) { phases.append($0) }

        let recreated = try #require(mock.containers.first { $0.name == "datastore" })
        #expect(recreated.status == .running, "a running container must come back running")
        #expect(mock.staleness(of: recreated) == .current)
        #expect(result.wasRunning && !result.didPull)
        #expect(result.oldImageReclaimable, "digest moved, so the old bytes are reclaimable")
        #expect(phases == [.stoppingContainer, .deletingContainer, .creatingContainer, .startingContainer])
    }

    @MainActor @Test func mockRecreatePullsWhenRemoteUpdateSeeded() async throws {
        let mock = MockContainerService()
        let sandbox = try #require(mock.containers.first { $0.name == "sandbox" })
        #expect(mock.staleness(of: sandbox) == .remoteUpdateAvailable)

        var phases: [RecreatePhase] = []
        let result = try await mock.recreateContainer(sandbox.id, pullFirst: true) { phases.append($0) }

        let recreated = try #require(mock.containers.first { $0.name == "sandbox" })
        #expect(result.didPull && !result.wasRunning)
        #expect(recreated.status == .stopped, "a non-running container must not be started by recreate")
        #expect(recreated.imageDigest == "sha256:feed5eed01", "container must pin the freshly pulled digest")
        #expect(mock.staleness(of: recreated) == .current)
        #expect(phases.first == .pullingImage)
        #expect(!phases.contains(.startingContainer))
    }

    // MARK: - recreate result

    @Test func recreateResultReclaimableOnlyWhenDigestMoved() {
        let moved = RecreateResult(wasRunning: true, didPull: true,
                                   oldImageDigest: "sha256:old", newImageDigest: "sha256:new")
        let same = RecreateResult(wasRunning: true, didPull: true,
                                  oldImageDigest: "sha256:same", newImageDigest: "sha256:same")
        #expect(moved.oldImageReclaimable)
        #expect(!same.oldImageReclaimable)
    }
}
