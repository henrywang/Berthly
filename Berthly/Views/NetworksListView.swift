import SwiftUI

struct NetworksListView: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        if service.networks.isEmpty {
            ContentUnavailableView {
                Label("No Networks", systemImage: "arrow.triangle.branch")
            } description: {
                Text("Networks created for containers will appear here.")
            }
            .navigationTitle("Networks")
        } else {
            List {
                ForEach(service.networks) { net in
                    NetworkRow(networkID: net.id).listRowSeparator(.hidden)
                }
            }
            .navigationTitle("Networks")
        }
    }
}

// MARK: - Row

private struct NetworkRow: View {
    let networkID: String
    @Environment(ContainerServiceBase.self) private var service

    private var network: Network? {
        service.networks.first(where: { $0.id == networkID })
    }

    var body: some View {
        if let network {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(network.isDefault ? Color.berthlyAccent : .secondary)
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(network.name)
                            .font(.system(.body, design: .default, weight: .medium))
                        if network.isDefault {
                            Text("default")
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.berthlyAccent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.berthlyAccent)
                        }
                    }
                    Text(network.subnet)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(endpointSummary(network))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(driverLabel(network.driver))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func endpointSummary(_ net: Network) -> String {
        let running = net.endpoints.filter(\.isRunning).count
        let total   = net.endpoints.count
        if total == 0 { return "no endpoints" }
        return "\(running)/\(total) active"
    }

    private func driverLabel(_ driver: NetworkDriver) -> String {
        switch driver {
        case .nat:      return "NAT"
        case .hostOnly: return "Host-only"
        }
    }
}

#Preview {
    NetworksListView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 360, height: 300)
}
