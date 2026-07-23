// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

/// Sort order for library lists (Images, Volumes). `created` is deliberately absent: the model
/// only carries a human-readable display string ("2h ago", "Jun 12 2026"), not a date, so a
/// "by created" sort would be lexicographic garbage.
enum LibrarySortOrder: String, CaseIterable {
    case `default` = "Default Order"
    case name      = "Name"
    case size      = "Size"
}

struct ImagesListView: View {
    @Binding var selectedID: String?
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @State private var filterText = ""
    @State private var isSearchPresented = false
    @State private var deleteTargetID: String?
    @State private var deleteErrorMessage: String?
    @State private var showPruneConfirm = false
    @State private var isPruning = false
    @State private var pruneResult: PruneResult?
    @AppStorage("imagesSortOrder") private var sortOrderRaw = LibrarySortOrder.default.rawValue

    private var sortOrder: LibrarySortOrder { LibrarySortOrder(rawValue: sortOrderRaw) ?? .default }

    private var filtered: [ContainerImage] {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = query.isEmpty
            ? service.images
            : service.images.filter { $0.fullName.lowercased().contains(query) }
        switch sortOrder {
        case .default: return matching
        case .name:    return matching.sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
        case .size:    return matching.sorted { $0.sizeBytes > $1.sizeBytes }
        }
    }

    private var local: [ContainerImage] { filtered.filter { $0.source == .built } }
    private var pulled: [ContainerImage] { filtered.filter { $0.source == .pulled } }

    // Summarizes all images, not `filtered` — like the Volumes bar, it reports disk state,
    // which a text filter doesn't change.
    private var diskUsage: (totalBytes: Int64, reclaimableBytes: Int64) {
        ContainerImage.diskUsage(of: service.images)
    }

