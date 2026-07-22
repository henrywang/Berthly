// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

struct RegistriesListView: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge

    @State private var errorMessage: String?
    @State private var filterText = ""
    @State private var isSearchPresented = false

    private var filtered: [Registry] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return service.registries }
        return service.registries.filter {
            $0.host.lowercased().contains(query) || $0.username.lowercased().contains(query)
        }
    }

    var body: some View {
        Group {
            if service.registries.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    infoBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    ContentUnavailableView {
                        Label("No Registries", systemImage: "building.columns")
                    } description: {
                        Text("Add a registry to sign in — or run `container registry login`.")
                    } actions: {
                        // Same intent path the toolbar's Add button uses — MainWindowView owns the
                        // sheet, so the empty state can't present it directly.
                        Button("Add Registry…") { bridge.pendingIntent = .openAddRegistrySheet }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if filtered.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    infoBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    ContentUnavailableView.search(text: filterText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                List {
                    ForEach(filtered) { registry in
                        RegistryRow(registryID: registry.id, errorMessage: $errorMessage)
                    }
                }
                .listStyle(.plain)
                // Attached as a safe-area inset (not a sibling above the List) so List stays the
                // flush top-level view under the toolbar — otherwise macOS shows a stray hairline
                // divider under the toolbar that Compute/Networks (List with no header) don't have.
                .safeAreaInset(edge: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        infoBanner
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                        columnHeader
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    }
                    .background(.background)
                }
            }
        }
        .searchable(text: $filterText, isPresented: $isSearchPresented, prompt: "Filter by host or user")
        .onChange(of: bridge.searchFocusToken) { _, _ in isSearchPresented = true }
        .navigationTitle("Registries")
        .task { await service.loadRegistries() }
        .errorAlert($errorMessage)
    }

    // MARK: - Header

    private var infoBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.blue)
                .padding(.top, 1)
            Text("""
                Credentials are stored in the **macOS Keychain**, never written to `config.toml` \
                in plaintext. Signing in or out maps to `container registry login` / `logout` — \
                no daemon restart. While signed in, macOS may confirm Keychain access on pulls \
                from that host too, even for public images — sign out below to stop it.
                """)
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
                            .accessibilityIdentifier("registrySignOutButton-\(registry.host)")
                    }
                }
                .frame(width: 90, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 20)
            .contextMenu {
                Button("Copy Host") { copyToPasteboard(registry.host) }
                Button("Copy Username") { copyToPasteboard(registry.username) }
                Divider()
                Button("Sign Out") { signOut(host: registry.host) }
            }
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
        .environment(MenuBarBridge())
        .frame(width: 720, height: 500)
}
