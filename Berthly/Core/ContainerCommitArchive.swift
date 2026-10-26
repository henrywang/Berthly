// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerResource
import ContainerizationArchive
import ContainerizationOCI
import Foundation

/// Wraps an exported container rootfs in a single-layer OCI image archive that `image load`
/// accepts — the `container commit` path (container 1.6.0, apple/container#1762). A port of the
/// CLI's `OCIImageArchive`, which lives in the unlinked `ContainerCommands` target. Takes the
/// snapshot's fields rather than a `ContainerSnapshot` so it can be tested without a daemon.
nonisolated enum ContainerCommitArchive {
    /// The committed image runs what the container ran: its init process becomes the
    /// entrypoint/cmd, and its labels override the source image's on conflict.
    static func imageConfig(
        process: ProcessConfiguration,
        containerLabels: [String: String],
        stopSignal: String?,
        sourceImage: Image
    ) -> ImageConfig {
        var labels = sourceImage.config?.labels ?? [:]
        labels.merge(containerLabels) { _, containerValue in containerValue }
        return ImageConfig(
            user: process.user.description,
            env: process.environment,
            entrypoint: [process.executable],
            cmd: process.arguments,
            workingDir: process.workingDirectory,
            labels: labels,
            stopSignal: stopSignal
        )
    }

    static func create(
        from rootfsArchive: URL,
        in temporaryDirectory: URL,
        reference: String,
        platform: Platform,
        imageConfig: ImageConfig,
        sourceImage: Image,
        now: Date = Date()
    ) throws -> URL {
        let layoutDirectory = temporaryDirectory.appendingPathComponent("oci-layout")
        let blobsDirectory = layoutDirectory.appendingPathComponent("blobs/sha256")
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)
        let contentWriter = try ContentWriter(for: blobsDirectory)

        var result = try contentWriter.create(from: rootfsArchive)
        let layerDescriptor = Descriptor(mediaType: MediaTypes.imageLayer, digest: result.digest.digestString, size: result.size)
        let created = ISO8601DateFormatter().string(from: now)
        let config = Image(
            created: created,
            author: sourceImage.author,
            architecture: platform.architecture,
            os: platform.os,
            osVersion: sourceImage.osVersion,
            osFeatures: sourceImage.osFeatures,
            variant: platform.variant,
            config: imageConfig,
            rootfs: Rootfs(type: "layers", diffIDs: [layerDescriptor.digest]),
            history: [History(created: created, createdBy: "container commit")]
        )
        result = try contentWriter.create(from: config)
        let configDescriptor = Descriptor(mediaType: MediaTypes.imageConfig, digest: result.digest.digestString, size: result.size)

        let manifest = Manifest(config: configDescriptor, layers: [layerDescriptor])
        result = try contentWriter.create(from: manifest)
        var manifestDescriptor = Descriptor(mediaType: MediaTypes.imageManifest, digest: result.digest.digestString, size: result.size)
        manifestDescriptor.annotations = [
            "org.opencontainers.image.ref.name": reference,
            "io.containerd.image.name": reference,
            "com.apple.containerization.image.name": reference
        ]
        manifestDescriptor.platform = platform

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        try encoder.encode(["imageLayoutVersion": "1.0.0"])
            .write(to: layoutDirectory.appendingPathComponent("oci-layout"), options: .atomic)
        try encoder.encode(Index(schemaVersion: 2, manifests: [manifestDescriptor]))
            .write(to: layoutDirectory.appendingPathComponent("index.json"), options: .atomic)

        let imageArchive = temporaryDirectory.appendingPathComponent("image.tar")
        let archiveWriter = try ArchiveWriter(format: .pax, filter: .none, file: imageArchive)
        try archiveWriter.archiveDirectory(layoutDirectory)
        try archiveWriter.finishEncoding()
        return imageArchive
    }
}
