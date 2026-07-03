import SwiftUI

/// Shared by `BuilderCard` and `DaemonVersionCard`'s info grids below.
private func infoLabel(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .frame(minWidth: 64, alignment: .leading)
}

struct SystemView: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                daemonVersionSection
                builderSection
            }
            .padding(20)
        }
        .navigationTitle("System")
    }

    @ViewBuilder
    private var daemonVersionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTAINER DAEMON")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            DaemonVersionCard()
        }
    }

    @ViewBuilder
    private var builderSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BUILDER")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            if service.builders.isEmpty {
                Text("No builder found. Create one with `container builder create`.")
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            } else {
                ForEach(service.builders) { builder in
                    BuilderCard(builder: builder)
                }
            }
        }
    }
}

// MARK: - Builder Card

private struct BuilderCard: View {
    let builder: Builder
    @Environment(ContainerServiceBase.self) private var service
    @State private var showStopConfirm = false
    @State private var isStopping = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Header row: icon + name + status badge + stop button
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "hammer")
                    .foregroundStyle(builder.status == .running ? Color.statusRunning : Color(NSColor.tertiaryLabelColor))
                    .imageScale(.medium)

                Text(builder.name)
                    .font(.system(.body, design: .default, weight: .semibold))

                StatusBadge(status: builder.status == .running ? .running : .stopped)

                Spacer()

                if builder.status == .running {
                    Button(role: .destructive) { showStopConfirm = true } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .tint(.statusError)
                    .disabled(isStopping)
                    .help("Stop Builder")
                }
            }

            Divider()

            // Info grid
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    infoLabel("Image")
                    Text(builder.image)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                GridRow {
                    infoLabel("Resources")
                    Text("\(builder.cpus) vCPU · \(builder.memoryGB) GB")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if builder.autoStarted {
                    GridRow {
                        infoLabel("Mode")
                        Text("Auto-start")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .opacity(isStopping ? 0.4 : 1)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        .alert("Stop \(builder.name)?", isPresented: $showStopConfirm) {
            Button("Stop", role: .destructive) {
                isStopping = true
                Task {
                    do { try await service.stopBuilder(builder.id) }
                    catch { errorMessage = error.localizedDescription }
                    isStopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The builder container will be shut down.")
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

// MARK: - Daemon Version Card

private struct DaemonVersionCard: View {
    @Environment(ContainerServiceBase.self) private var service
    @State private var showUpdateConfirm = false
    @State private var isUpdating = false
    @State private var logLines: [String] = []
    @State private var errorMessage: String?

    private var isCompatible: Bool {
        guard let installed = service.installedContainerVersion else { return true }
        return ContainerCompatibility.isCompatible(installed: installed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(isCompatible ? Color.statusRunning : Color.statusError)
                    .imageScale(.medium)

                Text("container")
                    .font(.system(.body, design: .default, weight: .semibold))

                if !isCompatible {
                    Text("Update Available")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.statusError)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.statusError.opacity(0.12), in: Capsule())
                }

                Spacer()

                if !isCompatible {
                    Button {
                        showUpdateConfirm = true
                    } label: {
                        Label("Update Container", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.berthlyAccent)
                    .disabled(isUpdating)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    infoLabel("Installed")
                    Text(service.installedContainerVersion ?? "Unknown")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                GridRow {
                    infoLabel("Required")
                    Text(ContainerCompatibility.requiredVersion)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if isUpdating {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(16)
        .opacity(isUpdating ? 0.7 : 1)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        .alert("Update container to v\(ContainerCompatibility.requiredVersion)?", isPresented: $showUpdateConfirm) {
            Button("Update", role: .destructive) {
                isUpdating = true
                logLines = []
                Task {
                    do {
                        try await service.upgradeContainer { line in
                            logLines.append(line)
                        }
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isUpdating = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops every running container on this Mac, not just ones Berthly manages, while the update runs. You'll be asked for your admin password.")
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

#Preview {
    SystemView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 360, height: 300)
}
