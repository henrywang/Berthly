// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import ContainerAPIClient
import Testing
@testable import Berthly

struct RegistrySchemeResolverTests {

    @Test func insecureForcesHTTPRegardlessOfHost() {
        #expect(RegistrySchemeResolver.scheme(forHost: "ghcr.io", insecure: true, internalDnsDomain: nil) == .http)
        #expect(RegistrySchemeResolver.scheme(forReference: "ghcr.io/apple/x:1", insecure: true, internalDnsDomain: nil) == .http)
    }

    @Test func bareLocalhostIsInternal() {
        #expect(RegistrySchemeResolver.scheme(forHost: "localhost", insecure: false, internalDnsDomain: nil) == .http)
    }

    @Test func localhostWithPortIsNotDetected() {
        // A host:port string matches neither "localhost" nor an IPv4 address — same quirk the
        // apple/container heuristic had; such a registry needs the insecure toggle.
        #expect(RegistrySchemeResolver.scheme(forHost: "localhost:5000", insecure: false, internalDnsDomain: nil) == .https)
    }

    @Test func internalDnsDomainSuffixIsInternal() {
        #expect(RegistrySchemeResolver.scheme(forHost: "registry.test", insecure: false, internalDnsDomain: "test") == .http)
        #expect(RegistrySchemeResolver.scheme(forHost: "registry.example.com", insecure: false, internalDnsDomain: "test") == .https)
    }

    @Test func privateIPv4RangesAreInternal() {
        for host in ["10.0.0.1", "10.255.255.255", "127.0.0.1", "192.168.1.10", "172.16.0.1", "172.31.255.255"] {
            #expect(RegistrySchemeResolver.scheme(forHost: host, insecure: false, internalDnsDomain: nil) == .http, "\(host)")
        }
    }

    @Test func publicIPv4AndHostsAreExternal() {
        for host in ["8.8.8.8", "172.32.0.1", "ghcr.io", "registry-1.docker.io"] {
            #expect(RegistrySchemeResolver.scheme(forHost: host, insecure: false, internalDnsDomain: nil) == .https, "\(host)")
        }
    }

    @Test func referenceWithoutRegistryResolvesHTTPS() {
        #expect(RegistrySchemeResolver.scheme(forReference: "alpine:latest", insecure: false, internalDnsDomain: nil) == .https)
    }

    @Test func referenceRegistryHostDrivesDetection() {
        #expect(RegistrySchemeResolver.scheme(forReference: "10.1.2.3:5000/team/app:1", insecure: false, internalDnsDomain: nil) == .https)
        #expect(RegistrySchemeResolver.scheme(forReference: "reg.lan/team/app:1", insecure: false, internalDnsDomain: "lan") == .http)
        #expect(RegistrySchemeResolver.scheme(forReference: "ghcr.io/apple/x:1", insecure: false, internalDnsDomain: nil) == .https)
    }
}
