// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import Charts
import ContainerAPIClient
import SwiftUI

// MARK: - Container Detail View

// Thin wrapper that resolves the live container from the service on every render,
// so status/stats always reflect the current state after Stop/Start/Delete.
struct ContainerDetailView: View {
    let containerID: String
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        if service.containers.contains(where: { $0.id == containerID }) {
            ContainerDetailContent(containerID: containerID)
        } else {
            ContentUnavailableView("Container not found", systemImage: "shippingbox")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ContainerDetailContent: View {
    let containerID: String
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @State private var tab: DetailTab = .overview
    @State private var isWorking    = false
    @State private var errorMessage: String?
    @State private var showCopySheet     = false
    @State private var showRecreateSheet = false

    // Reads directly from service so every `container.xxx` access in body/computed-props
    // is tracked by @Observable — re-renders immediately when status/stats change.
    // Optional because @Observable can deliver this body before the outer ContainerDetailView
    // has processed the same containers update (TOCTOU on the guard in the wrapper).
    private var container: Container? {
        service.containers.first(where: { $0.id == containerID })
    }

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case logs     = "Logs"
        case terminal = "Terminal"
    }

    var body: some View {
        // Guard against the TOCTOU window where @Observable delivers this body
        // after `containers` has changed but before the outer ContainerDetailView
        // has processed the same update and removed this view from the tree.
        if let container {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(container)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

            Divider()

            DetailTabPicker(selection: $tab)

            Divider()

            Group {
                switch tab {
                case .overview:
                    ScrollView {
                        OverviewTab(container: container).padding(24)
                    }
                case .logs:
                    LogsTab(container: container)
                case .terminal:
                    if container.status == .running {
                        TerminalHostView(target: .container(id: container.id))
                            .id(container.id)
                    } else {
                        TerminalNotRunningTab()
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(container.name)
        .errorAlert($errorMessage)
        .sheet(isPresented: $showCopySheet) {
            CopyFilesSheet(service: service, containerID: container.id, targetName: container.name)
        }
        .sheet(isPresented: $showRecreateSheet) {
            RecreateContainerSheet(container: container)
        }
        // Palette "Open Shell" routing. `.onChange` covers the already-selected container;
        // `.onAppear` covers the usual case where selecting this container mounts the view fresh
        // (with the request already set), which `.onChange` would miss.
        .onAppear { consumeTerminalRequestIfRequested() }
        .onChange(of: bridge.terminalRequest) { _, _ in consumeTerminalRequestIfRequested() }
        // View-menu ⌘⌥1/2/3. Only `.onChange` (no `.onAppear`): the menu items are disabled
        // while no detail is open, so a request never predates this view's mount.
        .onChange(of: bridge.detailTabRequest) { _, request in
            guard let request, let mapped = DetailTab(rawValue: request.rawValue) else { return }
            tab = mapped
            bridge.detailTabRequest = nil
        }
        } // end if let container
    }

    private func consumeTerminalRequestIfRequested() {
        guard bridge.terminalRequest == .container(containerID) else { return }
        tab = .terminal
        bridge.terminalRequest = nil
    }

    // MARK: - Header

    private func detailHeader(_ container: Container) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(container.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    StatusBadge(status: container.status)
                }
                HStack(spacing: 4) {
                    Text(container.image)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                    ContainerStalenessGlyph(staleness: service.staleness(of: container),
                                            containerName: container.name)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)

            Button { service.togglePinContainer(container.id) } label: {
                Image(systemName: service.isContainerPinned(container.id) ? "pin.fill" : "pin")
                    .foregroundStyle(service.isContainerPinned(container.id) ? Color(hex: "F59E0B") : Color.secondary)
            }
            .buttonStyle(.bordered)
            .help(service.isContainerPinned(container.id) ? "Unpin" : "Pin")
            .hoverScale()

            Button { showRecreateSheet = true } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("containerRecreateButton")
            .help("Recreate with Latest Image…")
            .hoverScale()

            Button { showCopySheet = true } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("copyFilesButton")
            // The copy API rejects a non-running container ("container is not running"), so the
            // action is only offered while running — same gate the Terminal tab uses.
            .disabled(container.status != .running)
            .help(container.status == .running ? "Copy Files…" : "Start the container to copy files")
            .hoverScale()

            if container.status == .running {
                // No confirmation: stopping is cheap and reversible (Start replaces this button in
                // place), and the menu bar row already stops with a single click — one policy for
                // both. Confirmations are reserved for Delete and the daemon-wide stop.
                Button(role: .destructive) {
                    run { try await service.stopContainer(container.id) }
                } label: {
                    LifecycleActionLabel(title: "Stop", systemImage: "stop.fill", isWorking: isWorking)
                }
                .buttonStyle(.bordered)
                .tint(.statusError)
                .disabled(isWorking)
                .accessibilityIdentifier("containerStopButton")
                .help("Stop")
                .hoverScale()
            } else {
                Button {
                    run {
                        try await service.startContainer(container.id)
                        tab = .terminal
                    }
                } label: {
                    LifecycleActionLabel(title: "Start", systemImage: "play.fill", isWorking: isWorking)
                }
                .buttonStyle(.borderedProminent)
                .tint(.berthlyAccent)
                .disabled(isWorking)
                .accessibilityIdentifier("containerStartButton")
                .help("Start")
                .hoverScale()
            }
        }
    }

    // MARK: - Action runner

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do {
                try await action()
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

// MARK: - Overview Tab

// Overview folds in the live performance metrics that used to be a separate "Stats" tab: the
// old Overview showed static CPU/Memory cards fed by `container.cpuPercent`/`memoryMB`, which the
// live service never populates (always 0). The CPU/Memory/Network cards and their sparklines
// consume `service.containerStatsStream(id:)` — the poll loop and counter math live in the
// service layer (Live polls the daemon, Mock synthesizes), not here, so mock mode gets live
// cards and the delta math is unit-testable. Metrics only appear while running; stopped
// containers show Inspect alone.
private struct OverviewTab: View {
    let container: Container
    @Environment(ContainerServiceBase.self) private var service

    struct StatsPoint: Identifiable {
        let id    = UUID()
        let cpu: Double
        let memMB: Double
        let netMBs: Double
    }

    @State private var history: [StatsPoint] = []

    private var latestCPU: Double { history.last?.cpu    ?? 0 }
    private var latestMem: Double { history.last?.memMB  ?? 0 }
    private var latestNet: Double { history.last?.netMBs ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if container.status == .running {
                metricCards
            }
            InspectSection(container: container)
        }
        // Keyed on id *and* running state: switching containers must not blend two containers'
        // histories into one chart (this view's structural identity survives a selection change),
        // and a container started while its detail is open should begin charting without
        // requiring a reselect.
        .task(id: "\(container.id)|\(container.status == .running)") {
            history.removeAll()
            guard container.status == .running else { return }
            for await sample in service.containerStatsStream(id: container.id) {
                history.append(StatsPoint(cpu: sample.cpuPercent, memMB: sample.memoryMB, netMBs: sample.networkMBPerSecond))
                if history.count > 150 { history.removeFirst() }
            }
        }
    }

    // MARK: Live metrics

    private var metricCards: some View {
        // Until two samples exist there's no real value or trend to show — "0% · stable" over an
        // empty chart placeholder reads as a rendering bug, not as "warming up".
        let collecting = history.count < 2
        let cpuVals = history.map(\.cpu)
        let memVals = history.map(\.memMB)
        let netVals = history.map(\.netMBs)
        let cpuTrend = collecting ? ("", Color.secondary) : trendDisplay(ContainerStatsMath.trend(for: cpuVals))
        let memTrend = collecting ? ("", Color.secondary) : trendDisplay(ContainerStatsMath.trend(for: memVals))
        let netTrend = collecting ? ("", Color.secondary) : trendDisplay(ContainerStatsMath.trend(for: netVals))

        return HStack(spacing: 12) {
            MetricCard(
                label: "CPU",
                value: collecting ? "—" : "\(Int(latestCPU))%",
                trend: cpuTrend.0, trendColor: cpuTrend.1,
                data: cpuVals, lineColor: .berthlyAccent
            )
            MetricCard(
                label: "Memory",
                value: collecting ? "—" : "\(Int(latestMem)) MB",
                trend: memTrend.0, trendColor: memTrend.1,
                data: memVals, lineColor: .purple
            )
            MetricCard(
                label: "Network",
                value: collecting ? "—" : String(format: "%.1f MB/s", latestNet),
                trend: netTrend.0, trendColor: netTrend.1,
                data: netVals, lineColor: .statusRunning
            )
        }
    }

    private func trendDisplay(_ trend: ContainerStatsMath.Trend) -> (String, Color) {
        switch trend {
        case .stable:        return ("stable", .secondary)
        case .up(let delta): return ("▲ \(String(format: "%.0f", delta))", .statusRunning)
        case .down(let delta): return ("▼ \(String(format: "%.0f", delta))", .secondary)
        }
    }

}

private struct InspectSection: View {
    let container: Container

    private var rows: [(String, String)] {
        let mountStr = container.mounts.map(\.displayString).joined(separator: "\n")
        return [
            ("Status", "\(container.status.label)\(container.status == .running ? " · up \(container.uptime)" : "")"),
            ("Image", container.image),
            // Makes staleness legible: this is the digest the container was created from, which
            // the badge compares against the tag's current local image.
            ("Image digest", container.imageDigest ?? "–"),
            ("Container ID", container.id),
            ("Command", container.command),
            ("Ports", container.ports.isEmpty ? "–" : container.ports.map(\.displayString).joined(separator: ", ")),
            ("Mounts", mountStr.isEmpty ? "–" : mountStr),
            ("Networks", container.networks.isEmpty ? "–" : container.networks.joined(separator: ", ")),
            ("Environment", container.environment.isEmpty ? "–"
                             : "\(container.environment[0])\(container.environment.count > 1 ? " (+\(container.environment.count - 1))" : "")")
        ]
    }

    var body: some View {
        InspectTable(
            rows: rows,
            monospacedKeys: ["Image digest", "Container ID", "Command", "Ports", "Mounts"]
        )
    }
}

// MARK: - Logs Tab

private struct LogsTab: View {
    let container: Container
    @State private var source: LogStreamer.LogSource = .stdio

    var body: some View {
        // `id` folds in the source so switching Output ↔ Boot restarts the stream task.
        LogStreamView(id: "\(container.id)-\(source.rawValue)", stream: { onLine in
            try await LogStreamer.stream(
                source: source,
                fetch: { try await ContainerClient().logs(id: container.id) },
                onLine: onLine
            )
        }, source: $source)
    }
}

private struct MetricCard: View {
    let label: String
    let value: String
    let trend: String
    let trendColor: Color
    let data: [Double]
    let lineColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(trend)
                    .font(.caption)
                    .foregroundStyle(trendColor)
            }

            Text(value)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)

            if data.count >= 2 {
                Chart(Array(data.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(lineColor.opacity(0.15))
                    LineMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(lineColor)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 50)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(lineColor.opacity(0.08))
                    .frame(height: 50)
                    .overlay {
                        Text("Collecting…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
    }
}

// MARK: - Terminal Not Running

private struct TerminalNotRunningTab: View {
    var body: some View {
        TerminalUnavailableView(message: "Start the container to open a shell.")
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: ContainerStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.systemImage)
                .imageScale(.small)
            Text(status.label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(status.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.color.opacity(0.12), in: Capsule())
    }
}

/// Small "DEFAULT" tag for the machine `container machine run` targets when no ID is given —
/// same visual treatment as the networks list's chip for the built-in default network, so
/// "default-ness" reads identically across resource kinds. Shared by the compute list row and
/// the machine detail header.
struct DefaultChip: View {
    var body: some View {
        TintedChip(text: "DEFAULT", color: .secondary)
    }
}

// MARK: - Detail Tab Picker

/// Segmented switcher for the detail panes (Overview/Logs/Terminal), shared by the container
/// and machine detail views. A native segmented control rather than a custom underline tab
/// strip — keyboard focus, VoiceOver, and appearance come for free.
struct DetailTabPicker<Tab: Hashable & RawRepresentable & CaseIterable>: View
    where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    @Binding var selection: Tab

    var body: some View {
        Picker("View", selection: $selection) {
            ForEach(Array(Tab.allCases), id: \.self) { t in
                Text(t.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }
}

// MARK: - Preview

#Preview {
    let mock = MockContainerService()
    ContainerDetailView(containerID: mock.containers[0].id)
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 760, height: 600)
}

// Separate preview for a stopped container to verify Start button shows correctly
#Preview("Stopped container") {
    let mock = MockContainerService()
    ContainerDetailView(containerID: mock.containers[4].id) // worker is stopped
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 760, height: 600)
}
