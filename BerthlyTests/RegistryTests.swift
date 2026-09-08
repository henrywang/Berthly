// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import Testing
@testable import Berthly

struct MapRegistriesTests {

    @Test func mapsEachKeychainEntryToASignedInRow() {
        let registries = LiveContainerService.mapRegistries(keychainEntries: [
            (hostname: "ghcr.io", username: "apple-bot"),
            (hostname: "registry-1.docker.io", username: "berthly")
        ])
        #expect(registries.count == 2)
        #expect(registries.first { $0.host == "ghcr.io" }?.username == "apple-bot")
        #expect(registries.first { $0.host == "registry-1.docker.io" }?.username == "berthly")
    }

    @Test func showsHostsVerbatimWithoutUnresolvingDockerAlias() {
        // `container registry list` prints the raw stored hostname — a Docker Hub login shows as
        // `registry-1.docker.io`, not prettified back to `docker.io`. Berthly matches that.
        let registries = LiveContainerService.mapRegistries(keychainEntries: [
            (hostname: "registry-1.docker.io", username: "berthly")
        ])
        #expect(registries.first?.host == "registry-1.docker.io")
    }

    @Test func sortsByHostForStableOrder() {
        let registries = LiveContainerService.mapRegistries(keychainEntries: [
            (hostname: "quay.io", username: "a"),
            (hostname: "ghcr.io", username: "b"),
            (hostname: "docker.io", username: "c")
        ])
        #expect(registries.map(\.host) == ["docker.io", "ghcr.io", "quay.io"])
    }

    @Test func emptyKeychainProducesNoRegistries() {
        #expect(LiveContainerService.mapRegistries(keychainEntries: []).isEmpty)
    }
}

struct ResolveRegistryConnectionTargetTests {

    @Test func splitsHostPortIntoBareHostAndExplicitPort() throws {
        // A local test registry — the case the host-only RegistryClient initializer used to mishandle.
        let target = try LiveContainerService.resolveRegistryConnectionTarget(
            host: "localhost:18581", insecure: true, internalDnsDomain: nil
        )
        #expect(target.scheme == .http)
        #expect(target.host == "localhost")
        #expect(target.port == 18581)
    }

    @Test func insecureForcesHTTPRegardlessOfHost() throws {
        // The insecure toggle forces HTTP explicitly even for a public host, same as the
        // Push/Pull sheets.
        let target = try LiveContainerService.resolveRegistryConnectionTarget(
            host: "ghcr.io", insecure: true, internalDnsDomain: nil
        )
        #expect(target.scheme == .http)
        #expect(target.host == "ghcr.io")
        #expect(target.port == nil)
    }

    @Test func publicHostWithoutInsecureResolvesHTTPS() throws {
        let target = try LiveContainerService.resolveRegistryConnectionTarget(
            host: "ghcr.io", insecure: false, internalDnsDomain: nil
        )
        #expect(target.scheme == .https)
        #expect(target.port == nil)
    }

    @Test func bareLocalhostAutoDetectsHTTPWithoutTheInsecureToggle() throws {
        // `RegistrySchemeResolver` treats an exact "localhost" as an internal host — a verbatim
        // port of the detection apple/container removed in 1.3.0 (apple/container#2100) — so the
        // toggle isn't the only way to reach HTTP.
        let target = try LiveContainerService.resolveRegistryConnectionTarget(
            host: "localhost", insecure: false, internalDnsDomain: nil
        )
        #expect(target.scheme == .http)
        #expect(target.host == "localhost")
        #expect(target.port == nil)
    }
}

struct RegistryOperationErrorTests {

    @Test func messageNamesHostAndCLILogoutCommand() {
        let error = RegistryOperationError(host: "ghcr.io")
        #expect(error.errorDescription?.contains("ghcr.io") == true)
        #expect(error.errorDescription?.contains("container registry logout ghcr.io") == true)
    }
}

struct InsecureRegistryAuthMessageTests {

    @Test func namesTheHostAndExplainsTheHTTPSRequirement() {
        let message = LiveContainerService.insecureRegistryAuthMessage(host: "registry.lan")
        #expect(message.contains("registry.lan"))
        #expect(message.contains("HTTPS"))
        #expect(message.contains("1.3.1"))
    }
}

@MainActor
struct RegistryMockTests {

    @Test func signInAppendsNewRegistry() async throws {
        let mock = MockContainerService()
        try await mock.signInRegistry(host: "quay.io", username: "me", password: "tok")
        #expect(mock.registries.contains { $0.host == "quay.io" && $0.username == "me" })
    }

    @Test func signInUpdatesExistingRegistryWithoutDuplicating() async throws {
        let mock = MockContainerService()  // seeds ghcr.io as apple-bot
        try await mock.signInRegistry(host: "ghcr.io", username: "new-user", password: "tok")
        #expect(mock.registries.filter { $0.host == "ghcr.io" }.count == 1)
        #expect(mock.registries.first { $0.host == "ghcr.io" }?.username == "new-user")
    }

    @Test func signOutRemovesRegistry() async throws {
        let mock = MockContainerService()
        try await mock.signOutRegistry(host: "ghcr.io")
        #expect(!mock.registries.contains { $0.host == "ghcr.io" })
    }

    @Test func signInRejectsBlankFields() async {
        let mock = MockContainerService()
        await #expect(throws: (any Error).self) {
            try await mock.signInRegistry(host: "", username: "u", password: "p")
        }
    }
}
