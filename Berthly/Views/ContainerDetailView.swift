import Charts
import ContainerAPIClient
import ContainerResource
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
    @State private var tab: DetailTab = .overview
    @State private var isWorking    = false
    @State private var errorMessage: String?
    @State private var showStopConfirm   = false

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
        case stats    = "Stats"
        case terminal = "Terminal"
        case files    = "Files"
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

            HStack(spacing: 0) {
                ForEach(DetailTab.allCases, id: \.self) { t in
                    Button(t.rawValue) { tab = t }
                        .buttonStyle(TabButtonStyle(isSelected: tab == t))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            Divider()

            Group {
                switch tab {
                case .overview:
                    ScrollView {
                        OverviewTab(container: container).padding(24)
                    }
                case .logs:
                    LogsTab(container: container)
                case .stats:
                    ScrollView {
                        StatsTab(container: container).padding(24)
                    }
                case .terminal:
                    if container.status == .running {
                        TerminalHostView(target: .container(id: container.id))
                            .id(container.id)
                    } else {
                        TerminalNotRunningTab()
                    }
                case .files:
                    FilesPlaceholderTab()
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle(container.name)
        .alert("Stop \(container.name)?", isPresented: $showStopConfirm) {
            Button("Stop", role: .destructive) { run { try await service.stopContainer(container.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The container process will be terminated.")
        }
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        } // end if let container
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
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
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

            if container.status == .running {
                Button(role: .destructive) { showStopConfirm = true } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .tint(.statusError)
                .disabled(isWorking)
                .help("Stop")
                .hoverScale()
            } else {
                Button {
                    run {
                        try await service.startContainer(container.id)
                        tab = .terminal
                    }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .tint(.berthlyAccent)
                .disabled(isWorking)
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

private struct OverviewTab: View {
    let container: Container

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                StatCard(
                    label: "CPU",
                    value: container.cpuPercent > 0 ? "\(Int(container.cpuPercent))%" : "–",
                    detail: "of \(ProcessInfo.processInfo.processorCount) cores"
                )
                StatCard(
                    label: "Memory",
                    value: container.memoryMB > 0 ? "\(container.memoryMB) MB" : "–",
                    detail: "limit \(container.memoryLimitMB) MB"
                )
                StatCard(
                    label: "Ports",
                    value: container.ports.isEmpty ? "–"
                         : container.ports.count == 1 ? container.ports[0].displayString
                         : "\(container.ports.count) ports",
                    detail: container.ports.isEmpty ? "none exposed"
                          : container.ports.count == 1 ? "1 published"
                          : container.ports.map(\.displayString).joined(separator: ", ")
                )
                StatCard(
                    label: "Uptime",
                    value: container.uptime,
                    detail: container.startedDate.map { "since \(timeLabel($0))" } ?? "–"
                )
            }
            InspectSection(container: container)
        }
    }

    private func timeLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct InspectSection: View {
    let container: Container

    private var rows: [(String, String)] {
        let mountStr = container.mounts.map(\.displayString).joined(separator: "\n")
        return [
            ("Status",       "\(container.status.label)\(container.status == .running ? " · up \(container.uptime)" : "")"),
            ("Image",        container.image),
            ("Container ID", container.id),
            ("Command",      container.command),
            ("Ports",        container.ports.isEmpty ? "–" : container.ports.map(\.displayString).joined(separator: ", ")),
            ("Mounts",       mountStr.isEmpty ? "–" : mountStr),
            ("Networks",     container.networks.isEmpty ? "–" : container.networks.joined(separator: ", ")),
            ("Environment",  container.environment.isEmpty ? "–"
                             : "\(container.environment[0])\(container.environment.count > 1 ? " (+\(container.environment.count - 1))" : "")"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("INSPECT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { key, val in
                    HStack(alignment: .top, spacing: 0) {
                        Text(key)
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(val)
                            .fontDesign(["Container ID", "Command", "Ports", "Mounts"].contains(key) ? .monospaced : .default)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)

                    if key != rows.last?.0 {
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Logs Tab

private struct LogsTab: View {
    let container: Container

    var body: some View {
        LogStreamView(id: container.id, stream: Self.streamContainerLogs(id: container.id))
    }

    /// Adapts `ContainerClient().logs(id:)`'s FileHandle-based read/follow loop to
    /// `LogStreamView`'s per-line callback signature.
    private static func streamContainerLogs(id: String) -> (@escaping @MainActor (String) -> Void) async throws -> Void {
        { onLine in
            let fhs = try await ContainerClient().logs(id: id)
            guard let fh = fhs.first else { return }

            // Read existing content off the main actor so we don't block the UI
            let existing = await Task.detached(priority: .utility) {
                fh.readDataToEndOfFile()
            }.value
            if let text = String(data: existing, encoding: .utf8), !text.isEmpty {
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    onLine(line)
                }
            }

            // Follow new data
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                let data = await Task.detached(priority: .utility) { fh.availableData }.value
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { continue }
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    onLine(line)
                }
            }
        }
    }
}

// MARK: - Stats Tab

private struct StatsTab: View {
    let container: Container

    struct StatsPoint: Identifiable {
        let id   = UUID()
        let index: Int
        let cpu:   Double
        let memMB: Double
        let netMBs: Double
    }

    @State private var history: [StatsPoint] = []

    private var latestCPU:  Double { history.last?.cpu    ?? 0 }
    private var latestMem:  Double { history.last?.memMB  ?? 0 }
    private var latestNet:  Double { history.last?.netMBs ?? 0 }

    private var avgCPU:  Double { history.isEmpty ? 0 : history.map(\.cpu).reduce(0, +) / Double(history.count) }
    private var peakCPU: Double { history.map(\.cpu).max() ?? 0 }

    private func trend(for values: [Double]) -> (String, Color) {
        guard values.count >= 6 else { return ("stable", .secondary) }
        let delta = values.last! - values[values.count - 6]
        if delta >  2 { return ("▲ \(String(format: "%.0f", delta))",  Color.statusRunning) }
        if delta < -2 { return ("▼ \(String(format: "%.0f", -delta))", Color.secondary) }
        return ("stable", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if container.status != .running {
                Spacer()
                ContentUnavailableView("Stats unavailable", systemImage: "chart.xyaxis.line")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                let cpuVals = history.map(\.cpu)
                let memVals = history.map(\.memMB)
                let netVals = history.map(\.netMBs)
                let cpuTrend = trend(for: cpuVals)
                let memTrend = trend(for: memVals)
                let netTrend = trend(for: netVals)

                HStack(spacing: 12) {
                    MetricCard(
                        label: "CPU",
                        value: "\(Int(latestCPU))%",
                        trend: cpuTrend.0, trendColor: cpuTrend.1,
                        data: cpuVals, lineColor: .berthlyAccent
                    )
                    MetricCard(
                        label: "Memory",
                        value: "\(Int(latestMem)) MB",
                        trend: memTrend.0, trendColor: memTrend.1,
                        data: memVals, lineColor: .purple
                    )
                    MetricCard(
                        label: "Network",
                        value: String(format: "%.1f MB/s", latestNet),
                        trend: netTrend.0, trendColor: netTrend.1,
                        data: netVals, lineColor: .statusRunning
                    )
                }

                // Full CPU chart
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("CPU — last 5 min")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("avg \(Int(avgCPU))%  ·  peak \(Int(peakCPU))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)

                    if history.count >= 2 {
                        Chart(history) { pt in
                            AreaMark(
                                x: .value("t", pt.index),
                                y: .value("CPU%", pt.cpu)
                            )
                            .foregroundStyle(Color.berthlyAccent.opacity(0.15))
                            LineMark(
                                x: .value("t", pt.index),
                                y: .value("CPU%", pt.cpu)
                            )
                            .foregroundStyle(Color.berthlyAccent)
                        }
                        .chartXAxis(.hidden)
                        .chartYScale(domain: 0...max(10, peakCPU * 1.2))
                        .frame(height: 180)
                        .padding(.horizontal, 16)
                    } else {
                        Color.clear.frame(height: 180)
                    }

                    Spacer().frame(height: 14)
                }
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 0.5))
            }
        }
        .task(id: container.id) {
            await pollStats()
        }
    }

    private func pollStats() async {
        guard container.status == .running else { return }

        var index        = 0
        var prevCpuUsec: UInt64?
        var prevTime:    Date?
        var prevNetRx:   UInt64?
        var prevNetTx:   UInt64?

        while !Task.isCancelled {
            do {
                let s   = try await ContainerClient().stats(id: container.id)
                let now = Date()

                // CPU%: delta microseconds / elapsed microseconds / core count
                var cpuPct = 0.0
                if let cur = s.cpuUsageUsec, let prev = prevCpuUsec, let prevT = prevTime {
                    let dt = now.timeIntervalSince(prevT)
                    if dt > 0, cur >= prev {
                        cpuPct = Double(cur - prev)
                            / (dt * 1_000_000)
                            / Double(max(1, ProcessInfo.processInfo.processorCount))
                            * 100
                    }
                }
                prevCpuUsec = s.cpuUsageUsec
                prevTime    = now

                let memMB = Double(s.memoryUsageBytes ?? 0) / 1_048_576

                let curRx = s.networkRxBytes ?? 0
                let curTx = s.networkTxBytes ?? 0
                var netMBs = 0.0
                if let pRx = prevNetRx, let pTx = prevNetTx,
                   curRx >= pRx, curTx >= pTx {
                    netMBs = Double((curRx - pRx) + (curTx - pTx)) / 1_048_576
                }
                prevNetRx = curRx
                prevNetTx = curTx

                history.append(StatsPoint(index: index, cpu: cpuPct, memMB: memMB, netMBs: netMBs))
                if history.count > 150 { history.removeFirst() }
                index += 1

            } catch {
                // stats temporarily unavailable — keep polling
            }

            try? await Task.sleep(for: .seconds(2))
        }
    }
}

private struct MetricCard: View {
    let label:      String
    let value:      String
    let trend:      String
    let trendColor: Color
    let data:       [Double]
    let lineColor:  Color

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
        ZStack {
            Color.codeBackground
            VStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.codePrompt)
                Text("Terminal")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Start the container to open a shell.")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Files Placeholder

private struct FilesPlaceholderTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("File browser")
                .font(.title3.weight(.semibold))
            Text("Browse and pull files from the container's\nfilesystem. Coming in a later release.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Planned")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - Tab Button Style

struct TabButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 2)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(Color.berthlyAccent)
                        .frame(height: 2)
                        .padding(.horizontal, -2)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 10)
    }
}

// MARK: - Preview

#Preview {
    let mock = MockContainerService()
    ContainerDetailView(containerID: mock.containers[0].id)
        .environment(mock as ContainerServiceBase)
        .frame(width: 760, height: 600)
}

// Separate preview for a stopped container to verify Start button shows correctly
#Preview("Stopped container") {
    let mock = MockContainerService()
    ContainerDetailView(containerID: mock.containers[4].id) // worker is stopped
        .environment(mock as ContainerServiceBase)
        .frame(width: 760, height: 600)
}
