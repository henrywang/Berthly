import SwiftUI

struct RegistriesListView: View {
    @Environment(ContainerServiceBase.self) private var service

    private var signedIn:    [Registry] { service.registries.filter {  $0.isSignedIn } }
    private var notSignedIn: [Registry] { service.registries.filter { !$0.isSignedIn } }

    var body: some View {
        if service.registries.isEmpty {
            ContentUnavailableView {
                Label("No Registries", systemImage: "building.columns")
            } description: {
                Text("Sign in to a registry with `container login`.")
                    .fontDesign(.monospaced)
            }
            .navigationTitle("Registries")
        } else {
            List {
                if !signedIn.isEmpty {
                    Section {
                        ForEach(signedIn)    { r in RegistryRow(registryID: r.id).listRowSeparator(.hidden) }
                    } header: { LibrarySectionHeader("SIGNED IN \(signedIn.count)") }
                }
                if !notSignedIn.isEmpty {
                    Section {
                        ForEach(notSignedIn) { r in RegistryRow(registryID: r.id).listRowSeparator(.hidden) }
                    } header: { LibrarySectionHeader("NOT SIGNED IN \(notSignedIn.count)") }
                }
            }
            .navigationTitle("Registries")
        }
    }
}

// MARK: - Row

private struct RegistryRow: View {
    let registryID: String
    @Environment(ContainerServiceBase.self) private var service

    private var registry: Registry? {
        service.registries.first(where: { $0.id == registryID })
    }

    var body: some View {
        if let registry {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "building.columns")
                    .foregroundStyle(registry.isSignedIn ? Color.statusRunning : Color(NSColor.tertiaryLabelColor))
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(registry.name)
                        .font(.system(.body, design: .default, weight: .medium))
                        .lineLimit(1)
                    Text(registry.host)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(scopeLabel(registry.scope))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if case .signedIn(let username) = registry.status {
                        Text("@\(username)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.statusRunning)
                    } else {
                        Text("not signed in")
                            .font(.caption)
                            .foregroundStyle(Color(NSColor.tertiaryLabelColor))
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func scopeLabel(_ scope: RegistryScope) -> String {
        switch scope {
        case .pushAndPull: return "Push & Pull"
        case .pullOnly:    return "Pull only"
        case .unknown:     return "–"
        }
    }
}

// MARK: - Section Header

private struct LibrarySectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(nil)
    }
}

#Preview {
    RegistriesListView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 360, height: 350)
}
