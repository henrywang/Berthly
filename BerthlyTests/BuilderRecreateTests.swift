// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerPersistence
import ContainerResource
import ContainerizationOCI
import Testing
@testable import Berthly

// #210: when an existing "buildkit" container is reused versus recreated.
struct BuilderRecreateTests {
    private let image = "ghcr.io/apple/container-builder-shim/builder:0.9.0"
    private let wantedDNS = ContainerConfiguration.DNSConfiguration(nameservers: [])

    private func existing(image: String? = nil, cpus: Int = 2, memory: UInt64 = 2_147_483_648,
                          ssh: Bool = false, environment: [String] = ["PATH=/usr/bin"],
                          dns: ContainerConfiguration.DNSConfiguration? = .init(nameservers: [])) -> ContainerConfiguration {
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
        config.dns = dns
        return config
    }

    private var wanted: ContainerConfiguration.Resources {
        var resources = ContainerConfiguration.Resources()
        resources.cpus = 2
        resources.memoryInBytes = 2_147_483_648
        return resources
    }

    private func needsRecreate(_ config: ContainerConfiguration) -> Bool {
        LiveContainerService.builderNeedsRecreate(config, image: image, resources: wanted, ssh: false, dns: wantedDNS)
    }

    @Test func matchingBuilderIsReused() {
        #expect(!needsRecreate(existing()))
    }

    @Test(arguments: ["image", "cpus", "memory", "ssh"])
    func anyCreationTimeSettingChangeRecreates(field: String) {
        let config: ContainerConfiguration = switch field {
        case "image": existing(image: "ghcr.io/apple/container-builder-shim/builder:0.8.0")
        case "cpus": existing(cpus: 4)
        case "memory": existing(memory: 4_294_967_296)
        default: existing(ssh: true)
        }
        #expect(needsRecreate(config))
    }

    // #233: "nameservers" is also the one-time recreate of builders made before #233, which
    // hard-coded `1.1.1.1`.
    @Test(arguments: ["nameservers", "domain", "searchDomains", "options"])
    func anyDNSFieldChangeRecreates(field: String) {
        let dns: ContainerConfiguration.DNSConfiguration = switch field {
        case "nameservers": .init()
        case "domain": .init(nameservers: [], domain: "test")
        case "searchDomains": .init(nameservers: [], searchDomains: ["corp.example"])
        default: .init(nameservers: [], options: ["ndots:2"])
        }
        #expect(needsRecreate(existing(dns: dns)))
    }

    @Test func builderWithoutDNSIsComparedLikeUpstream() {
        // Upstream's dnsConfigurationChanged treats a missing DNS block as `.init()` (1.1.1.1), so
        // against empty desired nameservers it counts as changed; matching it keeps the CLI and
        // Berthly from recreating each other's builder.
        #expect(needsRecreate(existing(dns: nil)))
    }

    @Test func managedColorEnvDifferencesDoNotRecreate() {
        // Upstream recreates on BUILDKIT_COLORS/NO_COLOR drift; a Finder-launched Berthly never has
        // them, so honoring that would discard the build cache whenever a CLI-made builder is reused.
        let cliMade = existing(environment: ["PATH=/usr/bin", "NO_COLOR=true", "BUILDKIT_COLORS=run=green"])
        #expect(!needsRecreate(cliMade))
    }
}

// #233: the builder's DNS comes from `[container.dns]`, never a hard-coded resolver.
struct BuilderDNSTests {
    @Test func noDefaultsLeavesNameserversToTheGateway() {
        let dns = LiveContainerService.builderDNS(defaults: nil)
        #expect(dns.nameservers.isEmpty)
        #expect(dns.domain == nil)
        #expect(dns.searchDomains.isEmpty)
        #expect(dns.options.isEmpty)
    }

    @Test func configuredDefaultsAreCopiedThrough() {
        let defaults = ContainerDNSConfig(
            domain: "test", nameservers: ["10.0.0.53"], searchDomains: ["corp.example"], options: ["ndots:2"]
        )
        let dns = LiveContainerService.builderDNS(defaults: defaults)
        #expect(dns.nameservers == ["10.0.0.53"])
        #expect(dns.domain == "test")
        #expect(dns.searchDomains == ["corp.example"])
        #expect(dns.options == ["ndots:2"])
    }

    @Test func partialDefaultsKeepTheRestEmpty() {
        let dns = LiveContainerService.builderDNS(defaults: ContainerDNSConfig(searchDomains: ["corp.example"]))
        #expect(dns.nameservers.isEmpty)
        #expect(dns.domain == nil)
        #expect(dns.searchDomains == ["corp.example"])
    }
}