    var body: some View {
        Group {
            if service.images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "square.stack.3d.up")
                } description: {
                    Text("Pull or build an image to get started.")
                } actions: {
                    Button("Pull Image…") { bridge.pendingIntent = .openPullSheet }
                        .buttonStyle(.borderedProminent)
                    Button("Build Image…") { bridge.pendingIntent = .openBuildSheet }
                }
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: filterText)
            } else {
                List(selection: $selectedID) {
                    if !local.isEmpty {
                        Section {
                            ForEach(local) { img in ImageRow(imageID: img.id, selectedID: $selectedID).tag(img.id).listRowSeparator(.hidden) }
                        // "BUILT", not "LOCAL": pulled images live locally too, so "local" didn't
                        // distinguish anything — the split is how the image got here.
                        } header: { LibrarySectionHeader("BUILT \(local.count)") }
                    }
                    if !pulled.isEmpty {
                        Section {
                            ForEach(pulled) { img in ImageRow(imageID: img.id, selectedID: $selectedID).tag(img.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("PULLED \(pulled.count)") }
                    }
                }
                // Kill the hairline AppKit draws under the pinned first section header — see
                // NonFloatingListHeaders.
                .nonFloatingSectionHeaders()
                // ⌫ on the selected image — same confirm-then-delete as the hover trash button.
                .onDeleteCommand { deleteTargetID = selectedID }
                // Attached as a safe-area inset (not a sibling above the List) so List stays the
                // flush top-level view under the toolbar — otherwise macOS shows a stray hairline
                // divider under the toolbar that Compute/Networks (List with no header) don't have.
                .safeAreaInset(edge: .top) {
                    HStack(spacing: 8) {
                        Label(formatSize(diskUsage.totalBytes) + " on disk", systemImage: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if diskUsage.reclaimableBytes > 0 {
                            Text(formatSize(diskUsage.reclaimableBytes) + " reclaimable")
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
        .searchable(text: $filterText, isPresented: $isSearchPresented, prompt: "Filter by reference")
        .onChange(of: bridge.searchFocusToken) { _, _ in isSearchPresented = true }
        .navigationTitle("Images")
        // Section-scoped housekeeping next to the shared Run/Build/Pull actions, mirroring the
        // Networks pane's Prune — this pane already shows the reclaimable size, so the action
        // that frees it belongs here too, not only in System > Disk Usage.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // Always a labeled Button, even while checking — an icon-only ProgressView here
                // visually fuses into the same rounded capsule as the (also icon-only) Refresh
                // toolbar button, making the spinner look like it's running inside Refresh.
                Button {
                    Task { await service.checkForImageUpdates(force: true) }
                } label: {
                    if service.isCheckingImageUpdates {
                        Label {
                            Text("Checking…")
                        } icon: {
                            ProgressView().controlSize(.small)
                        }
                        .labelStyle(.titleAndIcon)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .disabled(service.isCheckingImageUpdates)
                .help(checkForUpdatesHelp)
                .accessibilityIdentifier("checkImageUpdatesButton")
            }
            ToolbarItem(placement: .primaryAction) {
                if isPruning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Prune…") { showPruneConfirm = true }
                        .disabled(diskUsage.reclaimableBytes == 0)
                        .help(diskUsage.reclaimableBytes == 0
                              ? "Every image is used by a container or machine"
                              : "Remove images not used by any container or machine")
                }
            }
        }
        .alert("Remove unused images?", isPresented: $showPruneConfirm) {
            Button("Remove", role: .destructive) { performPrune() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes every image not used by a container or machine, freeing about \(formatSize(diskUsage.reclaimableBytes)). Machine and builder images are never removed.")
        }
        .alert("Done", isPresented: Binding(
            get: { pruneResult != nil },
            set: { if !$0 { pruneResult = nil } }
        )) {
            Button("OK") { pruneResult = nil }
        } message: {
            Text(pruneResult?.summaryText ?? "")
        }
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

    private var deleteTarget: ContainerImage? {
        service.images.first(where: { $0.id == deleteTargetID })
    }

    private var checkForUpdatesHelp: String {
        guard let last = service.lastImageUpdateCheck else {
            return "Compare local images against their registries"
        }
        return "Compare local images against their registries (last checked \(last.formatted(.relative(presentation: .named))))"
    }

    private var deleteConfirmTitle: String {
        deleteTarget.map { "Delete \($0.fullName)?" } ?? ""
    }

    private var deleteConfirmMessage: LocalizedStringResource {
        deleteTarget?.deleteWarning ?? ""
    }

    private func performDelete() {
        guard let image = deleteTarget else { return }
        deleteTargetID = nil
        Task {
            do { try await service.deleteImage(image.fullName) } catch { deleteErrorMessage = error.localizedDescription }
        }
    }

    private func performPrune() {
        isPruning = true
        Task {
            do {
                let result = try await service.pruneImages()
                // A pruned image might be the selected one — clear selection so the detail pane
                // doesn't strand on "not found" (same reason performDelete clears it).
                if let selectedID, !service.images.contains(where: { $0.id == selectedID }) {
                    self.selectedID = nil
                }
                pruneResult = result
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
            isPruning = false
        }
    }
}

// MARK: - Row

private struct ImageRow: View {
    let imageID: String
    // Clearing selection here (mirroring the list's performDelete) collapses the detail pane
    // when the selected image is deleted from the row — otherwise it strands on "not found".
    @Binding var selectedID: String?
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var showRunSheet = false
    @State private var showTagSheet = false
    @State private var showPullSheet = false
    @State private var showPushSheet = false
    @State private var saveRequest: ImageSaveRequest?

    private var image: ContainerImage? {
        service.images.first(where: { $0.id == imageID })
    }

    private var hasUpdate: Bool {
        image.map { service.updateAvailability(for: $0) == .updateAvailable } ?? false
    }

    var body: some View {
        if let image {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: image.source == .built ? "hammer" : "square.stack.3d.up")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(image.fullName)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .lineLimit(1)
                        .accessibilityIdentifier("imageRow-\(image.id)")
                    HStack(spacing: 4) {
                        ForEach(image.arch, id: \.self) { arch in
                            Text(arch)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        }
                        if image.arch.isEmpty {
                            Text("–")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        UsageBadge(usage: image.usage)
                        if hasUpdate {
                            UpdateAvailableBadge(image: image)
                        }
                    }
                }

                Spacer()

                if isHovered {
                    if hasUpdate {
                        Button { showPullSheet = true } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                        .buttonStyle(.hoverIcon)
                        .help("Pull Latest")
                        .accessibilityLabel("Pull Latest")
                    }
                    Button { showRunSheet = true } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.hoverIcon)
                    .help("Run from this image")
                    .accessibilityLabel("Run from this image")

                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.hoverIcon)
                    .help("Delete Image")
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatSize(image.sizeBytes))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text(image.created)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(isDeleting ? 0.4 : 1)
            .onHover { isHovered = $0 }
            .contextMenu {
                Button("Run from This Image…") { showRunSheet = true }
                if hasUpdate {
                    Button("Pull Latest") { showPullSheet = true }
                }
                Divider()
                Button("Tag…") { showTagSheet = true }
                Button("Push…") { showPushSheet = true }
                Button("Save to Disk…") {
                    if let destination = promptForArchiveDestination(imageName: image.fullName) {
                        saveRequest = ImageSaveRequest(reference: image.fullName, destination: destination)
                    }
                }
                Divider()
                Button("Copy Reference") { copyToPasteboard(image.fullName) }
                Button("Copy Digest") { copyToPasteboard(image.digest) }
                Divider()
                Button("Delete…", role: .destructive) { showDeleteConfirm = true }
            }
            .alert("Delete \(image.fullName)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    if selectedID == image.id { selectedID = nil }
                    Task {
                        do { try await service.deleteImage(image.fullName) } catch { errorMessage = error.localizedDescription }
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(image.deleteWarning)
            }
            .sheet(isPresented: $showRunSheet) {
                RunContainerSheet(service: service, initialReference: image.fullName)
            }
            .sheet(isPresented: $showPullSheet) {
                PullImageSheet(initialReference: image.fullName,
                              initiallyInsecure: service.isKnownInsecureRegistry(forReference: image.fullName))
            }
            .sheet(isPresented: $showTagSheet) {
                TagImageSheet(image: image)
            }
            .sheet(isPresented: $showPushSheet) {
                PushImageSheet(image: image)
            }
            .sheet(item: $saveRequest) { request in
                SaveImageSheet(request: request)
            }
            .errorAlert($errorMessage)
        }
    }
}

// MARK: - Usage Badge

/// Marks an image as referenced by a container/machine (or as an infra builder image), so
/// deleting it reads as a deliberate choice rather than an accident — shown on both the image
/// row and `ImageDetailView`'s header. `.unused` renders nothing: an unused image is the
/// expected, safe-to-delete default, so it doesn't need a badge to say so.
struct UsageBadge: View {
    let usage: ImageUsage

    var body: some View {
        switch usage {
        case .usedBy:
            // statusPaused (amber), not berthlyAccent — this codebase reserves accent blue for
            // interactive/primary controls; amber is already the "notable, look before you act"
            // tint (RO mounts, non-default networks), which fits a can't-delete-carelessly cue.
            Text(usage.displayString)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.statusPaused)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.statusPaused.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
        case .builderImage:
            Text(usage.displayString)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
        case .unused:
            EmptyView()
        }
    }
}

// MARK: - Sort menu

/// Compact sort control shared by the Images and Volumes lists. Backed by the raw string of a
/// `LibrarySortOrder` so callers can persist it directly in `@AppStorage`.
struct LibrarySortMenu: View {
    @Binding var selectionRaw: String

    var body: some View {
        Menu {
            Picker("Sort By", selection: $selectionRaw) {
                ForEach(LibrarySortOrder.allCases, id: \.rawValue) { order in
                    Text(order.rawValue).tag(order.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Sort the list")
    }
}

#Preview {
    @Previewable @State var selectedID: String?
    ImagesListView(selectedID: $selectedID)
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 360, height: 500)
}

#Preview("Empty") {
    @Previewable @State var selectedID: String?
    let mock = MockContainerService()
    mock.images.removeAll()
    return ImagesListView(selectedID: $selectedID)
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 400, height: 500)
}
