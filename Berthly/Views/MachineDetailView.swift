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
                    case .terminal:
                        TerminalPlaceholder()
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

            if machine.status == .running {
                Button(role: .destructive) { showStopConfirm = true } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .tint(.statusError)
                .disabled(isWorking)
                .help("Stop")

                Button { tab = .terminal } label: {
                    Label("Shell", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help("Shell")
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
            HStack(spacing: 12) {
                StatCard(
                    label: "Disk",
                    value: String(format: "%.1f GB", machine.diskUsedGB),
                    detail: String(format: "of %.1f GB · %d%%", machine.diskTotalGB,
                                   Int(machine.diskUsagePercent * 100))
                )
                StatCard(
                    label: "Resources",
                    value: machine.resources,
                    detail: "allocated"
                )
                StatCard(
                    label: "Uptime",
                    value: machine.status == .running ? machine.uptimeString : "–",
                    detail: machine.status == .running ? "since boot" : "not running"
                )
                StatCard(
                    label: "Created",
                    value: machine.created,
                    detail: "date created"
                )
            }
            InspectSection(machine: machine)
        }
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
                .lineLimit(1)
                .minimumScaleFactor(0.7)
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

// MARK: - Terminal Placeholder

private struct TerminalPlaceholder: View {
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
                Text("Interactive shell support is coming in M3.")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                Text("Coming in M3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule())
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
