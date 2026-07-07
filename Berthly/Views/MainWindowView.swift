import SwiftUI
import TerminalProgress

struct MainWindowView: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
    @Environment(BuildJobManager.self) private var buildManager
    @State private var sidebarSelection: SidebarSelection? = .compute
    @State private var selectedCompute: ComputeItem?
    @State private var selectedImageID: String?
    @State private var isRefreshing = false
    @State private var refreshRotation = 0.0
    @State private var showPullSheet = false
    @State private var showBuildSheet = false
    @State private var showRunMenu = false
    @State private var showRunSheet = false
    @State private var showMachineCreateSheet = false
    @State private var showBuildsPopover = false
    @State private var viewedBuildJob: BuildJob?

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
            }
            .animation(.easeInOut(duration: 0.25), value: selectedCompute)
            .animation(.easeInOut(duration: 0.25), value: selectedImageID)
            .onChange(of: service.isConnected) { _, connected in
                if !connected { selectedCompute = nil; selectedImageID = nil }
            }
            .onChange(of: sidebarSelection) { _, _ in
                selectedCompute = nil
                selectedImageID = nil
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
        .sheet(item: $viewedBuildJob) { job in
            BuildImageSheet(service: service, existingJob: job)
        }
        // Lets the menu bar tell whether a main window already exists before deciding whether to
        // call `openWindow(id:)` — that API has no built-in single-instance behavior for a plain
        // `WindowGroup`, so calling it unconditionally opens a duplicate window every time.
        .onAppear { bridge.isMainWindowOpen = true }
        .onDisappear { bridge.isMainWindowOpen = false }
    }

    private func handlePendingIntent() {
        switch bridge.pendingIntent {
        case .selectCompute(let item):
            sidebarSelection = .compute
            selectedCompute = item
        case .openRunContainerSheet:
            showRunSheet = true
        case .openCreateMachineSheet:
            showMachineCreateSheet = true
        case .openBuildSheet:
            showBuildSheet = true
        case .openPullSheet:
            showPullSheet = true
        case nil:
            return
        }
        bridge.pendingIntent = nil
    }

    private var detailVisible: Bool { selectedCompute != nil || (selectedImageID != nil && sidebarSelection == .images) }

    // MARK: - Content pane (list)

    @ViewBuilder
    private var contentPane: some View {
        switch sidebarSelection {
        case .compute:
            ComputeListView(selection: $selectedCompute)
        case .volumes:
            VolumesListView()
        case .networks:
            NetworksListView()
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showRunMenu = true
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.berthlyAccent)
            .disabled(!service.isConnected)
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
            }
            .disabled(!service.isConnected)

            Button {
                showPullSheet = true
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            .disabled(!service.isConnected)
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
