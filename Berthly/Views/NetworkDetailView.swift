// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI

// MARK: - NetworkDetailView

struct NetworkDetailView: View {
    let networkID: String
    var onDelete: (() -> Void)?
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        if service.networks.contains(where: { $0.id == networkID }) {
            NetworkDetailContent(networkID: networkID, onDelete: onDelete)
        } else {
            ContentUnavailableView("Network not found", systemImage: "arrow.triangle.branch")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - NetworkDetailContent

private struct NetworkDetailContent: View {
    let networkID: String
    var onDelete: (() -> Void)?
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var network: Network? {
        service.networks.first(where: { $0.id == networkID })
    }

    var body: some View {
        if let network {
            let endpoints = NetworkPresentation.resolvedEndpoints(for: network, containers: service.containers)
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(network)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 16)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        topologySection(network, endpoints: endpoints)
                        configurationSection(network)
                        endpointsSection(network, endpoints: endpoints)
                    }
                    .padding(24)
                }
            }
            .alert("Delete \(network.name)?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await service.deleteNetwork(network.id)
                            onDelete?()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if !network.endpoints.isEmpty {
                    Text("This network has \(network.endpoints.count) endpoint\(network.endpoints.count == 1 ? "" : "s"). Deleting it may disrupt connectivity.")
                } else {
                    Text("This can't be undone.")
                }
            }
            .errorAlert($errorMessage)
        }
    }

    // MARK: Header

    private func detailHeader(_ network: Network) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(network.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    NetworkChip(text: network.driver.rawValue,
                                color: network.driver == .nat ? .berthlyAccent : .statusPaused)
                    if network.isDefault {
                        NetworkChip(text: "DEFAULT", color: .secondary)
                    }
                }
                HStack(spacing: 4) {
                    Text("\(network.subnet) · gw \(network.gateway)")
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        copyToPasteboard(network.subnet)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy subnet")
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(network.isDefault ? Color.secondary : Color.red)
            }
            .buttonStyle(.bordered)
            .disabled(network.isDefault)
            .help(network.isDefault ? "The default network can't be deleted" : "Delete Network")
            .accessibilityLabel("Delete Network")
        }
    }

    // MARK: Topology

    /// Egress badge → network node → endpoint cards, joined by vertical connectors — the
    /// network-shaped sibling of VolumeDetailView's "Mounted Into" diagram.
    private func topologySection(_ network: Network, endpoints: [NetworkEndpoint]) -> some View {
        DetailSection(title: "Topology") {
            VStack(spacing: 0) {
                egressBadge(network)
                connector()
                networkNode(network)

                if endpoints.isEmpty {
                    connector()
                    noEndpointsNode(network)
                } else {
                    connector()
                    endpointGrid(network, endpoints: endpoints)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background {
                DotGridBackground()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func egressBadge(_ network: Network) -> some View {
        let badge = NetworkPresentation.egressBadge(for: network)
        return HStack(spacing: 6) {
            Image(systemName: badge.symbol)
                .font(.caption)
                .foregroundStyle(network.driver == .hostOnly ? Color.statusPaused : Color.berthlyAccent)
            Text(badge.text)
                .font(.system(.caption, design: .monospaced, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.background, in: Capsule())
        .overlay(Capsule().stroke(.separator, lineWidth: 0.5))
    }

    private func connector() -> some View {
        Rectangle()
            .fill(Color.berthlyAccent.opacity(0.35))
            .frame(width: 1.5, height: 16)
    }

    private func networkNode(_ network: Network) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.berthlyAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(network.subnet)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("→ gw \(network.gateway)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5)
        )
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(Color.berthlyAccent)
                .frame(width: 3)
        }
    }

    private func endpointGrid(_ network: Network, endpoints: [NetworkEndpoint]) -> some View {
        CenteredAdaptiveGrid(minimumWidth: 140, spacing: 8) {
            ForEach(endpoints) { endpoint in
                endpointCard(endpoint)
            }
        }
    }

    /// One attached endpoint, as a clickable card that jumps to it in the Compute section.
    private func endpointCard(_ endpoint: NetworkEndpoint) -> some View {
        let target = computeItem(for: endpoint)
        return Button {
            if let target { bridge.pendingIntent = .selectCompute(target) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(endpoint.isRunning ? Color.statusRunning : Color(NSColor.tertiaryLabelColor))
                        .frame(width: 6, height: 6)
                    Text(endpoint.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(endpoint.ipv4)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                NetworkChip(text: endpoint.kind, color: .secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .help(target == nil ? "" : "Show \(endpoint.name)")
    }

    /// The Compute item an endpoint card should jump to, matched by name — endpoints don't
    /// carry the container/machine id.
    private func computeItem(for endpoint: NetworkEndpoint) -> ComputeItem? {
        if endpoint.kind == "MACHINE" {
            return service.machines.first(where: { $0.name == endpoint.name }).map { .machine($0.id) }
        }
        return service.containers.first(where: { $0.name == endpoint.name }).map { .container($0.id) }
    }

    private func noEndpointsNode(_ network: Network) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No endpoints attached")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Attach with --network \(network.name)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: Configuration

    private func configurationSection(_ network: Network) -> some View {
        let rows: [(String, String)] = [
            ("Driver", network.driver.rawValue),
            ("Scope", network.scope),
            ("Subnet", network.subnet),
            ("Gateway", network.gateway),
            ("IPv6", network.ipv6Enabled ? "enabled" : "disabled"),
            ("Egress", NetworkPresentation.egressDescription(for: network)),
            ("Attachable", network.attachable ? "yes" : "no"),
            ("Backend", network.backend)
        ]
        return DetailSection(title: "Configuration") {
            KeyValueRows(rows: rows, monoKeys: ["Subnet", "Gateway", "Egress", "Backend"])
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }

    // MARK: Endpoints

    @ViewBuilder
    private func endpointsSection(_ network: Network, endpoints: [NetworkEndpoint]) -> some View {
        if !endpoints.isEmpty {
            DetailSection(title: "Endpoints \(endpoints.count)") {
                VStack(spacing: 0) {
                    HStack {
                        Text("ENDPOINT")
                            .frame(width: 170, alignment: .leading)
                        Text("IPV4")
                        Spacer()
                        Text("ALIASES")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)

                    ForEach(endpoints) { endpoint in
                        Divider().padding(.horizontal, 16)
                        endpointRow(endpoint)
                    }
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        }
    }

    private func endpointRow(_ endpoint: NetworkEndpoint) -> some View {
        HStack {
            HStack(spacing: 6) {
                Circle()
                    .fill(endpoint.isRunning ? Color.statusRunning : Color(NSColor.tertiaryLabelColor))
                    .frame(width: 6, height: 6)
                Text(endpoint.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // The chip keeps its intrinsic width inside the fixed column — without this the
                // column squeezes the chip's text into a wrap before the name truncates.
                NetworkChip(text: endpoint.kind, color: .secondary)
                    .fixedSize()
            }
            .frame(width: 170, alignment: .leading)
            Text(endpoint.ipv4)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Text(endpoint.aliases.isEmpty ? "–" : endpoint.aliases.joined(separator: ", "))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Centered adaptive grid

/// Mirrors `LazyVGrid(columns: [.adaptive(minimum:)])`'s column math, but centers a short
/// trailing row instead of leaving it flush left beside empty grid cells.
private struct CenteredAdaptiveGrid: Layout {
    var minimumWidth: CGFloat
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rawWidth = proposal.width ?? minimumWidth
        let width = rawWidth.isFinite ? rawWidth : minimumWidth
        let columns = columnCount(for: width)
        let columnWidth = columnWidth(for: width, columns: columns)
        var height: CGFloat = 0
        var rowCount = 0
        for start in stride(from: 0, to: subviews.count, by: columns) {
            let row = subviews[start..<min(start + columns, subviews.count)]
            height += row.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
            rowCount += 1
        }
        height += spacing * CGFloat(max(0, rowCount - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = columnCount(for: bounds.width)
        let columnWidth = columnWidth(for: bounds.width, columns: columns)
        var y = bounds.minY

        for start in stride(from: 0, to: subviews.count, by: columns) {
            let rowSubviews = Array(subviews[start..<min(start + columns, subviews.count)])
            let rowHeight = rowSubviews.map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }.max() ?? 0
            let rowWidth = CGFloat(rowSubviews.count) * columnWidth + CGFloat(rowSubviews.count - 1) * spacing
            var x = bounds.minX + (bounds.width - rowWidth) / 2

            for subview in rowSubviews {
                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: columnWidth, height: rowHeight)
                )
                x += columnWidth + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        return max(1, Int((width + spacing) / (minimumWidth + spacing)))
    }

    private func columnWidth(for width: CGFloat, columns: Int) -> CGFloat {
        (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    }
}

// MARK: - Dot grid

/// Subtle dot-grid canvas behind the topology diagram — reads as a "blueprint" surface in
/// both appearances without adding real chrome.
private struct DotGridBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.quinary)
            Canvas { context, size in
                let spacing: CGFloat = 14
                var y: CGFloat = spacing / 2
                while y < size.height {
                    var x: CGFloat = spacing / 2
                    while x < size.width {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                            with: .color(.secondary.opacity(0.18))
                        )
                        x += spacing
                    }
                    y += spacing
                }
            }
        }
    }
}

// MARK: - Chip

/// Small tinted tag (driver, DEFAULT, endpoint kind) — same recipe as VolumeDetailView's chip.
private struct NetworkChip: View {
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

#Preview("NAT with endpoints") {
    NetworkDetailView(networkID: "app-net")
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 1080)
}

#Preview("Host-only") {
    NetworkDetailView(networkID: "data-net")
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 1080)
}

#Preview("Default network") {
    NetworkDetailView(networkID: "default")
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 520, height: 1080)
}
