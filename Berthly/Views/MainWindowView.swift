// Copyright 2026 Berthly Contributors
// Licensed under the Apache License, Version 2.0

import SwiftUI
import TerminalProgress

struct MainWindowView: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(BuildJobManager.self) private var buildManager
    @State private var sidebarSelection: SidebarSelection? = .compute
    @State private var selectedCompute: ComputeItem?
    @State private var selectedImageID: String?
    @State private var selectedVolumeID: String?
    @State private var selectedNetworkID: String?
    @State private var isRefreshing = false
    @State private var refreshRotation = 0.0
    @State private var showPullSheet = false
    @State private var showBuildSheet = false
    @State private var showRunMenu = false
    @State private var showRunSheet = false
    @State private var showMachineCreateSheet = false
    @State private var showVolumeCreateSheet = false
    @State private var showNetworkCreateSheet = false
    @State private var showAddRegistrySheet = false
    @State private var loadImageRequest: ImageLoadRequest?
    @State private var showBuildsPopover = false
    @State private var viewedBuildJob: BuildJob?
    @State private var showCommandPalette = false
    /// Last `commandPaletteToken` this window has acted on, so a ⌘K that predates the window's mount
    /// is presented exactly once via `.onAppear` (see `presentPaletteIfRequested()`).
    @State private var lastPaletteToken = 0
    /// The compute item a palette "Delete" action wants to remove, pending confirmation. `nil` when
    /// no delete is in flight.
    @State private var pendingDelete: ComputeItem?
    @State private var deleteErrorMessage: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 260)
        } detail: {
            HStack(spacing: 0) {
                DaemonGateView { contentPane }
                    .id(sidebarSelection)
                    .frame(minWidth: 200, idealWidth: 260, maxWidth: detailVisible ? 300 : .infinity)

                if let item = selectedCompute {
                    Divider()
                    Group {
                        switch item {
                        case .container(let id):
                            ContainerDetailView(containerID: id)
                        case .machine(let id):
                            MachineDetailView(machineID: id)
                        }
                    }
                    .frame(minWidth: 320, idealWidth: 480)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .leading)
                    ))
                }
                if let id = selectedImageID, sidebarSelection == .images {
                    Divider()
                    ImageDetailView(imageID: id)
                        .frame(minWidth: 320, idealWidth: 480)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                }
                if let id = selectedVolumeID, sidebarSelection == .volumes {
                    Divider()
                    VolumeDetailView(volumeID: id, onDelete: { selectedVolumeID = nil })
                        .frame(minWidth: 320, idealWidth: 480)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                }
                if let id = selectedNetworkID, sidebarSelection == .networks {
                    Divider()
                    NetworkDetailView(networkID: id, onDelete: { selectedNetworkID = nil })
                        .frame(minWidth: 320, idealWidth: 480)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing),
                            removal: .move(edge: .leading)
                        ))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: selectedCompute)
            .animation(.easeInOut(duration: 0.25), value: selectedImageID)
            .animation(.easeInOut(duration: 0.25), value: selectedVolumeID)
            .animation(.easeInOut(duration: 0.25), value: selectedNetworkID)
            .onChange(of: service.isConnected) { _, connected in
                if !connected {
                    selectedCompute = nil; selectedImageID = nil
                    selectedVolumeID = nil; selectedNetworkID = nil
                }
            }
            .onChange(of: sidebarSelection) { _, _ in
                selectedCompute = nil
                selectedImageID = nil
                selectedVolumeID = nil
                selectedNetworkID = nil
            }
            // `.onChange` only fires on a value change *after* this view is already observing it —
            // if the menu bar sets `pendingIntent` in the same beat it creates a fresh window (the
            // window was previously fully closed), this view mounts with the intent already set,
            // and `.onChange` would never fire for it. `.onAppear` catches that case; `.onChange`
            // covers the window-already-open case where a later menu bar action changes it.
            .onAppear { handlePendingIntent() }
            .onChange(of: bridge.pendingIntent) { _, _ in handlePendingIntent() }
        }
        .navigationTitle("Berthly")
        // ⎋ backs out one level: close the palette if it's up, else collapse the detail pane by
        // clearing the selection. A hidden key-equivalent button, not `.onExitCommand` — key
        // equivalents resolve window-wide regardless of focus, while cancelOperation only reaches
        // an onExitCommand when a SwiftUI-focusable descendant currently has focus (it doesn't
        // after a palette action or a plain row click, verified empirically). Mounted only while
        // there's something to back out of, so Esc still reaches the search field's own
        // clear/cancel behavior the rest of the time. Sheets are separate key windows, so their
        // Cancel buttons keep owning Esc while presented.
        .background {
            if showCommandPalette || detailVisible {
                Button("") {
                    if showCommandPalette {
                        showCommandPalette = false
                    } else {
                        selectedCompute = nil
                        selectedImageID = nil
                        selectedVolumeID = nil
                        selectedNetworkID = nil
                    }
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showPullSheet) {
            PullImageSheet {
                showPullSheet = false
                sidebarSelection = .registries
            }
            .environment(service as ContainerServiceBase)
        }
        .sheet(isPresented: $showBuildSheet) {
            BuildImageSheet(service: service)
        }
        .sheet(isPresented: $showRunSheet) {
            RunContainerSheet(service: service)
        }
        .sheet(isPresented: $showMachineCreateSheet) {
            MachineCreateSheet(service: service)
        }
        .sheet(isPresented: $showVolumeCreateSheet) {
            VolumeCreateSheet()
        }
        .sheet(isPresented: $showNetworkCreateSheet) {
            NetworkCreateSheet()
        }
        .sheet(isPresented: $showAddRegistrySheet) {
            AddRegistrySheet()
        }
        .sheet(item: $loadImageRequest) { request in
            LoadImageSheet(archiveURL: request.url)
        }
        .sheet(item: $viewedBuildJob) { job in
            BuildImageSheet(service: service, existingJob: job)
        }
        // Lets the menu bar tell whether a main window already exists before deciding whether to
        // call `openWindow(id:)` — that API has no built-in single-instance behavior for a plain
        // `WindowGroup`, so calling it unconditionally opens a duplicate window every time.
        .onAppear {
            bridge.isMainWindowOpen = true
            // Catch a ⌘K that arrived *before* this window mounted (menu shortcut with no window
            // open): the token was already bumped, so `.onChange` won't fire for it — mirrors the
            // `.onAppear { handlePendingIntent() }` above for `pendingIntent`.
            presentPaletteIfRequested()
        }
        .onDisappear { bridge.isMainWindowOpen = false }
        // Command palette (⌘K) — a top-center overlay driven by the bridge token, so the shortcut
        // works from the menu even when it arrives before this window has mounted.
        .overlay {
            if showCommandPalette {
                CommandPaletteView(
                    commands: buildPaletteCommands(
                        isConnected: service.isConnected,
                        containers: service.containers,
                        machines: service.machines),
                    onRun: dispatch,
                    isPresented: $showCommandPalette)
            }
        }
        .onChange(of: bridge.commandPaletteToken) { _, _ in presentPaletteIfRequested() }
        // Palette "Delete" confirmation — the palette never deletes directly.
        .alert("Delete \(pendingDeleteName)?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { item in
            Button("Delete", role: .destructive) { performPendingDelete(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This can't be undone.")
        }
        .errorAlert($deleteErrorMessage, title: "Delete failed")
    }

    /// Present the palette for a ⌘K that hasn't been consumed yet. Idempotent via `lastPaletteToken`
    /// so it can run from both `.onAppear` (window mounted after the shortcut) and `.onChange`
    /// (shortcut while the window is open) without double-firing or presenting on plain launch.
    private func presentPaletteIfRequested() {
        guard bridge.commandPaletteToken != lastPaletteToken else { return }
        lastPaletteToken = bridge.commandPaletteToken
        showCommandPalette = true
    }

    /// Map a palette action onto the existing sheet/navigation/service plumbing. Kept here (not in
    /// the palette view) so the view stays presentation-only and every action reuses the same
    /// state this window already owns.
    private func dispatch(_ action: PaletteAction) {
        switch action {
        case .navigate(let section):
            selectedCompute = nil
            selectedImageID = nil
            selectedVolumeID = nil
            selectedNetworkID = nil
            sidebarSelection = sidebarSelection(for: section)
        case .runContainer:    showRunSheet = true
        case .createMachine:   showMachineCreateSheet = true
        case .buildImage:      showBuildSheet = true
        case .pullImage:       showPullSheet = true
        case .loadImage:       promptLoadImage()
        case .createVolume:    showVolumeCreateSheet = true
        case .createNetwork:   showNetworkCreateSheet = true
        case .addRegistry:     showAddRegistrySheet = true
        case .refresh:         Task { await service.refresh() }
        case .selectContainer(let id): selectCompute(.container(id))
        case .selectMachine(let id):   selectCompute(.machine(id))
        case .openContainerShell(let id): openShell(.container(id))
        case .openMachineShell(let id):   openShell(.machine(id))
        // Destructive — confirmed before it runs (unlike the fire-and-forget lifecycle actions).
        case .deleteContainer(let id): pendingDelete = .container(id)
        case .deleteMachine(let id):   pendingDelete = .machine(id)
        // Lifecycle actions are fire-and-forget: the list/detail reflect the resulting state on the
        // next poll. A failure leaves the object's state unchanged (visible to the user) rather
        // than popping an alert over the palette.
        case .startContainer(let id):   Task { try? await service.startContainer(id) }
        case .stopContainer(let id):    Task { try? await service.stopContainer(id) }
        case .restartContainer(let id): Task { try? await service.restartContainer(id) }
        case .startMachine(let id):     Task { try? await service.startMachine(id) }
        case .stopMachine(let id):      Task { try? await service.stopMachine(id) }
        }
    }

    /// File picker first, sheet second: the sheet only exists to show progress/outcome, so a
    /// cancelled panel opens nothing at all.
    private func promptLoadImage() {
        if let url = promptForArchiveToLoad() {
            loadImageRequest = ImageLoadRequest(url: url)
        }
    }

    /// Select a compute item, switching to the Compute section first. The section switch fires
    /// `.onChange(of: sidebarSelection)`, which clears `selectedCompute` — so the selection is
    /// deferred to the next runloop to land *after* that clear rather than being wiped by it.
    /// When already on Compute the switch is a no-op and this simply selects one tick later.
    private func selectCompute(_ item: ComputeItem) {
        sidebarSelection = .compute
        DispatchQueue.main.async { selectedCompute = item }
    }

    /// Select a compute item and ask its detail view to open the Terminal tab. The request is set
    /// before the selection so the (usually fresh) detail mount reads it on appear.
    private func openShell(_ item: ComputeItem) {
        bridge.terminalRequest = item
        selectCompute(item)
    }

    /// The name shown in the delete confirmation, resolved from the pending item.
    private var pendingDeleteName: String {
        switch pendingDelete {
        case .container(let id): service.containers.first { $0.id == id }?.name ?? "this container"
        case .machine(let id):   service.machines.first { $0.id == id }?.name ?? "this machine"
        case nil:                ""
        }
    }

    /// Run the confirmed delete. Clears the selection if the deleted item was showing (so the
    /// detail pane doesn't flash "not found"), and surfaces failures rather than swallowing them.
    private func performPendingDelete(_ item: ComputeItem) {
        if selectedCompute == item { selectedCompute = nil }
        Task {
            do {
                switch item {
                case .container(let id): try await service.deleteContainer(id)
                case .machine(let id):   try await service.deleteMachine(id)
                }
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
        }
    }

    private func sidebarSelection(for section: PaletteSection) -> SidebarSelection {
        switch section {
        case .compute:    .compute
        case .volumes:    .volumes
        case .networks:   .networks
        case .images:     .images
        case .registries: .registries
        case .system:     .system
        }
    }

    private func handlePendingIntent() {
        switch bridge.pendingIntent {
        case .selectCompute(let item):
            sidebarSelection = .compute
            selectedCompute = item
        case .navigate(let section):
            // Setting the section fires `.onChange(of: sidebarSelection)`, which clears any open
            // detail selection — so switching panes lands on the list, not a stale detail.
            sidebarSelection = section
        case .openRunContainerSheet:
            showRunSheet = true
        case .openCreateMachineSheet:
            showMachineCreateSheet = true
        case .openBuildSheet:
            showBuildSheet = true
        case .openPullSheet:
            showPullSheet = true
        case .openLoadImageSheet:
            promptLoadImage()
        case .openCreateVolumeSheet:
            showVolumeCreateSheet = true
        case .openCreateNetworkSheet:
            showNetworkCreateSheet = true
        case .openAddRegistrySheet:
            showAddRegistrySheet = true
        case nil:
            return
        }
        bridge.pendingIntent = nil
    }

    private var detailVisible: Bool {
        selectedCompute != nil
            || (selectedImageID != nil && sidebarSelection == .images)
            || (selectedVolumeID != nil && sidebarSelection == .volumes)
            || (selectedNetworkID != nil && sidebarSelection == .networks)
    }

    /// The create action for the selected sidebar section, if it has one.
    private var contextualAddAction: (title: String, action: () -> Void)? {
        switch sidebarSelection {
        case .volumes:    ("Add Volume…",   { showVolumeCreateSheet = true })
        case .networks:   ("Add Network…",  { showNetworkCreateSheet = true })
        case .registries: ("Add Registry…", { showAddRegistrySheet = true })
        default:          nil
        }
    }

    // MARK: - Content pane (list)

    @ViewBuilder
    private var contentPane: some View {
        switch sidebarSelection {
        case .compute:
            ComputeListView(selection: $selectedCompute)
        case .volumes:
            VolumesListView(selectedID: $selectedVolumeID)
        case .networks:
            NetworksListView(selectedID: $selectedNetworkID)
        case .images:
            ImagesListView(selectedID: $selectedImageID)
        case .registries:
            RegistriesListView()
        case .system:
            SystemView()
        case nil:
            ContentUnavailableView("Select a section", systemImage: "sidebar.left")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // `.titleAndIcon` on the primary actions: macOS toolbars render Labels icon-only by
        // default, which left three ambiguities — Run's play.fill collides with every row's
        // "start this container" button, Pull's arrow.down.circle sits next to Refresh's
        // arrow.clockwise, and the contextual + changes meaning per section. Text resolves all
        // three (Finder/Mail label their primary toolbar actions the same way); Refresh stays
        // icon-only in its own group — secondary and universally understood.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showRunMenu = true
            } label: {
                Label("Run", systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .tint(.berthlyAccent)
            .disabled(!service.isConnected)
            .help("Run a container or create a machine")
            // Stable identifier so UI tests query this button unambiguously: RunContainerSheet's
            // submit button carries the *label* "Run" (see submitLabel), and XCUITest matches
            // buttons["Run"] on identifier-or-label, so a label-based query hits both while the
            // sheet is on screen.
            .accessibilityIdentifier("runToolbarButton")
            // Shortcuts live on the Container menu items (ContainerCommands), not here — the
            // menu is the canonical owner, and registering the same key twice is ambiguous.
            .background(
                PopoverAnchor(isPresented: $showRunMenu) {
                    RunTypeMenuContent(
                        onSelectContainer: {
                            showRunMenu = false
                            showRunSheet = true
                        },
                        onSelectMachine: {
                            showRunMenu = false
                            showMachineCreateSheet = true
                        }
                    )
                }
            )

            Button {
                showBuildSheet = true
            } label: {
                Label("Build", systemImage: "hammer")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!service.isConnected)
            .help("Build an image from a Dockerfile")

            Button {
                showPullSheet = true
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
                    .labelStyle(.titleAndIcon)
            }
            .disabled(!service.isConnected)
            .help("Pull an image from a registry")

            // One home for section-scoped create actions (Finder/Notes keep primary actions in
            // the toolbar), instead of each list view growing its own in-content button bar.
            if let add = contextualAddAction {
                Button(action: add.action) {
                    Label(add.title, systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(!service.isConnected)
                .help(add.title)
            }
        }

        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        ToolbarItem(placement: .automatic) {
            if !buildManager.jobs.isEmpty {
                Button {
                    showBuildsPopover = true
                } label: {
                    BuildsToolbarLabel(manager: buildManager)
                }
                .accessibilityLabel("Builds")
                .accessibilityIdentifier("buildsIndicator")
                .background(
                    PopoverAnchor(isPresented: $showBuildsPopover) {
                        BuildsPopover(manager: buildManager) { job in
                            showBuildsPopover = false
                            viewedBuildJob = job
                        }
                    }
                )
                .help("Builds")
            }
        }

        ToolbarItem(placement: .automatic) {
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                    refreshRotation = 360
                }
                Task {
                    await service.refresh()
                    withAnimation(.default) { refreshRotation = 0 }
                    isRefreshing = false
                }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .rotationEffect(.degrees(refreshRotation))
            }
            .disabled(!service.isConnected)
            .help("Refresh")
        }
    }

}

#Preview {
    MainWindowView()
        .environment(MockContainerService() as ContainerServiceBase)
        .environment(MenuBarBridge())
        .environment(BuildJobManager())
        .frame(width: 1200, height: 780)
}
