import SwiftUI

struct VolumesListView: View {
    @Environment(ContainerServiceBase.self) private var service

    private var named:     [Volume] { service.volumes.filter { $0.type == .named     } }
    private var anonymous: [Volume] { service.volumes.filter { $0.type == .anonymous } }

    var body: some View {
        if service.volumes.isEmpty {
            ContentUnavailableView {
                Label("No Volumes", systemImage: "cylinder")
            } description: {
                Text("Volumes created by containers will appear here.")
            }
            .navigationTitle("Volumes")
        } else {
            List {
                if !named.isEmpty {
                    Section {
                        ForEach(named)     { v in VolumeRow(volumeID: v.id).listRowSeparator(.hidden) }
                    } header: { LibrarySectionHeader("NAMED \(named.count)") }
                }
                if !anonymous.isEmpty {
                    Section {
                        ForEach(anonymous) { v in VolumeRow(volumeID: v.id).listRowSeparator(.hidden) }
                    } header: { LibrarySectionHeader("ANONYMOUS \(anonymous.count)") }
                }
            }
            .navigationTitle("Volumes")
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
                    Text(mountSummary(volume))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        if volume.reclaimable {
                            Text("reclaimable")
                                .font(.caption)
                                .foregroundStyle(Color.statusPaused)
                        } else {
                            Text(volume.driver)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
            .opacity(isDeleting ? 0.4 : 1)
            .onHover { isHovered = $0 }
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

    private func usageString(_ v: Volume) -> String {
        "\(formatMB(v.usedMB)) / \(formatMB(v.allocatedMB))"
    }

    private func mountSummary(_ v: Volume) -> String {
        switch v.mounts.count {
        case 0:  return "not mounted"
        case 1:  return "1 mount · \(v.mounts[0].containerName)"
        default: return "\(v.mounts.count) mounts"
        }
    }

    private func formatMB(_ mb: Int) -> String {
        mb < 1024 ? "\(mb) MB" : String(format: "%.1f GB", Double(mb) / 1024)
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
    VolumesListView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 360, height: 500)
}
