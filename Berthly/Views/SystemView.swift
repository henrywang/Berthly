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
///
/// Primary (not secondary) foreground: these are the row's actual data — versions, paths,
/// image refs — and native System Settings shows such values in the primary label color, letting
/// right-alignment and the monospaced face carry the label/value distinction. Secondary gray is
/// reserved on this page for genuine status/supplementary text (the "Up to date" state, disk
/// "reclaimable" hints), not for data.
private func monoValue(_ text: String) -> some View {
    Text(text)
        .fontDesign(.monospaced)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
}

// MARK: - Daemon Version

private struct DaemonVersionSection: View {
    @Environment(ContainerServiceBase.self) private var service
    @State private var showUpdateConfirm = false
    @State private var isUpdating = false
    @State private var showStopConfirm = false
    @State private var isStopping = false
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

            // SystemView only renders behind DaemonGateView while the daemon is `.connected`, so
            // the daemon is always running here — a Stop control is the only lifecycle action that
            // makes sense (Start is unreachable from this page and already lives in the gate and
            // the menu bar).
            Button("Stop Container Daemon…", role: .destructive) {
                showStopConfirm = true
            }
            .disabled(isStopping || isUpdating)

            if !isCompatible {
                Button("Update Container to v\(ContainerCompatibility.requiredVersion)…") {
                    showUpdateConfirm = true
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
        .alert("Stop the container daemon?", isPresented: $showStopConfirm) {
            Button("Stop", role: .destructive) {
                isStopping = true
                Task {
                    await service.stopDaemon()
                    isStopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops every running container on this Mac, not just ones Berthly manages.")
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

/// Small-caps gray column header, matching `MenuBarSectionHeader`'s caption2/semibold/secondary
/// treatment elsewhere in the app.
private func columnHeader(_ text: String) -> some View {
    Text(text.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
}

private struct DiskUsageSection: View {
    let usage: DiskUsageSummary?
    @Environment(ContainerServiceBase.self) private var service

    @State private var showCleanUpAllConfirm = false
    @State private var isCleaningAll = false
    @State private var allResult: PruneResult?
    @State private var allErrorMessage: String?

    var body: some View {
        Section {
            if let usage {
                // A Grid (not independent LabeledContent rows) so every column — Total, Active,
                // Size, Reclaimable, Action — shares one width across all three category rows.
                // Independent rows don't do this: a row with an action button sizes its trailing
                // content differently than a row without one, so numbers land at different trailing
                // edges per row. Grid sizes each column to its widest cell across every row.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        columnHeader("Type")
                        columnHeader("Total").gridColumnAlignment(.trailing)
                        columnHeader("Active").gridColumnAlignment(.trailing)
                        columnHeader("Size").gridColumnAlignment(.trailing)
                        columnHeader("Reclaimable").gridColumnAlignment(.trailing)
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    Divider()

                    // Images: safe, re-pullable cache.
                    DiskUsageGridRow(name: "Images", category: usage.images, cleanup: .init(
                        confirmTitle: "Clean up unused images?",
                        confirmButton: "Clean Up",
                        confirmMessage: "Removes images not used by any container. They can be pulled again if you need them.",
                        isDestructive: false,
                        run: { try await service.pruneImages() }
                    ))
                    Divider()
                    // Containers: deleting a stopped container is more consequential than clearing
                    // image cache (it's gone, not re-pullable) — its confirmation says so and uses
                    // a destructive role, even though the row's own button looks like Images' row.
                    DiskUsageGridRow(name: "Containers", category: usage.containers, cleanup: .init(
                        confirmTitle: "Remove stopped containers?",
                        confirmButton: "Remove",
                        confirmMessage: "Deletes every stopped container and its writable layer. Running containers, machines, and builders are left alone. This can't be undone.",
                        isDestructive: true,
                        run: { try await service.pruneStoppedContainers() }
                    ))
                    Divider()
                    // Volumes: no cleanup action — an unattached volume can hold real data the user
                    // means to reattach. Delete those individually if you're sure.
                    DiskUsageGridRow(name: "Volumes", category: usage.volumes)
                }
                .padding(.vertical, 4)

                if usage.cleanableReclaimableBytes > 0 {
                    HStack {
                        Text("Total \(formatDiskBytes(usage.totalSizeBytes)) · \(formatDiskBytes(usage.cleanableReclaimableBytes)) reclaimable")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if isCleaningAll {
                            ProgressView().controlSize(.small)
                        } else {
                            // Additive, not a replacement for the per-row actions above — this is a
                            // shortcut for "both at once", not the single combined button that was
                            // rejected earlier for hiding the images/containers distinction.
                            Button("Clean Up All") { showCleanUpAllConfirm = true }
                                .controlSize(.small)
                        }
                    }
                }
            } else {
                LabeledContent("Loading…") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Disk Usage", systemImage: "internaldrive")
        }
        .alert("Clean up all reclaimable space?", isPresented: $showCleanUpAllConfirm) {
            Button("Clean Up All", role: .destructive) {
                isCleaningAll = true
                Task {
                    // Image and container cleanup run independently inside pruneAll() — a failure in
                    // one doesn't skip or discard a successful result from the other (see
                    // ContainerServiceBase.pruneAll()).
                    let outcome = await service.pruneAll()
                    if let message = outcome.errorAlertMessage {
                        allErrorMessage = message
                    } else {
                        allResult = outcome.result
                    }
                    isCleaningAll = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes unused images and stopped containers in one step. Volumes are never touched — delete those individually if you're sure you don't need their data.")
        }
        .alert("Done", isPresented: Binding(
            get: { allResult != nil },
            set: { if !$0 { allResult = nil } }
        )) {
            Button("OK") { allResult = nil }
        } message: {
            Text(allResult?.summaryText ?? "")
        }
        .alert("Error", isPresented: Binding(
            get: { allErrorMessage != nil },
            set: { if !$0 { allErrorMessage = nil } }
        )) {
            Button("OK") { allErrorMessage = nil }
        } message: {
            Text(allErrorMessage ?? "")
        }
    }
}

/// One disk-usage category row: name, total/active counts, size, reclaimable (with percent), plus
/// an optional per-category cleanup action. A `GridRow` (not `LabeledContent`) so its cells join the
/// same columns as every other row in the enclosing `Grid`, keeping numbers and actions aligned
/// whether or not a given row has an action at all (Volumes has none).
///
/// Each row owns its own confirm/progress/result state so the two actions stay fully independent —
/// reclaiming image cache never forces the more consequential removal of stopped containers.
private struct DiskUsageGridRow: View {
    let name: String
    let category: DiskUsageSummary.Category
    var cleanup: Cleanup?

    struct Cleanup {
        let confirmTitle: String
        let confirmButton: String
        let confirmMessage: String
        let isDestructive: Bool
        let run: () async throws -> PruneResult
    }

    @State private var showConfirm = false
    @State private var isBusy = false
    @State private var result: PruneResult?
    @State private var errorMessage: String?

    var body: some View {
        GridRow(alignment: .center) {
            Text(name)

            Text("\(category.total)")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)

            Text("\(category.active)")
                .monospacedDigit()
                .gridColumnAlignment(.trailing)

            Text(formatDiskBytes(category.sizeBytes))
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .gridColumnAlignment(.trailing)

            Text("\(formatDiskBytes(category.reclaimableBytes)) · \(category.reclaimablePercent)%")
                .monospacedDigit()
                .foregroundStyle(category.reclaimableBytes > 0 ? Color.statusPaused : .secondary)
                .gridColumnAlignment(.trailing)

            // Same label ("Prune") on every row that has one, so the action column is a fixed
            // width regardless of which row it's in — the earlier version used different labels
            // ("Clean Up" vs "Remove Stopped") whose differing widths made the column look uneven.
            // The destructive/non-destructive distinction lives in the confirmation step instead of
            // the row button's own styling.
            Group {
                if let cleanup, category.reclaimableBytes > 0 {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Prune") { showConfirm = true }
                            .controlSize(.small)
                    }
                }
            }
            .gridColumnAlignment(.trailing)
        }
        .alert(cleanup?.confirmTitle ?? "", isPresented: $showConfirm) {
            if let cleanup {
                Button(cleanup.confirmButton, role: cleanup.isDestructive ? .destructive : nil) {
                    isBusy = true
                    Task {
                        do { result = try await cleanup.run() }
                        catch { errorMessage = error.localizedDescription }
                        isBusy = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: {
            Text(cleanup?.confirmMessage ?? "")
        }
        .alert("Done", isPresented: Binding(
            get: { result != nil },
            set: { if !$0 { result = nil } }
        )) {
            Button("OK") { result = nil }
        } message: {
            Text(result?.summaryText ?? "")
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
