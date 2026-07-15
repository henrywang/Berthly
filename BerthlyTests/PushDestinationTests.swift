// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct PushDestinationTests {

    @Test func explicitHostsAreRecognized() {
        #expect(registryHost(forReference: "docker.io/team/web:1.0") == "docker.io")
        #expect(registryHost(forReference: "ghcr.io/org/app") == "ghcr.io")
        #expect(registryHost(forReference: "registry.example.com/web:latest") == "registry.example.com")
    }

    @Test func hostWithPortIsRecognized() {
        #expect(registryHost(forReference: "registry.local:5000/team/web:1.0") == "registry.local:5000")
        #expect(registryHost(forReference: "localhost:5000/web") == "localhost:5000")
    }

    @Test func localhostWithoutPortIsAHost() {
        #expect(registryHost(forReference: "localhost/web:1.0") == "localhost")
    }

    @Test func shortNamesAndLocalNamesHaveNoHost() {
        // Docker Hub short name: first segment is a namespace, not a host.
        #expect(registryHost(forReference: "user/web:1.4") == nil)
        // Purely local name, no slash at all.
        #expect(registryHost(forReference: "web:1.4") == nil)
        #expect(registryHost(forReference: "local/web:1.4") == nil)
    }

    @Test func surroundingWhitespaceIsIgnored() {
        #expect(registryHost(forReference: "  ghcr.io/org/app  ") == "ghcr.io")
    }
}
