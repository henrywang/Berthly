import SwiftUI

struct RegistriesListView: View {
    @Environment(ContainerServiceBase.self) private var service

    @State private var showAddRegistry = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            infoBanner
                .padding(.horizontal, 20)
                .padding(.top, 12)

            if service.registries.isEmpty {
                ContentUnavailableView {
                    Label("No Registries", systemImage: "building.columns")
                } description: {
                    Text("Add a registry to sign in — or run `container registry login`.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                columnHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                List {
                    ForEach(service.registries) { registry in
                        RegistryRow(registryID: registry.id, errorMessage: $errorMessage)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Registries")
        .task { await service.loadRegistries() }
        .sheet(isPresented: $showAddRegistry) {
            AddRegistrySheet()
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

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Registries")
                    .font(.largeTitle.weight(.bold))
                Text("Credentials for pushing & pulling images · shared by the daemon and every machine")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAddRegistry = true
            } label: {
                Label("Add registry", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(.berthlyAccent)
        }
        .padding(20)
    }

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.blue)
                .padding(.top, 1)
            Text("Tokens are stored in the **macOS Keychain**, never written to `config.toml` in plaintext. Signing in or out maps to `container registry login` / `logout` — no daemon restart.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.2), lineWidth: 0.5))
    }

    private var columnHeader: some View {
        HStack {
            Text("REGISTRY").frame(maxWidth: .infinity, alignment: .leading)
            Text("USER").frame(width: 160, alignment: .leading)
            Spacer().frame(width: 90)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Row

private struct RegistryRow: View {
    let registryID: String
    @Binding var errorMessage: String?

    @Environment(ContainerServiceBase.self) private var service
    @State private var isWorking = false

    private var registry: Registry? {
        service.registries.first(where: { $0.id == registryID })
    }

    var body: some View {
        if let registry {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "building.columns")
                    .foregroundStyle(Color.statusRunning)
                    .imageScale(.small)
                    .frame(width: 16)

                Text(registry.host)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("@\(registry.username)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 160, alignment: .leading)

                Group {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sign out") { signOut(host: registry.host) }
                            .buttonStyle(.bordered)
                    }
                }
                .frame(width: 90, alignment: .trailing)
            }
            .padding(.vertical, 4)
        }
    }

    private func signOut(host: String) {
        isWorking = true
        Task {
            do {
                try await service.signOutRegistry(host: host)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

#Preview {
    RegistriesListView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 720, height: 500)
}
