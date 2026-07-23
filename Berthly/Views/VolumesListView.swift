// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

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

    private var named: [Volume] { filtered.filter { $0.type == .named     } }
    private var anonymous: [Volume] { filtered.filter { $0.type == .anonymous } }

    private var totalUsedMB: Int { service.volumes.reduce(0) { $0 + $1.usedMB } }
    private var reclaimableMB: Int { service.volumes.filter(\.reclaimable).reduce(0) { $0 + $1.usedMB } }

    var body: some View {
        Group {
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
                            ForEach(named) { v in VolumeRow(volumeID: v.id, selectedID: $selectedID).tag(v.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("NAMED \(named.count)") }
                    }
                    if !anonymous.isEmpty {
                        Section {
                            ForEach(anonymous) { v in VolumeRow(volumeID: v.id, selectedID: $selectedID).tag(v.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("ANONYMOUS \(anonymous.count)") }
                    }
                }
                // Kill the hairline AppKit draws under the pinned first section header — see
                // NonFloatingListHeaders.
                .nonFloatingSectionHeaders()
                // ⌫ on the selected volume — same confirm-then-delete as the hover trash button.
                .onDeleteCommand { deleteTargetID = selectedID }
                // Attached as a safe-area inset (not a sibling above the List) so List stays the
                // flush top-level view under the toolbar — otherwise macOS shows a stray hairline
                // divider under the toolbar that Compute/Networks (List with no header) don't have.
                .safeAreaInset(edge: .top) {
                    HStack(spacing: 8) {
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
                        Spacer()
                        LibrarySortMenu(selectionRaw: $sortOrderRaw)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.background)
                }
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
        .errorAlert($deleteErrorMessage)
    }

    private var deleteTarget: Volume? {
        service.volumes.first(where: { $0.id == deleteTargetID })
    }

    private var deleteConfirmTitle: String {
        deleteTarget.map { "Delete \($0.name)?" } ?? ""
    }

    private var deleteConfirmMessage: LocalizedStringResource {
        deleteTarget?.deleteWarning ?? ""
    }

    private func performDelete() {
        guard let volume = deleteTarget else { return }
        deleteTargetID = nil
        if selectedID == volume.id { selectedID = nil }
        Task {
            do { try await service.deleteVolume(volume.name) } catch { deleteErrorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Row

private struct VolumeRow: View {
    let volumeID: String
    // Clearing selection here (mirroring the list's performDelete) collapses the detail pane
    // when the selected volume is deleted from the row — otherwise it strands on "not found".
    @Binding var selectedID: String?
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
                        .accessibilityIdentifier("volumeRow-\(volume.name)")
                    Text(mountSummary(volume))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // NetworkRow's identical if/else hover-swap reproducibly crashed the app on
                // context-menu delete (AppKit layout re-entrancy) and was rewritten as a static
                // ZStack+opacity swap — see its comment for the full story. This row has the same
                // shape and has never been observed to crash across repeated manual and automated
                // testing (2026-07-19), but no source-level difference explains why; prefer the
                // ZStack pattern here too if this row ever needs to change.
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
                    if selectedID == volume.id { selectedID = nil }
                    Task {
                        do { try await service.deleteVolume(volume.name) } catch { errorMessage = error.localizedDescription }
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(volume.deleteWarning)
            }
            .errorAlert($errorMessage)
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
        // A 512 GiB sparse-default (or unknown) capacity makes "x / 512 GB" misleading, so show
        // just the real on-disk footprint in that case.
        v.hasConfiguredCapacity
            ? "\(formatVolumeMB(v.usedMB)) / \(formatVolumeMB(v.allocatedMB))"
            : formatVolumeMB(v.usedMB)
    }

    private func mountSummary(_ v: Volume) -> String {
        v.mounts.isEmpty
            ? "Not mounted"
            : v.mounts.map(\.containerName).joined(separator: " · ")
    }
}

#Preview {
    @Previewable @State var selectedID: String?
    VolumesListView(selectedID: $selectedID)
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 360, height: 500)
}
