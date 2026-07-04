import SwiftUI

/// System page, styled as a macOS System Settings–style grouped form: each concern
/// (daemon version, disk usage, kernel, config, builder, logs) is its own inset
/// `Section` with a small SF Symbol header. Row content uses `LabeledContent` so the
/// label/value rhythm and separators match the native settings look.
struct SystemView: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        Form {
            DaemonVersionSection()
            DiskUsageSection(usage: service.diskUsage)
            KernelSection(kernel: service.kernelInfo)
            SystemConfigSection(config: service.systemConfigInfo)
            BuilderSection()
            DaemonLogsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("System")
        .task {
            async let disk: Void? = try? service.fetchDiskUsage()
            async let kernel: Void? = try? service.fetchKernelInfo()
            async let config: Void? = try? service.fetchSystemConfig()
            _ = await (disk, kernel, config)
        }
    }
}

// MARK: - Shared

/// A grouped-form section header: small SF Symbol + title, matching System Settings.
private func sectionHeader(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
}

/// Right-aligned, selectable, middle-truncating monospaced value for a `LabeledContent`.
private func monoValue(_ text: String) -> some View {
    Text(text)
        .fontDesign(.monospaced)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
}

// MARK: - Daemon Version

private struct DaemonVersionSection: View {
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
        Section {
            LabeledContent("Status") {
                HStack(spacing: 5) {
                    Image(systemName: isCompatible ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .imageScale(.small)
                    Text(isCompatible ? "Up to date" : "Update available")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(isCompatible ? Color.statusRunning : Color.statusError)
            }

            LabeledContent("Installed") { monoValue(service.installedContainerVersion ?? "Unknown") }
            LabeledContent("Required") { monoValue(ContainerCompatibility.requiredVersion) }

            if !isCompatible {
                Button {
                    showUpdateConfirm = true
                } label: {
                    Label("Update Container to v\(ContainerCompatibility.requiredVersion)…", systemImage: "arrow.down.circle")
                }
                .disabled(isUpdating)
            }

            if isUpdating {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        } header: {
            sectionHeader("Container Daemon", systemImage: "shippingbox")
        }
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

// MARK: - Disk Usage

private func formatDiskBytes(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1_024 { return String(format: "%.1f GB", mb / 1_024) }
    if mb >= 1 { return String(format: "%.1f MB", mb) }
    let kb = Double(bytes) / 1024
    if kb >= 1 { return String(format: "%.0f KB", kb) }
    return "\(bytes) B"
}

private struct DiskUsageSection: View {
    let usage: DiskUsageSummary?

    var body: some View {
        Section {
            if let usage {
                row("Images", usage.images)
                row("Containers", usage.containers)
                row("Volumes", usage.volumes)
            } else {
                LabeledContent("Loading…") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Disk Usage", systemImage: "internaldrive")
        }
    }

    private func row(_ name: String, _ c: DiskUsageSummary.Category) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDiskBytes(c.sizeBytes))
                    .font(.body.monospacedDigit())
                if c.reclaimableBytes > 0 {
                    Text("\(formatDiskBytes(c.reclaimableBytes)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(Color.statusPaused)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text("\(c.active) of \(c.total) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Kernel

private struct KernelSection: View {
    let kernel: KernelInfo?
    @Environment(ContainerServiceBase.self) private var service
    @State private var showSetKernel = false

    var body: some View {
        Section {
            if let kernel {
                LabeledContent("Path") { monoValue(kernel.path) }
                LabeledContent("Platform") { monoValue(kernel.platform) }
                Button("Set Kernel…") { showSetKernel = true }
            } else {
                LabeledContent("Kernel") {
                    Text("Not configured").foregroundStyle(.secondary)
                }
                Button("Set Kernel…") { showSetKernel = true }
            }
        } header: {
            sectionHeader("Kernel", systemImage: "cpu")
        }
        .sheet(isPresented: $showSetKernel) {
            SetKernelSheet(service: service, currentKernel: kernel)
        }
    }
}

// MARK: - System Configuration

private struct SystemConfigSection: View {
    let config: SystemConfigInfo?
    @State private var showRawJSON = false

    var body: some View {
        Section {
            if let config {
                LabeledContent("VM Init Image") { monoValue(config.vminitImage) }
                LabeledContent("Builder Image") { monoValue(config.builderImage) }

                DisclosureGroup("Raw configuration (JSON)", isExpanded: $showRawJSON) {
                    ScrollView {
                        Text(config.rawJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 240)
                    .padding(.top, 4)
                }
            } else {
                LabeledContent("Loading…") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("System Configuration", systemImage: "gearshape")
        }
    }
}

// MARK: - Builder

private struct BuilderSection: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        Section {
            if service.builders.isEmpty {
                Text("No builder found. Create one with `container builder create`.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(service.builders) { builder in
                    BuilderRow(builder: builder)
                }
            }
        } header: {
            sectionHeader("Builder", systemImage: "hammer")
        }
    }
}

private struct BuilderRow: View {
    let builder: Builder
    @Environment(ContainerServiceBase.self) private var service
    @State private var showStopConfirm = false
    @State private var isStopping = false
    @State private var errorMessage: String?

    private var isRunning: Bool { builder.status == .running }

    private var subtitle: String {
        var parts = ["\(builder.image)", "\(builder.cpus) vCPU · \(builder.memoryGB) GB"]
        if builder.autoStarted { parts.append("Auto-start") }
        return parts.joined(separator: "  ·  ")
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                StatusBadge(status: isRunning ? .running : .stopped)
                if isRunning {
                    Button(role: .destructive) { showStopConfirm = true } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .tint(.statusError)
                    .disabled(isStopping)
                    .help("Stop Builder")
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(builder.name).font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(isStopping ? 0.4 : 1)
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

// MARK: - Daemon Logs

private struct DaemonLogsSection: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        Section {
            LogStreamView(id: "daemon-logs", stream: service.streamDaemonLogs)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        } header: {
            sectionHeader("Daemon Logs", systemImage: "text.alignleft")
        }
    }
}

// MARK: - Preview

#Preview {
    // Seed system data synchronously so the preview renders populated cards rather
    // than the async "Loading…" states.
    let mock = MockContainerService()
    mock.diskUsage = DiskUsageSummary(
        images: .init(total: 12, active: 4, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
        containers: .init(total: 6, active: 2, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
        volumes: .init(total: 3, active: 1, sizeBytes: 512_000_000, reclaimableBytes: 0)
    )
    mock.kernelInfo = KernelInfo(path: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186", platform: "linux/arm64")
    mock.systemConfigInfo = SystemConfigInfo(
        vminitImage: "ghcr.io/apple/containerization/vminit:latest",
        kernelBinaryPath: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186",
        kernelURL: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst",
        builderImage: "ghcr.io/apple/container-builder-shim/builder:latest",
        rawJSON: "{\n  \"vminit\" : {\n    \"image\" : \"ghcr.io/apple/containerization/vminit:latest\"\n  }\n}"
    )
    return SystemView()
        .environment(mock as ContainerServiceBase)
        .frame(width: 520, height: 1000)
}
