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

    private var local:  [ContainerImage] { filtered.filter { $0.source == .built } }
    private var pulled: [ContainerImage] { filtered.filter { $0.source == .pulled } }

    var body: some View {
        Group {
            if service.images.isEmpty {
                ContentUnavailableView {
                    Label("No Images", systemImage: "shippingbox")
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
                            ForEach(local)  { img in ImageRow(imageID: img.id, selectedID: $selectedID).tag(img.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("LOCAL \(local.count)") }
                    }
                    if !pulled.isEmpty {
                        Section {
                            ForEach(pulled) { img in ImageRow(imageID: img.id, selectedID: $selectedID).tag(img.id).listRowSeparator(.hidden) }
                        } header: { LibrarySectionHeader("PULLED \(pulled.count)") }
                    }
                }
                // ⌫ on the selected image — same confirm-then-delete as the hover trash button.
                .onDeleteCommand { deleteTargetID = selectedID }
                // Attached as a safe-area inset (not a sibling above the List) so List stays the
                // flush top-level view under the toolbar — otherwise macOS shows a stray hairline
                // divider under the toolbar that Compute/Networks (List with no header) don't have.
                .safeAreaInset(edge: .top) {
                    HStack {
                        Spacer()
                        LibrarySortMenu(selectionRaw: $sortOrderRaw)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.background)
                }
            }
        }
        .searchable(text: $filterText, isPresented: $isSearchPresented, prompt: "Filter by reference")
        .onChange(of: bridge.searchFocusToken) { _, _ in isSearchPresented = true }
        .navigationTitle("Images")
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

    private var deleteTarget: ContainerImage? {
        service.images.first(where: { $0.id == deleteTargetID })
    }

    private var deleteConfirmTitle: String {
        deleteTarget.map { "Delete \($0.fullName)?" } ?? ""
    }

    private var deleteConfirmMessage: String {
        if case .usedBy(let n) = deleteTarget?.usage {
            return "This image is used by \(n) container\(n == 1 ? "" : "s"). Deleting it may affect those containers."
        }
        return "This will remove the image from local storage."
    }

    private func performDelete() {
        guard let image = deleteTarget else { return }
        deleteTargetID = nil
        Task {
            do { try await service.deleteImage(image.fullName) }
            catch { deleteErrorMessage = error.localizedDescription }
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

    private var image: ContainerImage? {
        service.images.first(where: { $0.id == imageID })
    }

    var body: some View {
        if let image {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: image.source == .built ? "hammer" : "shippingbox")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(image.fullName)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .lineLimit(1)
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
                    }
                }

                Spacer()

                if isHovered {
                    HStack(spacing: 12) {
                        Button { showRunSheet = true } label: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(Color.berthlyAccent)
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
                    }
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
                Divider()
                Button("Copy Reference") { copyToPasteboard(image.fullName) }
                Button("Copy Digest") { copyToPasteboard(image.id) }
                Divider()
                Button("Delete…", role: .destructive) { showDeleteConfirm = true }
            }
            .alert("Delete \(image.fullName)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
                    if selectedID == image.id { selectedID = nil }
                    Task {
                        do { try await service.deleteImage(image.fullName) }
                        catch { errorMessage = error.localizedDescription }
                        isDeleting = false
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if case .usedBy(let n) = image.usage {
                    Text("This image is used by \(n) container\(n == 1 ? "" : "s"). Deleting it may affect those containers.")
                } else {
                    Text("This will remove the image from local storage.")
                }
            }
            .sheet(isPresented: $showRunSheet) {
                RunContainerSheet(service: service, initialReference: image.fullName)
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

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1    { return String(format: "%.0f MB", mb) }
        let kb = Double(bytes) / 1024
        if kb >= 1    { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
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
    ImagesListView(selectedID: $selectedID)
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 360, height: 500)
}

#Preview("Empty") {
    @Previewable @State var selectedID: String? = nil
    let mock = MockContainerService()
    mock.images.removeAll()
    return ImagesListView(selectedID: $selectedID)
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 400, height: 500)
}
