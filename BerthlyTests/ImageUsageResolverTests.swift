// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Foundation
import Testing
@testable import Berthly

@MainActor
struct ImageUsageResolverTests {

    private func makeImage(id: String = "local/web:1.4", repository: String = "local/web",
                            tag: String = "1.4", digest: String = "sha256:abc") -> ContainerImage {
        ContainerImage(id: id, repository: repository, tag: tag, digest: digest, arch: ["arm64"],
                        sizeBytes: 100, created: "–", source: .pulled, usage: .unused)
    }

    private func makeContainer(name: String = "web", image: String) -> Container {
        Container(id: name, name: name, image: image, status: .running, ports: [],
                  cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "–",
                  uptime: "–", command: "", mounts: [], networks: [], environment: [])
    }

    private func makeMachine(name: String = "vm", image: String) -> Machine {
        Machine(id: name, name: name, image: image, status: .running, isUtility: false,
                diskUsedGB: 0, diskTotalGB: 0, uptimeString: "–", kernel: "–", resources: "–",
                created: "–", homeMount: .none)
    }

    @Test func unreferencedImageIsUnused() {
        let resolved = ContainerImage.resolvingUsage([makeImage()], containers: [], machines: [])
        guard case .unused = resolved[0].usage else { Issue.record("expected .unused"); return }
    }

    @Test func containerReferencingByRepoTagMarksUsed() {
        let resolved = ContainerImage.resolvingUsage(
            [makeImage()], containers: [makeContainer(image: "local/web:1.4")], machines: []
        )
        guard case .usedBy(let n) = resolved[0].usage else { Issue.record("expected .usedBy"); return }
        #expect(n == 1)
    }

    @Test func machineReferencingWithDigestSuffixMarksUsed() {
        // Machine.image isn't pre-stripped of a trailing @digest the way Container.image is.
        let resolved = ContainerImage.resolvingUsage(
            [makeImage()], containers: [], machines: [makeMachine(image: "local/web:1.4@sha256:deadbeef")]
        )
        guard case .usedBy(let n) = resolved[0].usage else { Issue.record("expected .usedBy"); return }
        #expect(n == 1)
    }

    @Test func multipleReferencesAreCounted() {
        let resolved = ContainerImage.resolvingUsage(
            [makeImage()],
            containers: [makeContainer(name: "web", image: "local/web:1.4"),
                         makeContainer(name: "worker", image: "local/web:1.4")],
            machines: [makeMachine(image: "local/web:1.4")]
        )
        guard case .usedBy(let n) = resolved[0].usage else { Issue.record("expected .usedBy"); return }
        #expect(n == 3)
    }

    @Test func referenceToADifferentImageIsIgnored() {
        let resolved = ContainerImage.resolvingUsage(
            [makeImage()], containers: [makeContainer(image: "local/other:2.0")], machines: []
        )
        guard case .unused = resolved[0].usage else { Issue.record("expected .unused"); return }
    }

    // MARK: diskUsage

    private func makeSizedImage(id: String, digest: String, sizeBytes: Int64,
                                usage: ImageUsage) -> ContainerImage {
        ContainerImage(id: id, repository: id, tag: "latest", digest: digest, arch: ["arm64"],
                       sizeBytes: sizeBytes, created: "–", source: .pulled, usage: usage)
    }

    @Test func diskUsageSumsDistinctDigests() {
        let usage = ContainerImage.diskUsage(of: [
            makeSizedImage(id: "a", digest: "sha256:a", sizeBytes: 100, usage: .usedBy(1)),
            makeSizedImage(id: "b", digest: "sha256:b", sizeBytes: 250, usage: .unused),
        ])
        #expect(usage.totalBytes == 350)
        #expect(usage.reclaimableBytes == 250)
    }

    @Test func diskUsageCountsRetaggedContentOnce() {
        // Two names for the same digest are one copy on disk, not two.
        let usage = ContainerImage.diskUsage(of: [
            makeSizedImage(id: "a", digest: "sha256:same", sizeBytes: 100, usage: .unused),
            makeSizedImage(id: "b", digest: "sha256:same", sizeBytes: 100, usage: .unused),
        ])
        #expect(usage.totalBytes == 100)
        #expect(usage.reclaimableBytes == 100)
    }

    @Test func sharedDigestWithAnyUsedNameIsNotReclaimable() {
        // Deleting the unused tag frees nothing while another name still references the bytes.
        let usage = ContainerImage.diskUsage(of: [
            makeSizedImage(id: "a", digest: "sha256:same", sizeBytes: 100, usage: .usedBy(2)),
            makeSizedImage(id: "b", digest: "sha256:same", sizeBytes: 100, usage: .unused),
        ])
        #expect(usage.totalBytes == 100)
        #expect(usage.reclaimableBytes == 0)
    }

    @Test func builderImageIsNotReclaimable() {
        let usage = ContainerImage.diskUsage(of: [
            makeSizedImage(id: "builder", digest: "sha256:builder", sizeBytes: 500, usage: .builderImage),
        ])
        #expect(usage.totalBytes == 500)
        #expect(usage.reclaimableBytes == 0)
    }

    @Test func diskUsageOfEmptyListIsZero() {
        let usage = ContainerImage.diskUsage(of: [])
        #expect(usage.totalBytes == 0)
        #expect(usage.reclaimableBytes == 0)
    }

    @Test func preservesAllOtherImageFields() {
        let original = makeImage()
        let resolved = ContainerImage.resolvingUsage([original], containers: [], machines: [])[0]
        #expect(resolved.id == original.id)
        #expect(resolved.repository == original.repository)
        #expect(resolved.tag == original.tag)
        #expect(resolved.digest == original.digest)
        #expect(resolved.arch == original.arch)
        #expect(resolved.sizeBytes == original.sizeBytes)
        #expect(resolved.created == original.created)
        #expect(resolved.source == original.source)
    }
}
