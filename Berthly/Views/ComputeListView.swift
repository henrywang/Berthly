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
    @Environment(MenuBarBridge.self) private var bridge
    @Binding var selection: ComputeItem?
    @State private var filterText = ""
    @State private var isSearchPresented = false
    @State private var deleteTarget: ComputeItem?
    @State private var deleteErrorMessage: String?

    var body: some View {
        let query = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        let containers = service.containers.filter { matches($0.name, $0.image, query: query) }
        let machines   = service.machines.filter { !$0.isUtility && matches($0.name, $0.image, query: query) }

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
        let hasAnyResources = !service.containers.isEmpty || service.machines.contains { !$0.isUtility }

        Group {
            if !hasAnyResources {
                ContentUnavailableView {
                    Label("No Compute Resources", systemImage: "shippingbox")
                } description: {
                    Text("Run a container or create a machine to get started.")
                } actions: {
                    // Same intents the menu bar and Container menu use — MainWindowView owns the
                    // sheets, so the empty state can't present them directly.
                    Button("Run Container…") { bridge.pendingIntent = .openRunContainerSheet }
                        .buttonStyle(.borderedProminent)
                    Button("Create Machine…") { bridge.pendingIntent = .openCreateMachineSheet }
                }
            } else if runningCount == 0 && stoppedCount == 0 {
                ContentUnavailableView.search(text: filterText)
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
                // ⌫ on a selected, stopped row — same confirm-then-delete flow as the row's
                // hover trash button and context menu, just reached by keyboard.
                .onDeleteCommand { deleteTarget = deletableSelection }
            }
        }
        .searchable(text: $filterText, isPresented: $isSearchPresented, prompt: "Filter by name or image")
        .onChange(of: bridge.searchFocusToken) { _, _ in isSearchPresented = true }
        .navigationTitle("Compute")
        .confirmationDialog(deleteConfirmTitle, isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("This action cannot be undone.")
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

    private func matches(_ name: String, _ detail: String, query: String) -> Bool {
        query.isEmpty || name.lowercased().contains(query) || detail.lowercased().contains(query)
    }

    /// The current selection, if it's something ⌫ may delete: running items are protected here
    /// exactly like their hover trash buttons are disabled.
    private var deletableSelection: ComputeItem? {
        switch selection {
        case .container(let id):
            guard let c = service.containers.first(where: { $0.id == id }), c.status != .running else { return nil }
            return selection
        case .machine(let id):
            guard let m = service.machines.first(where: { $0.id == id }), m.status != .running else { return nil }
            return selection
        case nil:
            return nil
        }
    }

    private var deleteConfirmTitle: String {
        switch deleteTarget {
        case .container(let id):
            let name = service.containers.first(where: { $0.id == id })?.name ?? id
            return "Delete \(name)?"
        case .machine(let id):
            let name = service.machines.first(where: { $0.id == id })?.name ?? id
            return "Delete \(name)?"
        case nil:
            return ""
        }
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        Task {
            do {
                switch target {
                case .container(let id): try await service.deleteContainer(id)
                case .machine(let id):   try await service.deleteMachine(id)
                }
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
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
            StatusGlyph(status: container.status)

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
        // The full action set, reachable by right-click — the hover trash icon alone isn't
        // discoverable and doesn't exist in the accessibility tree until hover, so this is also
        // the VoiceOver path to row actions.
        .contextMenu {
            if container.status == .running {
                Button("Stop") { perform { try await service.stopContainer(container.id) } }
                Button("Restart") { perform { try await service.restartContainer(container.id) } }
            } else {
                Button("Start") { perform { try await service.startContainer(container.id) } }
            }
            Divider()
            Button("Copy Name") { copyToPasteboard(container.name) }
            Button("Copy Container ID") { copyToPasteboard(container.id) }
            Button("Copy Image Reference") { copyToPasteboard(container.image) }
            Divider()
            Button("Delete…", role: .destructive) { showDeleteConfirm = true }
                .disabled(container.status == .running)
        }
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

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
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
            StatusGlyph(status: machine.status)

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
        .contextMenu {
            if machine.status == .running {
                Button("Stop") { perform { try await service.stopMachine(machine.id) } }
            } else {
                Button("Start") { perform { try await service.startMachine(machine.id) } }
            }
            Divider()
            Button("Copy Name") { copyToPasteboard(machine.name) }
            Button("Copy Machine ID") { copyToPasteboard(machine.id) }
            Divider()
            Button("Delete…", role: .destructive) { showDeleteConfirm = true }
                .disabled(machine.status == .running)
        }
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

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Status glyph

/// Per-row state indicator: without it, status only exists as section membership, so an
/// errored or paused container is indistinguishable from a plainly stopped one. Reuses the
/// shape+color coding from `ContainerStatus` (shapes carry the meaning for colorblind users).
private struct StatusGlyph: View {
    let status: ContainerStatus

    var body: some View {
        Image(systemName: status.systemImage)
            .font(.system(size: 9))
            .foregroundStyle(status.color)
            .frame(width: 12)
            .accessibilityLabel(status.label)
    }
}

// MARK: - Section headers

// Two header levels stack here (RUNNING/STOPPED over CONTAINERS/MACHINES); the section level
// is stronger (secondary vs tertiary) and the type level indents under it so they don't read
// as the same hierarchy at a glance.
private struct ComputeSectionHeader: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

private struct ComputeTypeHeader: View {
    let text: LocalizedStringKey
    let systemImage: String
    init(_ text: LocalizedStringKey, systemImage: String) {
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
            .padding(.leading, 8)
    }
}

// MARK: - Preview

// Wrapped in NavigationStack so `.searchable` has a navigation container to place its field in,
// matching the NavigationSplitView the real app provides.
#Preview {
    @Previewable @State var selection: ComputeItem? = nil
    NavigationStack {
        ComputeListView(selection: $selection)
    }
    .environment(MockContainerService() as ContainerServiceBase)
    .environment(MenuBarBridge())
    .frame(width: 320, height: 500)
}

#Preview("Empty") {
    @Previewable @State var selection: ComputeItem? = nil
    let mock = MockContainerService()
    mock.containers.removeAll()
    mock.machines.removeAll()
    return ComputeListView(selection: $selection)
        .environment(mock as ContainerServiceBase)
        .environment(MenuBarBridge())
        .frame(width: 400, height: 500)
}
