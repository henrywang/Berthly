import SwiftUI

struct ImagesListView: View {
    @Binding var selectedID: String?
    @Environment(ContainerServiceBase.self) private var service

    private var local:  [ContainerImage] { service.images.filter { $0.source == .built } }
    private var pulled: [ContainerImage] { service.images.filter { $0.source == .pulled } }

    var body: some View {
        if service.images.isEmpty {
            ContentUnavailableView {
                Label("No Images", systemImage: "shippingbox")
            } description: {
                Text("Pull or build an image to get started.")
            }
            .navigationTitle("Images")
        } else {
            List(selection: $selectedID) {
                if !local.isEmpty {
                    Section {
                        ForEach(local)  { img in ImageRow(imageID: img.id).tag(img.id).listRowSeparator(.hidden) }
                    } header: { LibrarySectionHeader("LOCAL \(local.count)") }
                }
                if !pulled.isEmpty {
                    Section {
                        ForEach(pulled) { img in ImageRow(imageID: img.id).tag(img.id).listRowSeparator(.hidden) }
                    } header: { LibrarySectionHeader("PULLED \(pulled.count)") }
                }
            }
            .navigationTitle("Images")
        }
    }
}

// MARK: - Row

private struct ImageRow: View {
    let imageID: String
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

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
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
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
            .alert("Delete \(image.fullName)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    isDeleting = true
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
        .frame(width: 360, height: 500)
}
