import SwiftUI
import TerminalProgress

struct MainWindowView: View {
    @Environment(ContainerServiceBase.self) private var service
    @Environment(MenuBarBridge.self) private var bridge
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
            .keyboardShortcut("r", modifiers: [.command, .shift])
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
            .keyboardShortcut("b", modifiers: [.command, .shift])

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
            .keyboardShortcut("r", modifiers: .command)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                // TODO: M7 — command palette
            } label: {
                Label("Search or run a command", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)
        }
    }

}

// MARK: - Pull Progress State

@MainActor
@Observable
private final class PullProgressState {
    struct LogLine: Identifiable {
        let id = UUID()
        let tag: String
        let text: String
    }

    var completedItems: Int = 0
    var totalItems: Int = 0
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var logLines: [LogLine] = []

    private var hasLoggedManifest = false

    func start(reference: String) {
        completedItems = 0; totalItems = 0; downloadedBytes = 0; totalBytes = 0
        hasLoggedManifest = false
        logLines = [LogLine(tag: "PULL", text: "container image pull \(reference)")]
    }

    func markFetchingComplete() {
        if totalItems > 0 {
            let blobWord = totalItems == 1 ? "blob" : "blobs"
            let sizePart = totalBytes > 0 ? " · \(formatSize(totalBytes))" : ""
            logLines.append(LogLine(tag: "PULL", text: "fetching complete · \(totalItems) \(blobWord)\(sizePart)"))
        } else {
            logLines.append(LogLine(tag: "PULL", text: "fetching complete · all layers cached"))
        }
    }

    func appendLog(tag: String, text: String) {
        logLines.append(LogLine(tag: tag, text: text))
    }

    func markDone(reference: String) {
        logLines.append(LogLine(tag: "DONE", text: "\(reference) ready · pulled to local store"))
    }

    func handle(_ events: [ProgressUpdateEvent]) {
        var dTotalSize: Int64 = 0
        var dSize: Int64 = 0
        var dItems: Int = 0
        var dTotalItems: Int = 0
        for event in events {
            switch event {
            case .addTotalSize(let n):  dTotalSize += n
            case .addSize(let n):       dSize += n
            case .addItems(let n):      dItems += n
            case .addTotalItems(let n): dTotalItems += n
            default: break
            }
        }
        totalBytes      += dTotalSize
        downloadedBytes += dSize
        completedItems  += dItems
        totalItems      += dTotalItems

        if !hasLoggedManifest && dTotalSize > 0 {
            hasLoggedManifest = true
            logLines.append(LogLine(tag: "PULL", text: "resolving manifest ✓"))
        }
    }

    var fraction: Double? {
        if totalBytes > 0 { return min(1.0, Double(downloadedBytes) / Double(totalBytes)) }
        if totalItems > 0 { return min(1.0, Double(completedItems) / Double(totalItems)) }
        return nil
    }

    var percentText: String {
        guard let f = fraction else { return "" }
        return "\(Int(f * 100))%"
    }

    private func formatSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        if kb >= 1 { return String(format: "%.0f KB", kb) }
        return "\(bytes) B"
    }

    var handler: ProgressUpdateHandler {
        { [weak self] events in
            guard let self else { return }
            await self.handle(events)
        }
    }
}

// MARK: - Pull Image Sheet

private struct PullImageSheet: View {
    let onOpenRegistries: () -> Void

    @Environment(ContainerServiceBase.self) private var service
    @Environment(\.dismiss) private var dismiss

    @State private var reference = ""
    @State private var platformChoice: SheetPlatformChoice = .default
    @State private var allowInsecure = false
    @State private var showAdvanced = false
    @State private var isPulling = false
    @State private var isDone = false
    @State private var errorMessage: String?
    @State private var pullProgress = PullProgressState()
    @State private var pullTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "globe")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull image")
                        .font(.headline)
                    Text("Pulls from Docker Hub or any public registry — no sign-in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            // Body
            VStack(alignment: .leading, spacing: 14) {
                if isPulling || isDone {
                    activeContent
                } else {
                    idleContent
                }
                if let error = errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            .padding(20)

            Divider()

            // Footer
            HStack {
                Spacer()
                if isDone {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return)
                } else if isPulling {
                    Button("Cancel") { cancelPull() }
                    Button {} label: {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(true)
                } else {
                    Button("Cancel") { dismiss() }
                    Button("Pull") { startPull() }
                        .buttonStyle(.borderedProminent)
                        .disabled(reference.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.return)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
    }

    @ViewBuilder
    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Image reference")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("ubuntu:24.04", text: $reference)
                .textFieldStyle(.roundedBorder)
                .fontDesign(.monospaced)
                .onSubmit { startPull() }
        }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.green)
                .imageScale(.small)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Anonymous pull — no sign-in needed. Short names resolve against \(Text("docker.io/library").fontDesign(.monospaced)).")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 3) {
                    Text("For a private image,")
                    Button { onOpenRegistries() } label: {
                        Text("sign in via Registries.").underline()
                    }
                    .buttonStyle(.link)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))

        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                PlatformPicker(title: "Platform", selection: $platformChoice)
                Toggle(isOn: $allowInsecure) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow insecure registry")
                            .font(.caption.weight(.medium))
                        Text("Forces HTTP instead of HTTPS. Only use for private registries without TLS.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(.top, 10)
        } label: {
            Text("Advanced")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        // Progress bar — visible while pulling, hidden when done
        if isPulling {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pulling image")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(pullProgress.percentText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let fraction = pullProgress.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        }

        // Log output box
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pullProgress.logLines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Text(line.tag)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 36, alignment: .leading)
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.tag == "DONE" ? Color.green : Color.primary)
                        }
                        .id(line.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
            .onChange(of: pullProgress.logLines.count) { _, _ in
                if let last = pullProgress.logLines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }

        // Success box — visible when done
        if isDone {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image pulled")
                        .font(.callout.weight(.semibold))
                    Text(reference)
                        .font(.caption)
                        .fontDesign(.monospaced)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.2), lineWidth: 0.5))
        }
    }

    private func startPull() {
        let ref = reference.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty, !isPulling else { return }
        isPulling = true
        isDone = false
        errorMessage = nil
        pullProgress.start(reference: ref)
        let platform = platformChoice.rawValue.isEmpty ? nil : platformChoice.rawValue
        pullTask = Task {
            do {
                try await service.pullImage(
                    reference: ref,
                    platform: platform,
                    insecure: allowInsecure,
                    progress: pullProgress.handler,
                    onUnpacking: {
                        pullProgress.markFetchingComplete()
                        pullProgress.appendLog(tag: "PULL", text: "unpacking image")
                    }
                )
                pullProgress.markDone(reference: ref)
                isPulling = false
                isDone = true
            } catch is CancellationError {
                isPulling = false
            } catch {
                errorMessage = error.localizedDescription
                isPulling = false
            }
            pullTask = nil
        }
    }

    private func cancelPull() {
        pullTask?.cancel()
        pullTask = nil
        isPulling = false
        errorMessage = nil
    }
}

#Preview {
    MainWindowView()
        .environment(MockContainerService() as ContainerServiceBase)
        .frame(width: 1200, height: 780)
}
