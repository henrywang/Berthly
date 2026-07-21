// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import AppKit
import SwiftUI
internal import ContainerPersistence

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
            SystemPropertiesSection(properties: service.systemProperties)
            LocalDNSSection()
            BuilderSection()
            DaemonLogsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("System")
        .task {
            async let disk: Void? = try? service.fetchDiskUsage()
            async let kernel: Void? = try? service.fetchKernelInfo()
            async let config: Void? = try? service.fetchSystemConfig()
            async let dns: Void = service.fetchDNSDomains()
            async let props: Void = service.fetchSystemProperties()
            _ = await (disk, kernel, config, dns, props)
        }
    }
}

// MARK: - Shared

/// A grouped-form section header: small SF Symbol + title, matching System Settings.
private func sectionHeader(_ title: LocalizedStringKey, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
}

/// Right-aligned, selectable, single-line monospaced value for a `LabeledContent`.
///
/// Primary (not secondary) foreground: these are the row's actual data — versions, refs, etc. —
/// and native System Settings shows such values in the primary label color, letting
/// right-alignment and the monospaced face carry the label/value distinction. Secondary gray is
/// reserved on this page for genuine status/supplementary text (the "Up to date" state, disk
/// "reclaimable" hints), not for data.
///
/// Only for values that are always short (version numbers, `linux/arm64`) — anything that can
/// run long (paths, image refs) should use `pathRow` instead, see its doc comment for why.
private func monoValue(_ text: String) -> some View {
    Text(text)
        .fontDesign(.monospaced)
        .textSelection(.enabled)
        .lineLimit(1)
}

/// A label/value row for path- or reference-like data that can run long (a kernel binary path,
/// an image ref with registry/repo/tag) — stacks the value on its own full-width, left-aligned
/// line below the label instead of squeezing both onto one row.
///
/// Tried putting this in a trailing-aligned `LabeledContent` first: once the value wrapped to
/// more than one line, trailing alignment made every line ragged on the left, including cutting
/// mid-word into the filename — much harder to read than plain left-aligned wrapping.
private func pathRow(_ label: LocalizedStringKey, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
        Text(text)
            .font(.callout)
            .fontDesign(.monospaced)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 2)
}

// MARK: - Daemon Version

private struct DaemonVersionSection: View {
    @Environment(ContainerServiceBase.self) private var service
    @State private var showStopConfirm = false
    @State private var isStopping = false

    private var mismatch: ContainerCompatibility.Mismatch? {
        guard let installed = service.installedContainerVersion else { return nil }
        return ContainerCompatibility.mismatch(installed: installed)
    }

    private var isCompatible: Bool { mismatch == nil }

    private var statusText: String {
        switch mismatch {
        case nil: "Up to date"
        case .tooOld: "Update available"
        case .tooNew: "Newer than Berthly supports"
        }
    }

