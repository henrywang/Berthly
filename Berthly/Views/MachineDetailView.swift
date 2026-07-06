import MachineAPIClient
import SwiftUI

// MARK: - Machine Detail View

struct MachineDetailView: View {
    let machineID: String
    @Environment(ContainerServiceBase.self) private var service

    var body: some View {
        if service.machines.contains(where: { $0.id == machineID }) {
            MachineDetailContent(machineID: machineID)
        } else {
            ContentUnavailableView("Machine not found", systemImage: "desktopcomputer")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MachineDetailContent: View {
    let machineID: String
    @Environment(ContainerServiceBase.self) private var service
    @State private var tab: DetailTab    = .overview
    @State private var isWorking         = false
    @State private var errorMessage: String?
    @State private var showStopConfirm   = false

    private var machine: Machine? {
        service.machines.first(where: { $0.id == machineID })
    }

    enum DetailTab: String, CaseIterable {
        case overview = "Overview"
        case logs     = "Logs"
        case terminal = "Terminal"
    }

    var body: some View {
        if let machine {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(machine)
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
                            OverviewTab(machine: machine).padding(24)
                        }
                    case .logs:
                        // Available whether the machine is running or stopped — the boot/console
                        // log is most useful precisely when a machine failed to start and the
                        // Terminal tab can't help.
                        MachineLogsTab(machineID: machine.id)
                    case .terminal:
                        if machine.status == .running {
                            TerminalHostView(target: .machine(id: machine.id))
                                .id(machine.id)
                        } else {
                            TerminalNotRunning()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationTitle(machine.name)
            .alert("Stop \(machine.name)?", isPresented: $showStopConfirm) {
                Button("Stop", role: .destructive) { run { try await service.stopMachine(machine.id) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The virtual machine will be shut down.")
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

    // MARK: - Header

    private func detailHeader(_ machine: Machine) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Text(machine.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                    StatusBadge(status: machine.status)
                }
                Text(machine.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)

            Button { service.togglePinMachine(machine.id) } label: {
                Image(systemName: service.isMachinePinned(machine.id) ? "pin.fill" : "pin")
                    .foregroundStyle(service.isMachinePinned(machine.id) ? Color(hex: "F59E0B") : Color.secondary)
            }
            .buttonStyle(.bordered)
            .help(service.isMachinePinned(machine.id) ? "Unpin" : "Pin")
            .hoverScale()

            if machine.status == .running {
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
                    run { try await service.startMachine(machine.id) }
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
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
            isWorking = false
        }
    }
}

// MARK: - Overview Tab

private struct OverviewTab: View {
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            BootPipelineSection(machine: machine)
            DiskCapacitySection(machine: machine)
            MountsSection(machine: machine)
            InspectSection(machine: machine)
        }
    }
}

// MARK: - Boot pipeline

private struct BootPipelineSection: View {
    let machine: Machine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BOOT PIPELINE")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                PipelineBox(
                    icon: "square.3.layers.3d",
                    label: "OCI IMAGE",
                    title: machine.image,
                    caption: "pulled · read-only"
                )
                PipelineArrow(topLabel: "extract", bottomLabel: "create")
                PipelineBox(
                    icon: "cylinder.fill",
                    label: "PERSISTENT DISK",
                    title: "rootfs.ext4",
                    caption: String(format: "%.1f GB · survives restarts", machine.diskTotalGB),
                    accented: true
                )
                PipelineArrow(topLabel: "boot", bottomLabel: "kernel.bin")
                PipelineBox(
                    icon: "desktopcomputer",
                    label: "LIGHTWEIGHT VM",
                    title: machine.name,
                    caption: machine.status == .running
                        ? "systemd · Running · up \(machine.uptimeString)"
                        : "systemd · Stopped",
                    statusRunning: machine.status == .running
                )
            }
            .padding(16)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct PipelineBox: View {
    let icon: String
    let label: String
    let title: String
    let caption: String
    var accented: Bool = false
    var statusRunning: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(accented ? Color.berthlyAccent : Color.secondary)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accented ? Color.berthlyAccent : Color.secondary)
                Spacer(minLength: 4)
                if let statusRunning {
                    Circle()
                        .fill(statusRunning ? Color.statusRunning : Color.secondary.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
            Text(title)
                .font(.system(.callout, design: .monospaced, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accented ? Color.berthlyAccent.opacity(0.5) : Color.secondary.opacity(0.2),
                              lineWidth: accented ? 1.5 : 1)
        )
    }
}

private struct PipelineArrow: View {
    let topLabel: String
    let bottomLabel: String

    var body: some View {
        VStack(spacing: 2) {
            Text(topLabel)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            HStack(spacing: 2) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 20, height: 1.5)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Text(bottomLabel)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }
}

// MARK: - Disk capacity

private struct DiskCapacitySection: View {
    let machine: Machine

    var body: some View {
        HStack {
            Text("DISK")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(String(format: "%.1f GB capacity", machine.diskTotalGB))
                .font(.callout.weight(.medium))
                .fontDesign(.rounded)
        }
    }
}

// MARK: - Mounts

private struct MountsSection: View {
    let machine: Machine

    private struct MountRow: Identifiable {
        let id: String
        let icon: String
        let path: String
        let caption: String
        let readOnly: Bool
    }

    private var rows: [MountRow] {
        var result = [
            MountRow(id: "sbin", icon: "wrench.and.screwdriver", path: "/sbin.machine",
                      caption: "injected init helper", readOnly: true)
        ]
        switch machine.homeMount {
        case .readWrite:
            result.append(MountRow(id: "home", icon: "house.fill", path: "~", caption: "your macOS home", readOnly: false))
        case .readOnly:
            result.append(MountRow(id: "home", icon: "house.fill", path: "~", caption: "your macOS home", readOnly: true))
        case .none:
            break
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MOUNTS · VIRTIOFS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            VStack(spacing: 0) {
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Image(systemName: row.icon)
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.path)
                                .font(.system(.callout, design: .monospaced, weight: .medium))
                            Text(row.caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.readOnly ? "RO" : "RW")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (row.readOnly ? Color.statusPaused : Color.berthlyAccent).opacity(0.15),
                                in: Capsule()
                            )
                            .foregroundStyle(row.readOnly ? Color.statusPaused : Color.berthlyAccent)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)

                    if row.id != rows.last?.id {
                        Divider().padding(.horizontal, 14)
                    }
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

private struct InspectSection: View {
    let machine: Machine

    private var rows: [(String, String)] {
        [
            ("Status",    machine.status.label),
            ("Image",     machine.image),
            ("Machine ID", machine.id),
            ("Resources", machine.resources),
            ("Kernel",    machine.kernel),
            ("Created",   machine.created),
            ("Disk",      String(format: "%.1f / %.1f GB", machine.diskUsedGB, machine.diskTotalGB)),
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
                            .fontDesign(["Machine ID", "Kernel"].contains(key) ? .monospaced : .default)
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

private struct MachineLogsTab: View {
    let machineID: String

    var body: some View {
        LogStreamView(id: machineID) { onLine in
            try await LogStreamer.stream(
                fetch: { try await MachineClient().logs(id: machineID) },
                onLine: onLine
            )
        }
    }
}

// MARK: - Terminal Placeholder

private struct TerminalNotRunning: View {
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
                Text("Start the machine to open a shell.")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview {
    let mock = MockContainerService()
    MachineDetailView(machineID: mock.machines[0].id)
        .environment(mock as ContainerServiceBase)
        .frame(width: 680, height: 560)
}

#Preview("Stopped machine") {
    let mock = MockContainerService()
    MachineDetailView(machineID: mock.machines[1].id) // ci-runner is stopped
        .environment(mock as ContainerServiceBase)
        .frame(width: 680, height: 560)
}
