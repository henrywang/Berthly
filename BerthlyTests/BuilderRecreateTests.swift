// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerResource
import ContainerizationOCI
import Testing
@testable import Berthly

// #210: when an existing "buildkit" container is reused versus recreated.
struct BuilderRecreateTests {
    private let image = "ghcr.io/apple/container-builder-shim/builder:0.9.0"

    private func existing(image: String? = nil, cpus: Int = 2, memory: UInt64 = 2_147_483_648,
                          ssh: Bool = false, environment: [String] = ["PATH=/usr/bin"]) -> ContainerConfiguration {
        let description = ImageDescription(
            reference: image ?? self.image,
            descriptor: Descriptor(mediaType: MediaTypes.index, digest: "sha256:abc", size: 1)
        )
        var config = ContainerConfiguration(
            id: "buildkit", image: description,
            process: ProcessConfiguration(executable: "/usr/local/bin/container-builder-shim", arguments: [], environment: environment)
        )
        config.resources.cpus = cpus
        config.resources.memoryInBytes = memory
        config.ssh = ssh
        return config
    }

    private var wanted: ContainerConfiguration.Resources {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = 2
        resources.memoryInBytes = 2_147_483_648
        return resources
    }

    @Test func matchingBuilderIsReused() {
        #expect(!LiveContainerService.builderNeedsRecreate(existing(), image: image, resources: wanted, ssh: false))
    }

    @Test(arguments: ["image", "cpus", "memory", "ssh"])
    func anyCreationTimeSettingChangeRecreates(field: String) {
        let config: ContainerConfiguration = switch field {
        case "image": existing(image: "ghcr.io/apple/container-builder-shim/builder:0.8.0")
        case "cpus": existing(cpus: 4)
        case "memory": existing(memory: 4_294_967_296)
        default: existing(ssh: true)
        }
        #expect(LiveContainerService.builderNeedsRecreate(config, image: image, resources: wanted, ssh: false))
    }

    @Test func managedColorEnvDifferencesDoNotRecreate() {
        // Upstream recreates on BUILDKIT_COLORS/NO_COLOR drift; a Finder-launched Berthly never has
        // them, so honoring that would discard the build cache whenever a CLI-made builder is reused.
        let cliMade = existing(environment: ["PATH=/usr/bin", "NO_COLOR=true", "BUILDKIT_COLORS=run=green"])
        #expect(!LiveContainerService.builderNeedsRecreate(cliMade, image: image, resources: wanted, ssh: false))
    }
}