    var body: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 5) {
                    Image(systemName: isCompatible ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .imageScale(.small)
                    Text(statusText)
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
            .disabled(isStopping)

            // No update button here, deliberately: an incompatible install flips `daemonState`
            // to `.versionMismatch` on the next poll, and DaemonGateView blocks this whole page
            // behind the gate that owns the update flow (with progress state that survives the
            // daemon restarting mid-update — state held here would be torn down with the page).
            // The status row can still disagree with "Up to date" for a moment mid-poll, so it
            // stays informational.
        } header: {
            sectionHeader("Container Daemon", systemImage: "shippingbox")
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
                        confirmMessage: """
                            Deletes every stopped container and its writable layer. Running \
                            containers, machines, and builders are left alone. This can't be undone.
                            """,
                        isDestructive: true,
                        run: { try await service.pruneStoppedContainers() }
                    ))
                    Divider()
                    // Volumes: the most consequential cleanup — an unattached volume can hold real
                    // data the user means to reattach — so it's deliberately excluded from "Clean
                    // Up All" below; only this row's own explicitly-confirmed action reaches it.
                    DiskUsageGridRow(name: "Volumes", category: usage.volumes, cleanup: .init(
                        confirmTitle: "Remove unused volumes?",
                        confirmButton: "Remove",
                        confirmMessage: """
                            Deletes every volume not attached to any container, including all data \
                            inside. Volumes a container still references — even a stopped one — are \
                            left alone. This can't be undone.
                            """,
                        isDestructive: true,
                        run: { try await service.pruneVolumes() }
                    ))
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
            Text("""
                Removes unused images and stopped containers in one step. Volumes are never touched \
                here — use the Volumes row's own Prune if you're sure you don't need their data.
                """)
        }
        .alert("Done", isPresented: Binding(
            get: { allResult != nil },
            set: { if !$0 { allResult = nil } }
        )) {
            Button("OK") { allResult = nil }
        } message: {
            Text(allResult?.summaryText ?? "")
        }
        .errorAlert($allErrorMessage)
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

            Text("\(formatDiskBytes(category.reclaimableBytes)) · \((Double(category.reclaimablePercent) / 100).formatted(.percent.precision(.fractionLength(0))))")
                .monospacedDigit()
                .foregroundStyle(category.reclaimableBytes > 0 ? Color.statusPaused : .secondary)
                .gridColumnAlignment(.trailing)

            // Same label ("Prune") on every row that has one, so the action column is a fixed
            // width regardless of which row it's in — the earlier version used different labels
            // ("Clean Up" vs "Remove Stopped") whose differing widths made the column look uneven.
            // The destructive/non-destructive distinction lives in the confirmation step instead of
            // the row button's own styling.
            Group {
                if cleanup != nil, category.reclaimableBytes > 0 {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Prune") { showConfirm = true }
                            .controlSize(.small)
                            .accessibilityIdentifier("prune-\(name)")
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
                        do { result = try await cleanup.run() } catch { errorMessage = error.localizedDescription }
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
        .errorAlert($errorMessage)
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
                pathRow("Path", kernel.path)
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

// MARK: - Infrastructure Images

private struct SystemConfigSection: View {
    let config: SystemConfigInfo?

    var body: some View {
        Section {
            if let config {
                pathRow("VM Init Image", config.vminitImage)
                pathRow("Builder Image", config.builderImage)

                Button("Reveal config.toml in Finder") {
                    revealConfigFile()
                }
            } else {
                LabeledContent("Loading…") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Infrastructure Images", systemImage: "cube")
        } footer: {
            Text("""
                The exact vminit and builder image versions this install of Berthly is built \
                against — these must match what the installed container CLI expects.
                """)
        }
    }

    /// Selects the user's editable `config.toml` (`~/.config/container/config.toml`, respecting
    /// `XDG_CONFIG_HOME`) in Finder — not the read-only app-root copy `ConfigurationLoader`
    /// actually loads from, which is regenerated from this file and would be pointless to edit.
    /// Falls back to the nearest existing ancestor directory if the file (or even `~/.config/
    /// container/` itself, never created until the user customizes something) doesn't exist yet
    /// — `selectFile` silently no-ops if handed a root that doesn't exist, so walking up is what
    /// actually guarantees *some* Finder window opens for the common "never customized" case.
    private func revealConfigFile() {
        let path = String(describing: ConfigurationLoader.configurationFile(.home))
        let fm = FileManager.default
        var directory = (path as NSString).deletingLastPathComponent
        while directory != "/" && !fm.fileExists(atPath: directory) {
            directory = (directory as NSString).deletingLastPathComponent
        }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: directory)
    }
}

// MARK: - System Properties

/// Read-only mirror of `container system property list`: every dotted config key with its
/// resolved value, defaults included. Deliberately not editable — properties are set via
/// `config.toml` (the Infrastructure Images section's Reveal button) or the CLI, and a wrong
/// value here can leave the daemon unbootable, so Berthly only reports.
private struct SystemPropertiesSection: View {
    let properties: [SystemProperty]?
    /// Collapsed by default: 17 rows of raw config is reference material, not at-a-glance
    /// status — expanded it would dominate the page.
    @State private var isExpanded = false

    var body: some View {
        Section {
            if let properties {
                // A hand-built toggle, not `DisclosureGroup` — the closure-label initializer
                // isn't reliably clickable through the accessibility API (see `SheetAdvancedSection`
                // in SheetChrome.swift for the fuller writeup of the underlying bug).
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack {
                        Text("\(properties.count) properties")
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("systemPropertiesDisclosure")

                if isExpanded {
                    ForEach(properties) { property in
                        LabeledContent {
                            Text(property.value)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(property.value)
                        } label: {
                            Text(property.key)
                                .font(.callout)
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                LabeledContent("Loading…") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Properties", systemImage: "list.bullet.rectangle")
        } footer: {
            Text("""
                Everything `container system property list` reports, defaults included. To change \
                a value, edit config.toml (revealed above) and restart the daemon.
                """)
        }
    }
}

// MARK: - Local DNS

/// Local DNS domains for containers (`container system dns list/create/delete`). Mutations
/// touch `/etc/resolver`, which needs root — the service layer shows the standard macOS
/// administrator-password prompt, so rows stay enabled and the OS handles the authorization UX.
private struct LocalDNSSection: View {
    @Environment(ContainerServiceBase.self) private var service
    @State private var showAddPrompt = false
    @State private var newDomain = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        Section {
            if let domains = service.dnsDomains {
                if domains.isEmpty {
                    Text("No local domains — containers are reachable by IP only.")
                        .foregroundStyle(.secondary)
                }
                ForEach(domains, id: \.self) { domain in
                    DNSDomainRow(domain: domain)
                }
                if isCreating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Adding domain…").foregroundStyle(.secondary)
                    }
                } else {
                    Button("Add Domain…") {
                        newDomain = ""
                        showAddPrompt = true
                    }
                }
            } else {
                LabeledContent("Loading…") { EmptyView() }
                    .foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("Local DNS", systemImage: "globe")
        } footer: {
            Text("""
                A local domain lets this Mac resolve containers by name under it (e.g. web.test). \
                Adding or removing one modifies /etc/resolver, so macOS asks for an administrator \
                password.
                """)
        }
        .alert("Add a local DNS domain", isPresented: $showAddPrompt) {
            TextField("Domain (e.g. test)", text: $newDomain)
            Button("Add") { performCreate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll be asked for an administrator password.")
        }
        .errorAlert($errorMessage)
    }

    private func performCreate() {
        let domain = newDomain
        isCreating = true
        Task {
            do {
                try await service.createDNSDomain(domain)
            } catch is CancellationError {
                // Dismissed the admin prompt — not an error.
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}

private struct DNSDomainRow: View {
    let domain: String
    @Environment(ContainerServiceBase.self) private var service
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        LabeledContent {
            if isDeleting {
                ProgressView().controlSize(.small)
            } else {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete Domain")
                .accessibilityIdentifier("dnsDeleteButton-\(domain)")
            }
        } label: {
            Text(domain)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
        }
        .opacity(isDeleting ? 0.4 : 1)
        .alert("Delete the \(domain) domain?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                isDeleting = true
                Task {
                    do {
                        try await service.deleteDNSDomain(domain)
                    } catch is CancellationError {
                        // Dismissed the admin prompt — not an error.
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Container names under \(domain) will stop resolving on this Mac. You'll be asked for an administrator password.")
        }
        .errorAlert($errorMessage)
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
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var isStarting = false
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
                    .buttonStyle(.bordered)
                    .tint(.statusError)
                    .controlSize(.small)
                    .disabled(isStopping)
                    .help("Stop Builder")
                    .accessibilityIdentifier("builderStopButton-\(builder.id)")
                } else {
                    // Benign and instantly reversible, so no confirmation alert — like
                    // `container builder start`, this just boots the builder VM so the next
                    // build skips the boot wait. Uses the configured default resources.
                    Button {
                        isStarting = true
                        Task {
                            do { try await service.startBuilder(builder.id) } catch { errorMessage = error.localizedDescription }
                            isStarting = false
                        }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isStarting || isDeleting)
                    .help("Start Builder")
                    .accessibilityIdentifier("builderStartButton-\(builder.id)")

                    // Delete only offered once stopped — same stop-first gate as container rows
                    // (the CLI needs --force to delete a running builder; the GUI doesn't offer
                    // that). The next build recreates the builder, so this is the reset path for
                    // a wedged or cache-bloated builder, not a permanent removal.
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isDeleting || isStarting)
                    .help("Delete Builder")
                    .accessibilityIdentifier("builderDeleteButton-\(builder.id)")
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
        .opacity(isStopping || isDeleting || isStarting ? 0.4 : 1)
        .alert("Stop \(builder.name)?", isPresented: $showStopConfirm) {
            Button("Stop", role: .destructive) {
                isStopping = true
                Task {
                    do { try await service.stopBuilder(builder.id) } catch { errorMessage = error.localizedDescription }
                    isStopping = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The builder container will be shut down.")
        }
        .alert("Delete \(builder.name)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                isDeleting = true
                Task {
                    do { try await service.deleteBuilder(builder.id) } catch { errorMessage = error.localizedDescription }
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the builder container and its build cache. Your next build recreates it automatically, but starts without cached layers.")
        }
        .errorAlert($errorMessage)
    }
}

// MARK: - Daemon Logs

private struct DaemonLogsSection: View {
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        Section {
            DaemonLogView(stream: service.streamDaemonLogs)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        } header: {
            sectionHeader("Daemon Logs", systemImage: "text.alignleft")
        }
    }
}

/// Read-only, at-a-glance feed of the daemon's own diagnostic events: muted `HH:MM:SS` + message,
/// no level badge, no filter/wrap/follow toolbar. Daemon events are occasional health/status
/// info you check when something looks off, not a firehose you actively search through the way
/// you would container stdout — that's what `LogStreamView` (Container Logs) is for. Always
/// auto-scrolls to the newest line since there's no "Following" toggle to turn that off.
private struct DaemonLogView: View {
    let stream: (@escaping @MainActor (String) -> Void) async throws -> Void

    private struct Line: Identifiable {
        let id = UUID()
        let time: String
        let message: String
    }

    @State private var lines: [Line] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if lines.isEmpty {
                    ContentUnavailableView("No logs", systemImage: "text.alignleft")
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines) { line in
                            HStack(alignment: .top, spacing: 12) {
                                Text(line.time)
                                    .foregroundStyle(.tertiary)
                                Text(line.message)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    // Native select + ⌘C / right-click Copy, same as Container Logs — daemon
                    // lines are read-only diagnostics a user often pastes elsewhere.
                    .textSelection(.enabled)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .onChange(of: lines.count) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            // No toolbar here by design, so a floating icon is the one-click "copy everything"
            // (drag-select + ⌘C still works for a partial copy via `.textSelection`).
            .overlay(alignment: .topTrailing) {
                if !lines.isEmpty {
                    Button { copyAll() } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy all logs to the clipboard")
                    .accessibilityLabel("Copy all logs")
                    .padding(8)
                }
            }
        }
        .task {
            lines = []
            try? await stream { raw in
                lines.append(Self.parseLine(raw))
                if lines.count > 500 { lines.removeFirst(lines.count - 500) }
            }
        }
    }

    private func copyAll() {
        let text = lines
            .map { [$0.time, $0.message].filter { !$0.isEmpty }.joined(separator: " ") }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Daemon log lines arrive as `LiveContainerService.formatDaemonLogEvent`'s
    /// `"time\tlevel\tmessage"` — level is dropped (this view shows no badge), and the
    /// millisecond-precision time is trimmed to `HH:MM:SS` for the compact, at-a-glance style.
    private static func parseLine(_ raw: String) -> Line {
        let fields = raw.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 3 else {
            return Line(time: "", message: raw.trimmingCharacters(in: .whitespaces))
        }
        return Line(time: String(fields[0].prefix(8)), message: String(fields[2]))
    }
}

#Preview("Builder rows — running / stopped") {
    let mock = MockContainerService()
    mock.builders = [
        Builder(id: "running", name: "buildkit", image: "buildkit:0.13", status: .running,
                autoStarted: true, cpus: 2, memoryGB: 2),
        Builder(id: "stopped", name: "buildkit", image: "buildkit:0.13", status: .stopped,
                autoStarted: false, cpus: 2, memoryGB: 2)
    ]
    return Form {
        BuilderSection()
    }
    .formStyle(.grouped)
    .environment(mock as ContainerServiceBase)
    .frame(width: 560, height: 220)
}

#Preview("Daemon log — copy overlay") {
    DaemonLogView { onLine in
        for raw in [
            "09:01:12.031\tinfo\tdaemon started",
            "09:01:13.114\tinfo\tapiserver ready",
            "09:01:14.980\twarn\tbuilder image missing, pulling"
        ] {
            await MainActor.run { onLine(raw) }
        }
    }
    .frame(width: 460, height: 180)
    .padding()
}

// MARK: - Preview

#Preview {
    // Seed system data synchronously so the preview renders populated cards rather
    // than the async "Loading…" states.
    let mock = MockContainerService()
    mock.diskUsage = DiskUsageSummary(
        images: .init(total: 12, active: 4, sizeBytes: 3_400_000_000, reclaimableBytes: 1_100_000_000),
        containers: .init(total: 6, active: 2, sizeBytes: 240_000_000, reclaimableBytes: 90_000_000),
        volumes: .init(total: 3, active: 1, sizeBytes: 512_000_000, reclaimableBytes: 180_000_000)
    )
    mock.dnsDomains = ["test"]
    mock.systemProperties = [
        SystemProperty(key: "build.rosetta", value: "true"),
        SystemProperty(key: "dns.domain", value: "test"),
        SystemProperty(key: "registry.domain", value: "docker.io")
    ]
    mock.kernelInfo = KernelInfo(path: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186", platform: "linux/arm64")
    mock.systemConfigInfo = SystemConfigInfo(
        vminitImage: "ghcr.io/apple/containerization/vminit:latest",
        kernelBinaryPath: "/opt/kata/share/kata-containers/vmlinux-6.18.15-186",
        kernelURL: "https://github.com/kata-containers/kata-containers/releases/download/3.28.0/kata-static-3.28.0-arm64.tar.zst",
        builderImage: "ghcr.io/apple/container-builder-shim/builder:latest"
    )
    return SystemView()
        .environment(mock as ContainerServiceBase)
        .frame(width: 520, height: 1400)
}
