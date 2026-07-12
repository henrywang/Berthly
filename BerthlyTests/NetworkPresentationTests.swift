// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Testing
@testable import Berthly

struct NetworkPresentationTests {

    private func makeContainer(name: String, status: ContainerStatus, networks: [String]) -> Container {
        Container(id: "id-\(name)", name: name, image: "local/\(name):1", status: status,
                  ports: [], cpuPercent: 0, memoryMB: 0, memoryLimitMB: 0, networkIOString: "–",
                  uptime: "–", command: "", mounts: [], networks: networks, environment: [])
    }

    private func makeNetwork(name: String = "net", driver: NetworkDriver = .nat,
                             egress: String = "", endpoints: [NetworkEndpoint] = []) -> Network {
        Network(id: name, name: name, driver: driver, subnet: "192.168.65.0/24",
                gateway: "192.168.65.1", isDefault: false, scope: "local", ipv6Enabled: false,
                egress: egress, attachable: true, backend: "vmnet", endpoints: endpoints)
    }

    // MARK: resolvedEndpoints

    @Test func reportedEndpointsPassThrough() {
        let endpoint = NetworkEndpoint(id: "e1", name: "web", ipv4: "192.168.65.10",
                                       kind: "CONTAINER", isRunning: true, aliases: ["web"])
        let resolved = NetworkPresentation.resolvedEndpoints(
            for: makeNetwork(endpoints: [endpoint]), containers: [])
        #expect(resolved == [endpoint])
    }

    @Test func attachedContainersAreDerivedWhenNotReported() {
        // The live daemon reports no endpoints — attached containers must still show up.
        let containers = [
            makeContainer(name: "web", status: .running, networks: ["net"]),
            makeContainer(name: "db",  status: .stopped, networks: ["net"]),
            makeContainer(name: "other", status: .running, networks: ["elsewhere"]),
        ]
        let resolved = NetworkPresentation.resolvedEndpoints(for: makeNetwork(), containers: containers)
        #expect(resolved.map(\.name) == ["db", "web"]) // sorted by name
        #expect(resolved.map(\.isRunning) == [false, true])
        #expect(resolved.allSatisfy { $0.kind == "CONTAINER" && $0.ipv4 == "–" })
    }

    @Test func reportedEndpointWinsOverDerivedForSameName() {
        let endpoint = NetworkEndpoint(id: "e1", name: "web", ipv4: "192.168.65.10",
                                       kind: "CONTAINER", isRunning: true, aliases: ["web"])
        let containers = [makeContainer(name: "web", status: .running, networks: ["net"])]
        let resolved = NetworkPresentation.resolvedEndpoints(
            for: makeNetwork(endpoints: [endpoint]), containers: containers)
        #expect(resolved.count == 1)
        #expect(resolved[0].ipv4 == "192.168.65.10")
        #expect(resolved[0].aliases == ["web"])
    }

    @Test func reportedRunningStateRefreshesFromContainerList() {
        // The endpoint snapshot says running, but the container has since stopped.
        let endpoint = NetworkEndpoint(id: "e1", name: "web", ipv4: "192.168.65.10",
                                       kind: "CONTAINER", isRunning: true, aliases: [])
        let containers = [makeContainer(name: "web", status: .stopped, networks: ["net"])]
        let resolved = NetworkPresentation.resolvedEndpoints(
            for: makeNetwork(endpoints: [endpoint]), containers: containers)
        #expect(resolved[0].isRunning == false)
    }

    @Test func machineEndpointKeepsItsStateWithoutAMatchingContainer() {
        let endpoint = NetworkEndpoint(id: "e1", name: "dev", ipv4: "192.168.64.3",
                                       kind: "MACHINE", isRunning: true, aliases: ["machine"])
        let resolved = NetworkPresentation.resolvedEndpoints(
            for: makeNetwork(endpoints: [endpoint]), containers: [])
        #expect(resolved[0].isRunning == true)
    }

    // MARK: endpointSummary

    @Test func endpointSummaryPluralizes() {
        #expect(NetworkPresentation.endpointSummary(count: 0) == "no endpoints")
        #expect(NetworkPresentation.endpointSummary(count: 1) == "1 endpoint")
        #expect(NetworkPresentation.endpointSummary(count: 3) == "3 endpoints")
    }

    // MARK: egress

    @Test func hostOnlyEgressIsIsolatedRegardlessOfValue() {
        let network = makeNetwork(driver: .hostOnly, egress: "NAT → en0")
        #expect(NetworkPresentation.egressDescription(for: network) == "none · isolated")
        let badge = NetworkPresentation.egressBadge(for: network)
        #expect(badge.symbol == "lock.fill")
        #expect(badge.text == "Isolated · no egress")
    }

    @Test func natEgressShowsDaemonValueWhenPresent() {
        let network = makeNetwork(driver: .nat, egress: "NAT → en0")
        #expect(NetworkPresentation.egressDescription(for: network) == "NAT → en0")
        #expect(NetworkPresentation.egressBadge(for: network).text == "NAT → en0 · Internet")
    }

    @Test func natEgressFallsBackWhenDaemonValueIsPlaceholder() {
        // LiveContainerService maps egress to "–" (unknown), and "" is possible in fixtures.
        for placeholder in ["–", ""] {
            let network = makeNetwork(driver: .nat, egress: placeholder)
            #expect(NetworkPresentation.egressDescription(for: network) == "NAT")
            let badge = NetworkPresentation.egressBadge(for: network)
            #expect(badge.symbol == "globe")
            #expect(badge.text == "NAT · Internet")
        }
    }
}
