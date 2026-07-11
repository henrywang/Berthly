import SwiftUI

struct VolumesListView: View {
    @Binding var selectedID: String?
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @State private var filterText = ""
    @State private var isSearchPresented = false
    @State private var deleteTargetID: String?
    @State private var deleteErrorMessage: String?
    @AppStorage("volumesSortOrder") private var sortOrderRaw = LibrarySortOrder.default.rawValue

    private var sortOrder: LibrarySortOrder { LibrarySortOrder(rawValue: sortOrderRaw) ?? .default }

    private var filtered: [Volume] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty
            ? service.volumes
            : service.volumes.filter { $0.name.lowercased().contains(query) }
        switch sortOrder {
        case .default: return matching
        case .name:    return matching.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:    return matching.sorted { $0.usedMB > $1.usedMB }
        }
    }

    private var named:     [Volume] { filtered.filter { $0.type == .named     } }
    private var anonymous: [Volume] { filtered.filter { $0.type == .anonymous } }

    private var totalUsedMB: Int { service.volumes.reduce(0) { $0 + $1.usedMB } }
    private var reclaimableMB: Int { service.volumes.filter(\.reclaimable).reduce(0) { $0 + $1.usedMB } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !service.volumes.isEmpty {
                    Label(formatVolumeMB(totalUsedMB) + " used", systemImage: "cylinder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if reclaimableMB > 0 {
                        Text(formatVolumeMB(reclaimableMB) + " reclaimable")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.statusPaused)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.statusPaused.opacity(0.12), in: Capsule())
                    }
                }
                Spacer()
                LibrarySortMenu(selectionRaw: $sortOrderRaw)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if service.volumes.isEmpty {
                ContentUnavailableView {
                    Label("No Volumes", systemImage: "cylinder")
                } description: {
                    Text("Add a volume, or one created by a container will appear here.")
                } actions: {
                    // Same intent path the toolbar's Add button uses — MainWindowView owns the
                    // sheet, so the empty state can't present it directly.
                    Button("Add Volume…") { bridge.pendingIntent = .openCreateVolumeSheet }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: filterText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedID) {
                    if !named.isEmpty {
                        Section {
                            ForEach(named)     { v in VolumeRow(volumeID: v.id).tag(v.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("NAMED \(named.count)") }
                    }
                    if !anonymous.isEmpty {
                        Section {
                            ForEach(anonymous) { v in VolumeRow(volumeID: v.id).tag(v.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("ANONYMOUS \(anonymous.count)") }
                    }
                }
                // ⌫ on the selected volume — same confirm-then-delete as the hover trash button.
                .onDeleteCommand { deleteTargetID = selectedID }
            }
        }
        .searchable(text: $filterText, isPresented: $isSearchPresented, prompt: "Filter by name")
        .onChange(of: bridge.searchFocusToken) { _, _ in isSearchPresented = true }
        .navigationTitle("Volumes")
        .confirmationDialog(deleteConfirmTitle, isPresented: Binding(
            get: { deleteTargetID != nil },
            set: { if !$0 { deleteTargetID = nil } }
        )) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deleteTargetID = nil }
        } message: {
            Text(deleteConfirmMessage)
        }
        .alert("Error", isPresented: Binding(
            get: { deleteErrorMessage != nil },
            set: { if !$0 { deleteErrorMessage = nil } }
        )) {
            Button("OK") { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var deleteTarget: Volume? {
        service.volumes.first(where: { $0.id == deleteTargetID })
    }

    private var deleteConfirmTitle: String {
        deleteTarget.map { "Delete \($0.name)?" } ?? ""
    }

    private var deleteConfirmMessage: String {
        guard let volume = deleteTarget else { return "" }
        if !volume.mounts.isEmpty {
            return "This volume is mounted by \(volume.mounts.count) container\(volume.mounts.count == 1 ? "" : "s"). Deleting it may cause data loss."
        }
        return "This will permanently delete the volume and all its data."
    }

    private func performDelete() {
        guard let volume = deleteTarget else { return }
        deleteTargetID = nil
        if selectedID == volume.id { selectedID = nil }
        Task {
            do { try await service.deleteVolume(volume.name) }
            catch { deleteErrorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Row

private struct VolumeRow: View {
    let volumeID: String
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var volume: Volume? {
        service.volumes.first(where: { $0.id == volumeID })
    }

    var body: some View {
        if let volume {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "cylinder")
                    .foregroundStyle(volume.reclaimable ? Color.statusPaused : .secondary)
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(volume.name)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(mountSummary(volume))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isHovered {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.hoverIcon)
                    .help("Delete Volume")
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(usageString(volume))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        mountStatus(volume)
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(isDeleting ? 0.4 : 1)
            .onHover { isHovered = $0 }
            .contextMenu {
                Button("Copy Name") { copyToPasteboard(volume.name) }
                if !volume.source.isEmpty {
                    Button("Copy Source Path") { copyToPasteboard(volume.source) }
                }
                Divider()
                Button("Delete…", role: .destructive) { showDeleteConfirm = true }
            }
            .alert("Delete \(volume.name)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    Task {
                        do { try await service.deleteVolume(volume.name) }
                        catch { errorMessage = error.localizedDescription }
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if !volume.mounts.isEmpty {
                    Text("This volume is mounted by \(volume.mounts.count) container\(volume.mounts.count == 1 ? "" : "s"). Deleting it may cause data loss.")
                } else {
                    Text("This will permanently delete the volume and all its data.")
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

    /// Trailing second line: mount count with a status dot — green when a mounting container
    /// is running, gray when all are stopped, orange "Unused" when nothing mounts it.
    @ViewBuilder
    private func mountStatus(_ v: Volume) -> some View {
        if v.mounts.isEmpty {
            HStack(spacing: 4) {
                Circle().fill(Color.statusPaused).frame(width: 5, height: 5)
                Text("Unused")
            }
            .font(.caption)
            .foregroundStyle(Color.statusPaused)
        } else {
            HStack(spacing: 4) {
                Circle()
                    .fill(anyMounterRunning(v) ? Color.statusRunning : Color(NSColor.tertiaryLabelColor))
                    .frame(width: 5, height: 5)
                Text("\(v.mounts.count) mount\(v.mounts.count == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func anyMounterRunning(_ v: Volume) -> Bool {
        let names = Set(v.mounts.map(\.containerName))
        return service.containers.contains { names.contains($0.name) && $0.status == .running }
    }

    private func usageString(_ v: Volume) -> String {
        "\(formatVolumeMB(v.usedMB)) / \(formatVolumeMB(v.allocatedMB))"
    }

    private func mountSummary(_ v: Volume) -> String {
        v.mounts.isEmpty
            ? "Not mounted"
            : v.mounts.map(\.containerName).joined(separator: " · ")
    }
}

// MARK: - Shared formatting

func formatVolumeMB(_ mb: Int) -> String {
    mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
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
    @Previewable @State var selectedID: String? = nil
    VolumesListView(selectedID: $selectedID)
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 360, height: 500)
}
