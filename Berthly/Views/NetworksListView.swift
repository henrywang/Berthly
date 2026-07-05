import SwiftUI

struct NetworksListView: View {
    @Environment(ContainerServiceBase.self) private var service
    @State private var showCreateSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { showCreateSheet = true } label: {
                    Label("Add Network", systemImage: "plus")
                }
                .disabled(!service.isConnected)
                .help("Create a new network")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if service.networks.isEmpty {
                ContentUnavailableView {
                    Label("No Networks", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Add a network, or one created for a container will appear here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(service.networks) { net in
                        NetworkRow(networkID: net.id).listRowSeparator(.hidden)
                    }
                }
            }
        }
        .navigationTitle("Networks")
        .sheet(isPresented: $showCreateSheet) {
            NetworkCreateSheet()
        }
    }
}

// MARK: - Row

private struct NetworkRow: View {
    let networkID: String
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

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

                if isHovered {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(network.isDefault ? Color.secondary : Color.red)
                    }
                    .buttonStyle(.hoverIcon)
                    .disabled(network.isDefault)
                    .help(network.isDefault ? "The default network can't be deleted" : "Delete Network")
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(endpointSummary(network))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(driverLabel(network.driver))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(isDeleting ? 0.4 : 1)
            .onHover { isHovered = $0 }
            .alert("Delete \(network.name)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    Task {
                        do { try await service.deleteNetwork(network.id) }
                        catch { errorMessage = error.localizedDescription }
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if !network.endpoints.isEmpty {
                    Text("This network has \(network.endpoints.count) endpoint\(network.endpoints.count == 1 ? "" : "s"). Deleting it may disrupt connectivity.")
                } else {
                    Text("This action cannot be undone.")
                }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
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
