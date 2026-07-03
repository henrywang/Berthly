import SwiftUI

// Typed entry wrappers carry the section+type-prefixed ForEach identity so that:
// (a) a container and machine sharing the same underlying id never collide in the list, and
// (b) moving between RUNNING/STOPPED sections is a delete+insert, not an in-place move.
// The embedded value lets rows render without a separate @Environment lookup.
private struct ContainerEntry: Identifiable {
    let id: String   // "rc-<containerID>" or "sc-<containerID>"
    let container: Container
    var tag: ComputeItem { .container(container.id) }
}

private struct MachineEntry: Identifiable {
    let id: String   // "rm-<machineID>" or "sm-<machineID>"
    let machine: Machine
    var tag: ComputeItem { .machine(machine.id) }
}

struct ComputeListView: View {
    @Environment(ContainerServiceBase.self) private var service
    @Binding var selection: ComputeItem?

    var body: some View {
        let containers = service.containers
        let machines   = service.machines.filter { !$0.isUtility }

        let runningContainerEntries = containers.filter { $0.status == .running }
                                                .map { ContainerEntry(id: "rc-\($0.id)", container: $0) }
        let stoppedContainerEntries = containers.filter { $0.status != .running }
                                                .map { ContainerEntry(id: "sc-\($0.id)", container: $0) }
        let runningMachineEntries   = machines.filter { $0.status == .running }
                                              .map { MachineEntry(id: "rm-\($0.id)", machine: $0) }
        let stoppedMachineEntries   = machines.filter { $0.status != .running }
                                              .map { MachineEntry(id: "sm-\($0.id)", machine: $0) }

        let runningCount = runningContainerEntries.count + runningMachineEntries.count
        let stoppedCount = stoppedContainerEntries.count + stoppedMachineEntries.count

        if runningCount == 0 && stoppedCount == 0 {
            ContentUnavailableView {
                Label("No Compute Resources", systemImage: "shippingbox")
            } description: {
                Text("Run a container or create a machine to get started.")
            }
            .navigationTitle("Compute")
        } else {
            List(selection: $selection) {
                if runningCount > 0 {
                    Section {
                        if !runningContainerEntries.isEmpty {
                            ComputeTypeHeader("CONTAINERS", systemImage: "shippingbox")
                            ForEach(runningContainerEntries) { entry in
                                ContainerComputeRow(container: entry.container)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        if !runningMachineEntries.isEmpty {
                            ComputeTypeHeader("MACHINES", systemImage: "desktopcomputer")
                            ForEach(runningMachineEntries) { entry in
                                MachineComputeRow(machine: entry.machine)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    } header: { ComputeSectionHeader("RUNNING \(runningCount)") }
                }
                if stoppedCount > 0 {
                    Section {
                        if !stoppedContainerEntries.isEmpty {
                            ComputeTypeHeader("CONTAINERS", systemImage: "shippingbox")
                            ForEach(stoppedContainerEntries) { entry in
                                ContainerComputeRow(container: entry.container)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        if !stoppedMachineEntries.isEmpty {
                            ComputeTypeHeader("MACHINES", systemImage: "desktopcomputer")
                            ForEach(stoppedMachineEntries) { entry in
                                MachineComputeRow(machine: entry.machine)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    } header: { ComputeSectionHeader("STOPPED \(stoppedCount)") }
                }
            }
            .navigationTitle("Compute")
        }
    }
}

// MARK: - Container row

private struct ContainerComputeRow: View {
    let container: Container
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(.body, design: .default, weight: .medium))
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(container.status == .running ? Color.secondary : Color.red)
                }
                .buttonStyle(.hoverIcon)
                .disabled(container.status == .running)
                .help(container.status == .running ? "Stop the container first" : "Delete Container")
            } else if !container.portsDisplayString.isEmpty {
                Text(container.portsDisplayString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(isDeleting ? 0.4 : 1)
        .onHover { isHovered = $0 }
        .alert("Delete \(container.name)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                isDeleting = true
                Task {
                    do { try await service.deleteContainer(container.id) }
                    catch { errorMessage = error.localizedDescription }
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
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

// MARK: - Machine row

private struct MachineComputeRow: View {
    let machine: Machine
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.system(.body, design: .default, weight: .medium))
                Text(machine.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(machine.status == .running ? Color.secondary : Color.red)
                }
                .buttonStyle(.hoverIcon)
                .disabled(machine.status == .running)
                .help(machine.status == .running ? "Stop the machine first" : "Delete Machine")
            } else {
                Text(machine.resources)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .opacity(isDeleting ? 0.4 : 1)
        .onHover { isHovered = $0 }
        .alert("Delete \(machine.name)?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                isDeleting = true
                Task {
                    do { try await service.deleteMachine(machine.id) }
                    catch { errorMessage = error.localizedDescription }
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
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

// MARK: - Section headers

private struct ComputeSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(nil)
    }
}

private struct ComputeTypeHeader: View {
    let text: String
    let systemImage: String
    init(_ text: String, systemImage: String) {
        self.text = text
        self.systemImage = systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .imageScale(.small)
            .textCase(nil)
            .listRowSeparator(.hidden)
            .padding(.top, 4)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selection: ComputeItem? = nil
    ComputeListView(selection: $selection)
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 320, height: 500)
}
