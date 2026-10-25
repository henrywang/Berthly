// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerResource
import Testing
@testable import Berthly

// #207: DNS aliases on network attachments (container 1.6.0, apple/container#2390).
struct NetworkAliasTests {

    private func makeContainer(networks: [String], aliases: [String: [String]] = [:]) -> Container {
        Container(id: "id-web", name: "web", image: "local/web:1", status: .running,
                  ports: [], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "–",
                  uptime: "–", command: "", mounts: [], networks: networks, networkAliases: aliases,
                  environment: [])
    }

    // MARK: NetworkAttachmentSpec

    @Test func aliasesSplitOnCommasAndWhitespace() {
        #expect(NetworkAttachmentSpec.aliases(from: " api.test, gateway.test  .gateway.test,,") ==
                ["api.test", "gateway.test", ".gateway.test"])
        #expect(NetworkAttachmentSpec.aliases(from: "  ").isEmpty)
    }

    @Test func specAppendsOneAliasPropertyPerName() {
        #expect(NetworkAttachmentSpec.spec(network: "default", aliasesText: "") == "default")
        #expect(NetworkAttachmentSpec.spec(network: "backend", aliasesText: "api.test, .api.test") ==
                "backend,alias=api.test,alias=.api.test")
    }

    @Test(arguments: ["", "api.test", "api.test .api.test", "a.b.c, d.e"])
    func acceptsWellFormedAliases(aliases: String) {
        #expect(NetworkAttachmentSpec.validationError(network: "default", aliasesText: aliases) == nil)
    }

    @Test(arguments: ["api-.test", "-api.test", "api..test", "api.test=x"])
    func rejectsMalformedAliasesBeforeSubmit(aliases: String) {
        #expect(NetworkAttachmentSpec.validationError(network: "default", aliasesText: aliases) != nil)
    }

    @Test func parseRoundTripsTheSpec() {
        let parsed = NetworkAttachmentSpec.parse("backend,alias=api.test,alias=.api.test")
        #expect(parsed.network == "backend")
        #expect(parsed.aliases == ["api.test", ".api.test"])
        #expect(NetworkAttachmentSpec.parse("backend").aliases.isEmpty)
    }

    @Test func aliasesByNetworkSkipsNetworksWithoutAliases() {
        #expect(NetworkAttachmentSpec.aliasesByNetwork(["default,alias=api.test", "backend"]) ==
                ["default": ["api.test"]])
    }

    // MARK: Live mapping

    @Test func networkAliasesReadTheConfiguredAttachments() {
        let attachments = [
            AttachmentConfiguration(network: "default", options: AttachmentOptions(
                hostname: "web", aliases: ["api.test", ".api.test"])),
            AttachmentConfiguration(network: "backend", options: AttachmentOptions(hostname: "web"))
        ]
        #expect(LiveContainerService.networkAliases(from: attachments) == ["default": ["api.test", ".api.test"]])
    }

    // MARK: Presentation

    @Test func derivedEndpointsCarryTheContainersAliasesForThatNetwork() {
        let network = Network(id: "default", name: "default", driver: .nat, subnet: "192.168.64.0/24",
                              gateway: "192.168.64.1", isDefault: true, scope: "local", ipv6Enabled: false,
                              egress: "", attachable: true, backend: "vmnet", endpoints: [])
        let container = makeContainer(networks: ["default", "backend"], aliases: ["default": ["api.test"]])
        let endpoints = NetworkPresentation.resolvedEndpoints(for: network, containers: [container])
        #expect(endpoints.map(\.aliases) == [["api.test"]])
    }

    @Test func networksDescriptionListsAliasesPerNetwork() {
        #expect(NetworkPresentation.networksDescription(for: makeContainer(networks: [])) == "–")
        let container = makeContainer(networks: ["default", "backend"],
                                      aliases: ["default": ["api.test", ".api.test"]])
        #expect(NetworkPresentation.networksDescription(for: container) == "default (api.test, .api.test), backend")
    }

    // MARK: Mock

    @MainActor
    @Test func mockStoresAliasesAndKeepsThemAcrossStopAndStart() async throws {
        let mock = MockContainerService()
        try await mock.runContainer(options: RunOptions(
            reference: "local/newapp:1.0", name: "alias-app", networks: ["default,alias=api.test"]
        ))
        #expect(mock.containers.first { $0.id == "alias-app" }?.networks == ["default"])

        try await mock.stopContainer("alias-app")
        try await mock.startContainer("alias-app")
        #expect(mock.containers.first { $0.id == "alias-app" }?.networkAliases == ["default": ["api.test"]])
    }
}
