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
                            // Containers first, then machines — the per-row type glyph carries the
                            // kind now (no CONTAINERS/MACHINES sub-header), and keeping the two
                            // kinds contiguous gives soft clustering without a header row.
                            ForEach(runningContainerEntries) { entry in
                                ContainerComputeRow(container: entry.container, selection: $selection)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                            ForEach(runningMachineEntries) { entry in
                                MachineComputeRow(machine: entry.machine, selection: $selection)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                        } header: { ComputeSectionHeader("RUNNING \(runningCount)") }
                    }
                    if stoppedCount > 0 {
                        Section {
                            ForEach(stoppedContainerEntries) { entry in
                                ContainerComputeRow(container: entry.container, selection: $selection)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                            ForEach(stoppedMachineEntries) { entry in
                                MachineComputeRow(machine: entry.machine, selection: $selection)
                                    .tag(entry.tag)
                                    .listRowSeparator(.hidden)
                            }
                        } header: { ComputeSectionHeader("STOPPED \(stoppedCount)") }
                    }
                }
                // Kill the hairline AppKit draws under the pinned first section header — see
                // NonFloatingListHeaders.
                .nonFloatingSectionHeaders()
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
        .errorAlert($deleteErrorMessage)
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
        if selection == target { selection = nil }
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
    // Clearing selection here (mirroring the list's performDelete) collapses the detail pane
    // when the selected container is deleted from the row — otherwise it strands on "not found".
    @Binding var selection: ComputeItem?
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var isRunning: Bool { container.status == .running }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TypeStatusGlyph(typeSystemImage: "shippingbox", status: container.status, dimmed: !isRunning)
                .frame(width: computeGlyphWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(container.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    // Stopped rows recede into the background (paired with the dimmed glyph); the
                    // full-strength status badge is what still flags a crashed one.
                    .foregroundStyle(isRunning ? Color.primary : Color.secondary)
                    // Unambiguous handle for the sidebar row (E2E lifecycle journey): the
                    // detail view shows the same name, so tests can't query by text alone.
                    .accessibilityIdentifier("computeRow-\(container.name)")
                Text(container.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                if !isRunning {
                    Button { perform { try await service.startContainer(container.id) } } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.hoverIcon)
                    .help("Start Container")
                    .accessibilityLabel("Start")
                }
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
            // No accessibilityIdentifier: it doesn't survive the SwiftUI→NSMenu bridge for
            // context-menu items — tests query menuItems["Delete…"] by label instead.
            Button("Delete…", role: .destructive) { showDeleteConfirm = true }
                .disabled(container.status == .running)
        }
        .alert("Delete \(container.name)?", isPresented: $showDeleteConfirm) {
            // Identifier because a bare buttons["Delete"] would also match the context-menu
            // item (identifier-OR-label matching) — the E2E lifecycle journey drives this.
            Button("Delete", role: .destructive) {
                isDeleting = true
                if selection == .container(container.id) { selection = nil }
                Task {
                    do { try await service.deleteContainer(container.id) }
                    catch { errorMessage = error.localizedDescription }
                    isDeleting = false
                }
            }
            .accessibilityIdentifier("containerDeleteConfirmButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .errorAlert($errorMessage)
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
    // Clearing selection here (mirroring the list's performDelete) collapses the detail pane
    // when the selected machine is deleted from the row — otherwise it strands on "not found".
    @Binding var selection: ComputeItem?
    @Environment(ContainerServiceBase.self) private var service
    @State private var isHovered = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    private var isRunning: Bool { machine.status == .running }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            TypeStatusGlyph(typeSystemImage: "desktopcomputer", status: machine.status, dimmed: !isRunning)
                .frame(width: computeGlyphWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(machine.name)
                    .font(.system(.body, design: .default, weight: .medium))
                    // Stopped rows recede into the background — see ContainerComputeRow.
                    .foregroundStyle(isRunning ? Color.primary : Color.secondary)
                    // Same rationale as computeRow-: the detail view repeats the name.
                    .accessibilityIdentifier("machineRow-\(machine.name)")
                Text(machine.image)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
            }

            Spacer()

            if isHovered {
                if !isRunning {
                    Button { perform { try await service.startMachine(machine.id) } } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.hoverIcon)
                    .help("Start Machine")
                    .accessibilityLabel("Start")
                }
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
                if selection == .machine(machine.id) { selection = nil }
                Task {
                    do { try await service.deleteMachine(machine.id) }
                    catch { errorMessage = error.localizedDescription }
                    isDeleting = false
                }
            }
            .accessibilityIdentifier("machineDeleteConfirmButton")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .errorAlert($errorMessage)
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Layout

// Shared leading width for both row kinds' `TypeStatusGlyph`, so container and machine names
// start in the same column even though the glyph + corner badge is wider than the text after it.
private let computeGlyphWidth: CGFloat = 22

// MARK: - Section header

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
