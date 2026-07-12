import Foundation

/// Pure presentation logic for the Networks list/detail views, kept out of the view layer so
/// it can be unit-tested (same rationale as `LiveContainerService.buildArguments(for:)`).
enum NetworkPresentation {

    /// The endpoints to display for a network. The daemon's network resource doesn't report
    /// attached endpoints (LiveContainerService maps `endpoints: []`), but each container knows
    /// which networks it joined — so containers attached to this network are derived into
    /// endpoint entries. Entries the network already reports (mock mode, future daemon support)
    /// win over derived ones with the same name, since they carry real IPs/aliases; their
    /// `isRunning` is refreshed from the container list when the names match. Derived entries
    /// are appended sorted by name for a stable order.
    nonisolated static func resolvedEndpoints(for network: Network, containers: [Container]) -> [NetworkEndpoint] {
        let reported = network.endpoints.map { endpoint in
            guard let container = containers.first(where: { $0.name == endpoint.name }) else {
                return endpoint
            }
            return NetworkEndpoint(
                id: endpoint.id, name: endpoint.name, ipv4: endpoint.ipv4,
                kind: endpoint.kind, isRunning: isRunning(container),
                aliases: endpoint.aliases
            )
        }
        let reportedNames = Set(reported.map(\.name))
        let derived = containers
            .filter { $0.networks.contains(network.name) && !reportedNames.contains($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { container in
                NetworkEndpoint(
                    id: container.id, name: container.name, ipv4: "–",
                    kind: "CONTAINER", isRunning: isRunning(container),
                    aliases: []
                )
            }
        return reported + derived
    }

    /// Trailing list-row summary, e.g. "3 endpoints" / "no endpoints".
    nonisolated static func endpointSummary(count: Int) -> String {
        switch count {
        case 0:  "no endpoints"
        case 1:  "1 endpoint"
        default: "\(count) endpoints"
        }
    }

    /// The Configuration row for egress. A host-only network has none by construction; for NAT
    /// the daemon's value is shown when it reports one ("–" is LiveContainerService's
    /// unknown placeholder, not a value).
    nonisolated static func egressDescription(for network: Network) -> String {
        if network.driver == .hostOnly { return "none · isolated" }
        return hasEgressDetail(network) ? network.egress : "NAT"
    }

    /// The badge at the top of the topology diagram: where traffic leaving this network goes.
    nonisolated static func egressBadge(for network: Network) -> (symbol: String, text: String) {
        if network.driver == .hostOnly { return ("lock.fill", "Isolated · no egress") }
        let detail = hasEgressDetail(network) ? network.egress : "NAT"
        return ("globe", "\(detail) · Internet")
    }

    private nonisolated static func hasEgressDetail(_ network: Network) -> Bool {
        !network.egress.isEmpty && network.egress != "–"
    }

    /// `status == .running` via a case pattern — ContainerStatus's synthesized Equatable
    /// conformance is main-actor isolated, so `==` can't be used from this nonisolated context.
    private nonisolated static func isRunning(_ container: Container) -> Bool {
        if case .running = container.status { return true }
        return false
    }
}
