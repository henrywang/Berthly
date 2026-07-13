import SwiftUI

struct NetworksListView: View {
    @Binding var selectedID: String?
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @State private var filterText = ""
    @State private var isSearchPresented = false
    @State private var deleteTargetID: String?
    @State private var deleteErrorMessage: String?

    private var filtered: [Network] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return service.networks }
        return service.networks.filter {
            $0.name.lowercased().contains(query) || $0.subnet.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if service.networks.isEmpty {
                ContentUnavailableView {
                    Label("No Networks", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Add a network, or one created for a container will appear here.")
                } actions: {
                    // Same intent path the toolbar's Add button uses — MainWindowView owns the
                    // sheet, so the empty state can't present it directly.
                    Button("Add Network…") { bridge.pendingIntent = .openCreateNetworkSheet }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: filterText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    ForEach(filtered) { net in
                        NetworkRow(networkID: net.id, selectedID: $selectedID).tag(net.id).listRowSeparator(.hidden)
                    }
                }
                // ⌫ on the selected network — same confirm-then-delete as the hover trash button.
                .onDeleteCommand { deleteTargetID = selectedID }
            }
        }
        .searchable(text: $filterText, isPresented: $isSearchPresented, prompt: "Filter by name or subnet")
        .onChange(of: bridge.searchFocusToken) { _, _ in isSearchPresented = true }
        .navigationTitle("Networks")
        .confirmationDialog(deleteConfirmTitle, isPresented: Binding(
            get: { deleteTargetID != nil },
            set: { if !$0 { deleteTargetID = nil } }
        )) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deleteTargetID = nil }
        } message: {
            Text(deleteConfirmMessage)
        }
        .errorAlert($deleteErrorMessage)
    }

    private var deleteTarget: Network? {
        // The default network can't be deleted — ignore ⌫ on it rather than confirm a no-op.
        service.networks.first(where: { $0.id == deleteTargetID && !$0.isDefault })
    }

    private var deleteConfirmTitle: String {
        deleteTarget.map { "Delete \($0.name)?" } ?? ""
    }

    private var deleteConfirmMessage: String {
        guard let network = deleteTarget else { return "" }
        if !network.endpoints.isEmpty {
            return "This network has \(network.endpoints.count) endpoint\(network.endpoints.count == 1 ? "" : "s"). Deleting it may disrupt connectivity."
        }
        return "This action cannot be undone."
    }

    private func performDelete() {
        guard let network = deleteTarget else { return }
        deleteTargetID = nil
        if selectedID == network.id { selectedID = nil }
        Task {
            do { try await service.deleteNetwork(network.id) }
            catch { deleteErrorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Row

private struct NetworkRow: View {
    let networkID: String
    // Clearing selection here (mirroring the list's performDelete) collapses the detail pane
    // when the selected network is deleted from the row — otherwise it strands on "not found".
    @Binding var selectedID: String?
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
            let endpoints = NetworkPresentation.resolvedEndpoints(for: network, containers: service.containers)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(network.isDefault ? Color.berthlyAccent : .secondary)
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(network.name)
                            .font(.system(.body, design: .default, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if network.isDefault {
                            RowChip(text: "DEFAULT", color: .secondary)
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
                    VStack(alignment: .trailing, spacing: 3) {
                        RowChip(text: network.driver.rawValue,
                                color: network.driver == .nat ? .berthlyAccent : .statusPaused)
                        endpointStatus(endpoints)
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(isDeleting ? 0.4 : 1)
            .onHover { isHovered = $0 }
            .contextMenu {
                Button("Copy Name") { copyToPasteboard(network.name) }
                Button("Copy Subnet") { copyToPasteboard(network.subnet) }
                Divider()
                Button("Delete…", role: .destructive) { showDeleteConfirm = true }
                    .disabled(network.isDefault)
            }
            .alert("Delete \(network.name)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    if selectedID == network.id { selectedID = nil }
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
            .errorAlert($errorMessage)
        }
    }

    /// Trailing second line: endpoint count with a status dot — green when any endpoint's
    /// workload is running, gray when all are stopped, tertiary "no endpoints" when empty.
    @ViewBuilder
    private func endpointStatus(_ endpoints: [NetworkEndpoint]) -> some View {
        if endpoints.isEmpty {
            Text(NetworkPresentation.endpointSummary(count: 0))
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(endpoints.contains(where: \.isRunning)
                          ? Color.statusRunning
                          : Color(NSColor.tertiaryLabelColor))
                    .frame(width: 5, height: 5)
                Text(NetworkPresentation.endpointSummary(count: endpoints.count))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Row chip

/// Small tinted tag (driver, DEFAULT) — list-row sibling of NetworkDetailView's chip.
private struct RowChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

#Preview {
    @Previewable @State var selectedID: String? = nil
    NetworksListView(selectedID: $selectedID)
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 360, height: 300)
}
