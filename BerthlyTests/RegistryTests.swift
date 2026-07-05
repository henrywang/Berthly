// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct MapRegistriesTests {

    @Test func mapsEachKeychainEntryToASignedInRow() {
        let registries = LiveContainerService.mapRegistries(keychainEntries: [
            (hostname: "ghcr.io", username: "apple-bot"),
            (hostname: "registry-1.docker.io", username: "berthly"),
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
            (hostname: "docker.io", username: "c"),
        ])
        #expect(registries.map(\.host) == ["docker.io", "ghcr.io", "quay.io"])
    }

    @Test func emptyKeychainProducesNoRegistries() {
        #expect(LiveContainerService.mapRegistries(keychainEntries: []).isEmpty)
    }
}

struct RegistryOperationErrorTests {

    @Test func messageNamesHostAndCLILogoutCommand() {
        let error = RegistryOperationError(host: "ghcr.io")
        #expect(error.errorDescription?.contains("ghcr.io") == true)
        #expect(error.errorDescription?.contains("container registry logout ghcr.io") == true)
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
