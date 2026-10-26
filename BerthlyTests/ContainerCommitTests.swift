// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerResource
import ContainerizationArchive
import ContainerizationOCI
import Foundation
import Testing
@testable import Berthly

// #206: `container commit` — the OCI archive port and the mock.
struct ContainerCommitTests {

    private let sourceImage = Image(
        author: "upstream",
        architecture: "arm64", os: "linux",
        config: ImageConfig(labels: ["maintainer": "upstream", "tier": "base"]),
        rootfs: Rootfs(type: "layers", diffIDs: [])
    )

    private let process = ProcessConfiguration(
        executable: "/usr/sbin/nginx",
        arguments: ["-g", "daemon off;"],
        environment: ["PATH=/usr/bin", "MODE=prod"],
        workingDirectory: "/srv",
        user: .raw(userString: "www-data")
    )

    @Test func imageConfigRunsWhatTheContainerRan() {
        let config = ContainerCommitArchive.imageConfig(
            process: process, containerLabels: [:], stopSignal: "SIGQUIT", sourceImage: sourceImage
        )
        #expect(config.entrypoint == ["/usr/sbin/nginx"])
        #expect(config.cmd == ["-g", "daemon off;"])
        #expect(config.env == ["PATH=/usr/bin", "MODE=prod"])
        #expect(config.workingDir == "/srv")
        #expect(config.user == "www-data")
        #expect(config.stopSignal == "SIGQUIT")
    }

    @Test func containerLabelsOverrideTheSourceImagesOnConflict() {
        let config = ContainerCommitArchive.imageConfig(
            process: process, containerLabels: ["tier": "app", "team": "web"], stopSignal: nil, sourceImage: sourceImage
        )
        #expect(config.labels == ["maintainer": "upstream", "tier": "app", "team": "web"])
    }

    @Test func archiveIsAOneLayerOCILayoutNamedForTheReference() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rootfs = dir.appendingPathComponent("rootfs.tar")
        try Data("not really a tar, but bytes to digest".utf8).write(to: rootfs)

        let platform = Platform(arch: "arm64", os: "linux", variant: "v8")
        let archive = try ContainerCommitArchive.create(
            from: rootfs, in: dir, reference: "docker.io/team/web:snapshot", platform: platform,
            imageConfig: ContainerCommitArchive.imageConfig(
                process: process, containerLabels: [:], stopSignal: nil, sourceImage: sourceImage
            ),
            sourceImage: sourceImage
        )

        let reader = try ArchiveReader(file: archive)
        let (_, indexData) = try reader.extractFile(path: "index.json")
        let index = try JSONDecoder().decode(Index.self, from: indexData)
        let manifestDescriptor = try #require(index.manifests.first)
        #expect(index.manifests.count == 1)
        #expect(manifestDescriptor.annotations?["org.opencontainers.image.ref.name"] == "docker.io/team/web:snapshot")
        #expect(manifestDescriptor.annotations?["com.apple.containerization.image.name"] == "docker.io/team/web:snapshot")
        #expect(manifestDescriptor.platform == platform)

        func blob(_ digest: String) throws -> Data {
            try ArchiveReader(file: archive)
                .extractFile(path: "blobs/sha256/\(digest.replacingOccurrences(of: "sha256:", with: ""))").1
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: blob(manifestDescriptor.digest))
        #expect(manifest.layers.count == 1)
        #expect(try blob(manifest.layers[0].digest) == Data(contentsOf: rootfs))

        let config = try JSONDecoder().decode(Image.self, from: blob(manifest.config.digest))
        #expect(config.architecture == "arm64")
        #expect(config.variant == "v8")
        #expect(config.author == "upstream")
        #expect(config.rootfs.diffIDs == [manifest.layers[0].digest])
        #expect(config.config?.entrypoint == ["/usr/sbin/nginx"])
    }

    @MainActor
    @Test func mockCommitAddsTheImageAndReplacesAnExistingName() async throws {
        let mock = MockContainerService()
        let container = try #require(mock.containers.first)
        let countBefore = mock.images.count

        #expect(try await mock.commitContainer(container.id, reference: "team/web:snap") == "team/web:snap")
        #expect(mock.images.count == countBefore + 1)
        _ = try await mock.commitContainer(container.id, reference: "team/web:snap")
        #expect(mock.images.count == countBefore + 1)
        #expect(mock.images.contains { $0.fullName == "team/web:snap" })

        await #expect(throws: (any Error).self) {
            try await mock.commitContainer("no-such-container", reference: "x:y")
        }
    }
}
