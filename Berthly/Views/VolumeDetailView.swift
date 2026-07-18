// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - VolumeDetailView

struct VolumeDetailView: View {
    let volumeID: String
    var onDelete: (() -> Void)?
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        if service.volumes.contains(where: { $0.id == volumeID }) {
            VolumeDetailContent(volumeID: volumeID, onDelete: onDelete)
        } else {
            ContentUnavailableView("Volume not found", systemImage: "cylinder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - VolumeDetailContent

private struct VolumeDetailContent: View {
    let volumeID: String
    var onDelete: (() -> Void)?
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var volume: Volume? {
        service.volumes.first(where: { $0.id == volumeID })
    }

    var body: some View {
        if let volume {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(volume)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        capacitySection(volume)
                        mountedIntoSection(volume)
                        configurationSection(volume)
                        optionsSection(volume)
                        mountsSection(volume)
                    }
                    .padding(24)
                }
            }
            .alert("Delete \(volume.name)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await service.deleteVolume(volume.name)
                            onDelete?()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
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
            .errorAlert($errorMessage)
        }
    }

    // MARK: Header

    private func detailHeader(_ volume: Volume) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(volume.name)
                        .font(.title3.weight(.semibold))
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    VolumeChip(text: volume.type == .named ? "named" : "anonymous",
                               color: volume.type == .named ? .statusRunning : .purple)
                    if volume.reclaimable {
                        VolumeChip(text: "RECLAIMABLE", color: .statusPaused)
                    }
                }
                if !volume.source.isEmpty {
                    HStack(spacing: 4) {
                        Text(volume.source)
                            .font(.caption)
                            .fontDesign(.monospaced)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button {
                            copyToPasteboard(volume.source)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy source path")
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .help("Delete Volume")
            .accessibilityLabel("Delete Volume")
        }
    }

    // MARK: Capacity

    @ViewBuilder
    private func capacitySection(_ volume: Volume) -> some View {
        if volume.hasConfiguredCapacity {
            // Real, user-chosen capacity: a used/allocated gauge is meaningful.
            DetailSection(title: "Capacity") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Spacer()
                        Text(formatVolumeMB(volume.usedMB))
                            .font(.system(.callout, design: .monospaced, weight: .semibold))
                        Text("/ \(formatVolumeMB(volume.allocatedMB))")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("\(Int((volume.usagePercent * 100).rounded()))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(barColor(volume))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(barColor(volume).opacity(0.12), in: Capsule())
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(barColor(volume))
                                .frame(width: max(8, geo.size.width * min(volume.usagePercent, 1)))
                        }
                    }
                    .frame(height: 8)
                }
            }
        } else {
            // No meaningful capacity (512 GiB sparse default or unknown): a bar would read a
            // constant ~0%, so feature the actual on-disk footprint instead, with the sparse cap
            // as muted context.
            DetailSection(title: "Disk Usage") {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatVolumeMB(volume.usedMB))
                        .font(.system(.title3, design: .monospaced, weight: .semibold))
                    Text("on disk")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if volume.allocatedMB > 0 {
                        Text("grows up to \(formatVolumeMB(volume.allocatedMB))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func barColor(_ volume: Volume) -> Color {
        volume.usagePercent >= 0.8 ? .statusPaused : .berthlyAccent
    }

    // MARK: Mounted into

    private func mountedIntoSection(_ volume: Volume) -> some View {
        DetailSection(title: "Mounted Into") {
            HStack(alignment: .center, spacing: 12) {
                volumeNode(volume)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.tertiary)

                if volume.mounts.isEmpty {
                    notMountedNode(volume)
                } else {
                    VStack(spacing: 8) {
                        ForEach(volume.mounts, id: \.self) { mount in
                            containerNode(mount)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func volumeNode(_ volume: Volume) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cylinder")
                .foregroundStyle(Color.berthlyAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(formatVolumeMB(volume.hasConfiguredCapacity ? volume.allocatedMB : volume.usedMB)) · \(volume.driver)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: 200, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
    }

    /// One mounting container, as a clickable card that jumps to it in the Compute section.
    private func containerNode(_ mount: VolumeMount) -> some View {
        let container = service.containers.first(where: { $0.name == mount.containerName })
        return Button {
            if let container {
                bridge.pendingIntent = .selectCompute(.container(container.id))
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: container?.status.systemImage ?? "circle")
                    .font(.system(size: 7))
                    .foregroundStyle(container?.status.color ?? Color(NSColor.tertiaryLabelColor))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mount.containerName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(mount.mountPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                VolumeChip(text: mount.mode, color: mount.mode == "RO" ? .statusPaused : .berthlyAccent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(container == nil)
        .help(container == nil ? "" : "Show \(mount.containerName)")
    }

    private func notMountedNode(_ volume: Volume) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Not mounted into any container")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Attach with --volume \(volume.name):/path")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: Configuration

    private func configurationSection(_ volume: Volume) -> some View {
        var rows: [(String, String)] = [
            ("Type", volume.type == .named ? "named" : "anonymous"),
            ("Driver", volume.driver)
        ]
        if !volume.source.isEmpty { rows.append(("Source", volume.source)) }
        rows.append(("Created", volume.created))
        if volume.hasConfiguredCapacity {
            rows.append(("Allocated", formatVolumeMB(volume.allocatedMB)))
            rows.append(("Used", "\(formatVolumeMB(volume.usedMB)) · \(Int((volume.usagePercent * 100).rounded()))%"))
        } else {
            rows.append(("On disk", formatVolumeMB(volume.usedMB)))
            if volume.allocatedMB > 0 {
                rows.append(("Max size", formatVolumeMB(volume.allocatedMB)))
            }
        }
        rows.append(("Labels", volume.labels.isEmpty ? "–" : volume.labels.joined(separator: ", ")))
        rows.append(("Reclaimable", volume.reclaimable ? "yes" : "no · in use"))

        return DetailSection(title: "Configuration") {
            KeyValueRows(rows: rows, monoKeys: ["Source", "Labels", "Allocated", "Used", "On disk", "Max size"])
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }

    // MARK: Options

    @ViewBuilder
    private func optionsSection(_ volume: Volume) -> some View {
        let rows = optionRows(volume)
        if !rows.isEmpty {
            DetailSection(title: "Options") {
                KeyValueRows(rows: rows, monoKeys: Set(rows.map(\.0)))
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        }
    }

    private func optionRows(_ volume: Volume) -> [(String, String)] {
        var rows: [(String, String)] = volume.options.map { option in
            let parts = option.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : (option, "")
        }
        if !volume.fs.isEmpty { rows.append(("fs", volume.fs)) }
        return rows
    }

    // MARK: Mounts

    @ViewBuilder
    private func mountsSection(_ volume: Volume) -> some View {
        if !volume.mounts.isEmpty {
            DetailSection(title: "Mounts \(volume.mounts.count)") {
                VStack(spacing: 0) {
                    HStack {
                        Text("CONTAINER")
                            .frame(width: 140, alignment: .leading)
                        Text("DESTINATION")
                        Spacer()
                        Text("MODE")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)

                    ForEach(volume.mounts, id: \.self) { mount in
                        Divider().padding(.horizontal, 16)
                        mountRow(mount)
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        }
    }

    private func mountRow(_ mount: VolumeMount) -> some View {
        let container = service.containers.first(where: { $0.name == mount.containerName })
        return HStack {
            HStack(spacing: 6) {
                Image(systemName: container?.status.systemImage ?? "circle")
                    .font(.system(size: 6))
                    .foregroundStyle(container?.status.color ?? Color(NSColor.tertiaryLabelColor))
                Text(mount.containerName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
            Text(mount.mountPath)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            VolumeChip(text: mount.mode, color: mount.mode == "RO" ? .statusPaused : .berthlyAccent)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Chip

/// Small tinted tag (driver, type, mode, RECLAIMABLE) used across the volume detail header
/// and mount cards — same recipe as the arch badges on image rows.
private struct VolumeChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Previews

#Preview("Named, multi-mount") {
    let mock = MockContainerService()
    VolumeDetailView(volumeID: "shared")
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 720)
}

#Preview("Reclaimable, not mounted") {
    let mock = MockContainerService()
    VolumeDetailView(volumeID: "model")
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 720)
}

#Preview("Anonymous") {
    let mock = MockContainerService()
    VolumeDetailView(volumeID: "anon1")
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 720)
}

#Preview("Sparse default (no --size)") {
    let mock = MockContainerService()
    VolumeDetailView(volumeID: "logs")
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 720)
}
